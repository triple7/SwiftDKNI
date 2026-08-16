import Foundation
import SceneKit

// MARK: - Core Singleton
final public class SwiftDKNI: Sendable {
    
    private static let lock = NSLock()
    
    // Tell the strict concurrency checker we are handling thread safety manually via the lock
    nonisolated(unsafe) private static var _shared: SwiftDKNI?
    
    /// Access the shared instance. Must call `configure(apiKey:)` first.
    public static var shared: SwiftDKNI {
        lock.lock()
        defer { lock.unlock() }
        guard let instance = _shared else {
            fatalError("SwiftDKNI must be configured via configure(apiKey:) before accessing 'shared'.")
        }
        return instance
    }
    
    /// Inject your API key at the application's entry point to initialize the singleton.
    public static func configure(apiKey: String) {
        lock.lock()
        defer { lock.unlock() }
        guard _shared == nil else { return }
        _shared = SwiftDKNI(apiKey: apiKey)
    }
    
    private let apiKey: String
    
    // Hold references to our pipeline services
    private let donkiService = DONKIService()
    
    private init(apiKey: String) {
        self.apiKey = apiKey
    }
}

// MARK: - Surface Generation Extension
extension SwiftDKNI {

    // MARK: - Scene Rendering Methods

    private func applySolarSurfaceMaterials(
            to sphere: SCNSphere,
            topologicalImage: Any?, // Accept the pre-fetched image directly
            cachedIfExists: Bool = true
        ) async throws {
            // 1. Fetch the active regions
            let noaaService = NOAADataService()
            let activeRegions = try await noaaService.fetchActiveRegions(cachedIfExists: cachedIfExists)
            
            // 2. Generate the surface layers
            guard let sunspotMask = generateSunspotTexture(from: activeRegions, textureSize: CGSize(width: 4096, height: 2048)),
                  let baseMaterial = sphere.materials.first else {
                return
            }
            
            sphere.segmentCount = 400
            
            // --- PBR UPGRADE: Shift from .constant to .physicallyBased ---
            baseMaterial.lightingModel = .physicallyBased
            
            // Force SceneKit to allocate the emission channel in the Metal struct
            // and kill specular highlights so it doesn't reflect ambient scene light
    #if os(macOS)
            baseMaterial.emission.contents = NSColor.black
            baseMaterial.specular.contents = NSColor.black
    #else
            baseMaterial.emission.contents = UIColor.black
            baseMaterial.specular.contents = UIColor.black
    #endif

            let sdoService = NASASDOService()
            
            // --- DATA ROUTING ---
            // LAYER 1: Core Surface Plasma (AIA 171) on Diffuse
            if let liveSunTexture = try? await sdoService.fetchLatestImage(wavelength: .aia171, resolution: 4096, cachedIfExists: cachedIfExists) {
                baseMaterial.diffuse.contents = liveSunTexture
            }
            
            // LAYER 2: NOAA Sunspot Mask on Ambient
            baseMaterial.ambient.contents = sunspotMask
            
            // LAYER 3: Coronal Holes (AIA 193) via Custom Uniform
            if let live193Texture = try? await sdoService.fetchLatestImage(wavelength: .aia193, resolution: 4096, cachedIfExists: cachedIfExists) {
                let textureProperty193 = SCNMaterialProperty(contents: live193Texture)
                baseMaterial.setValue(textureProperty193, forKey: "u_texture193")
            }
            
            // --- SHADER: Multi-Band Atmosphere Composite ---
            let multiBandSolarShader = """
                #pragma arguments
                texture2d<float, access::sample> u_texture193;
                
                #pragma transparent
                #pragma body
                
                constexpr sampler texSampler(coord::normalized, address::clamp_to_edge, filter::linear);
                float2 uv = _surface.diffuseTexcoord;
                
                // 1. Read the data streams
                float4 color171 = _surface.diffuse;
                float4 color193 = u_texture193.sample(texSampler, uv);
                float sunspotActivity = _surface.ambient.r;
                
                // 2. THE COMPOSITE MATH
                // Base: 193 Angstroms (Preserves the dark coronal holes)
                float3 compositeColor = color193.rgb;
                
                // Isolate 171: Calculate how bright the 171 pixel is
                float luma171 = dot(color171.rgb, float3(0.299, 0.587, 0.114));
                
                // Mask 171: Only add 171 where it is intensely bright (the active loops)
                // This prevents the 171 background from filling in the 193 coronal holes
                float3 hotPlasma171 = color171.rgb * smoothstep(0.4, 0.8, luma171);
                compositeColor += hotPlasma171;
                
                // Multiplicative Sunspots: Punch true dark holes into the composite
                // If sunspotActivity is 1.0, we multiply the color by 0.05 (near black)
                compositeColor *= (1.0 - (sunspotActivity * 0.95));
                
                // Ensure math doesn't drop below absolute zero
                compositeColor = max(compositeColor, float3(0.0));
                
                // 3. Atmospheric Edge Haze
                float4 uvBandSample = _surface.transparent;
                float uvIntensity = dot(uvBandSample.rgb, float3(0.299, 0.587, 0.114));
                
                float3 N = normalize(_surface.normal);
                float3 V = normalize(_surface.view);
                float edgeFactor = 1.0 - max(0.0, dot(N, V));
                
                float atmosphericHaze = pow(edgeFactor, 6.0);
                float3 atmosphereColor = float3(0.98, 0.90, 0.75); 
                float finalAtmosphereOpacity = atmosphericHaze * (0.2 + uvIntensity * 0.8);
                
                // 4. Final Blend
                float3 finalColor = mix(compositeColor, atmosphereColor, finalAtmosphereOpacity * 0.35);
                
                // 5. PBR COMPLIANCE: Route directly to emission and multiply for HDR bloom
                float emissionBoost = 6.0; 
                _surface.emission = float4(finalColor * emissionBoost, 1.0);
                
                // 6. Black out the physical diffuse channel
                _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
                """
            
            // Apply the surface shader by default
            baseMaterial.shaderModifiers = [.surface: multiBandSolarShader]
            
            // --- LAYER 4: Topological Warp ---
            if let validImage = topologicalImage {
                // 1. Create a standalone property (bypasses SceneKit alpha-sorting bug)
                let topoProperty = SCNMaterialProperty(contents: validImage)
                baseMaterial.setValue(topoProperty, forKey: "u_activeRegionMap")
                
                // 2. Set realistic topological bulge (2.5% expansion)
                let topographicalBulge: Float = 0.025
                baseMaterial.setValue(topographicalBulge, forKey: "u_warpIntensity")
                
                let unifiedGeometryShader = """
                    #pragma arguments
                    float u_warpIntensity;
                    texture2d<float, access::sample> u_activeRegionMap;
                    
                    #pragma body
                    
                    float flowTime = scn_frame.time * 0.15;
                    
                    float warpX = (sin(_geometry.texcoords[0].y * 12.0 + flowTime) 
                                 + sin(_geometry.texcoords[0].y * 28.0 - flowTime * 1.5)) * 0.003;
                                                                                                        
                    float warpY = (cos(_geometry.texcoords[0].x * 14.0 - flowTime) 
                                 + cos(_geometry.texcoords[0].x * 24.0 + flowTime * 1.2)) * 0.003;
                    
                    _geometry.texcoords[0].x += warpX;
                    _geometry.texcoords[0].y += warpY;
                    
                    constexpr sampler texSampler(coord::normalized, address::clamp_to_edge, filter::linear);
                    
                    float2 uv = _geometry.texcoords[0];
                    float4 mapData = u_activeRegionMap.sample(texSampler, uv);
                    float activityLevel = mapData.r; 
                    
                    float3 currentPos = _geometry.position.xyz;
                    float3 surfaceNormal = _geometry.normal;
                    float baseRadius = max(length(currentPos), 0.001f);
                    
                    float sinLat = currentPos.y / baseRadius;
                    float cosLat = sqrt(max(0.0f, 1.0f - (sinLat * sinLat)));
                    float oblateness = cosLat * 0.015f; 
                    
                    float magneticBulge = (activityLevel - 0.1f) * u_warpIntensity;
                    float totalDisplacement = (oblateness + magneticBulge) * baseRadius;
                    
                    _geometry.position.xyz = currentPos + (surfaceNormal * totalDisplacement);
                    """
                
                // 🚨 SAFEGUARD: Only append the geometry shader if the texture successfully loaded
                baseMaterial.shaderModifiers?[.geometry] = unifiedGeometryShader
                
            } else {
                // Fallback to plain white color, NO geometry shader added to prevent crash
    #if os(macOS)
                baseMaterial.transparent.contents = NSColor.white
    #else
                baseMaterial.transparent.contents = UIColor.white
    #endif
                print("Warning: Topological image failed to load. Falling back to perfect sphere geometry.")
            }
        }
    

    public func debugAnalyzeMagneticTexture(_ texture: MTLTexture) {
        let width = texture.width
        let height = texture.height
        let depth = texture.depth
        let totalVoxels = width * height * depth
        
        // Each voxel is RGBA32Float (4 floats = 16 bytes per voxel)
        let bytesPerPixel = MemoryLayout<SIMD4<Float>>.size
        let imageSize = totalVoxels * bytesPerPixel
        var rawMemory = Data(count: imageSize)
        
        rawMemory.withUnsafeMutableBytes { ptr in
            let region = MTLRegionMake3D(0, 0, 0, width, height, depth)
            texture.getBytes(ptr.baseAddress!, bytesPerRow: width * bytesPerPixel, bytesPerImage: width * height * bytesPerPixel, from: region, mipmapLevel: 0, slice: 0)
        }
        
        let floatPtr = rawMemory.withUnsafeBytes { $0.bindMemory(to: Float.self) }
        
        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0, sumA: Float = 0
        var minA: Float = Float.greatestFiniteMagnitude, maxA: Float = -Float.greatestFiniteMagnitude
        var nonZeroCount = 0
        
        // Step through the flat buffer (4 floats per voxel: R, G, B, A)
        let stride = 4
        for i in stride(from: 0, to: floatPtr.count, by: stride) {
            let r = floatPtr[i]
            let g = floatPtr[i+1]
            let b = floatPtr[i+2]
            let a = floatPtr[i+3]
            
            sumR += r
            sumG += g
            sumB += b
            sumA += a
            
            if a > 0.0001 {
                nonZeroCount += 1
                minA = min(minA, a)
                maxA = max(maxA, a)
            }
        }
        
        let voxelCountFloat = Float(totalVoxels)
        let meanR = sumR / voxelCountFloat
        let meanG = sumG / voxelCountFloat
        let meanB = sumB / voxelCountFloat
        let meanA = sumA / voxelCountFloat
        
        // Second pass for Standard Deviation (Sigma) on Alpha / Weight
        var varianceA: Float = 0
        for i in stride(from: 3, to: floatPtr.count, by: stride) {
            let a = floatPtr[i]
            let diff = a - meanA
            varianceA += diff * diff
        }
        let sigmaA = sqrt(varianceA / voxelCountFloat)
        
        print("""
        ==================================================
        📊 VOXEL TEXTURE STATISTICAL AUDIT ($\mu$ & $\sigma$)
        ==================================================
        Total Volume Pixels   : \(totalVoxels)
        Populated Voxels (A>0): \(nonZeroCount) (\(String(format: "%.1f", Float(nonZeroCount) / Float(totalVoxels) * 100))%)
        Mean RGB Vector       : [\(String(format: "%.4f", meanR)), \(String(format: "%.4f", meanG)), \(String(format: "%.4f", meanB))]
        Alpha Mean ($\mu$)    : \(String(format: "%.4f", meanA))
        Alpha StdDev ($\sigma$) : \(String(format: "%.4f", sigmaA))
        Alpha Min / Max       : \(String(format: "%.4f", minA)) / \(String(format: "%.4f", maxA))
        ==================================================
        """)
    }

    /// Generates a 3D Voxel Texture (sharedMagneticVolume) from FITS and SDO data.
        public func generateSharedMagneticVolume(
            device: MTLDevice,
            solarRadius: Float,
            resolution: Int = 64,
            warpIntensity: Float = 1.0, // Adjust based on your StellarConfig defaults
            cachedIfExists: Bool = true
        ) async throws -> MTLTexture? {
            
            // ---------------------------------------------------------
            // STAGE 1: CPU TOPOLOGICAL SAMPLER (AIA 193 Mask)
            // ---------------------------------------------------------
            print("Fetching AIA 193 image for CPU Topological Warping...")
            let sdoService = NASASDOService()
            var topologicalMap: [UInt8]? = nil
            var mapWidth = 0
            var mapHeight = 0
            
            if let coronalHoleMask = try? await sdoService.fetchLatestImage(wavelength: .aia193, resolution: 4096, cachedIfExists: cachedIfExists) {
                
    #if os(macOS)
                let extractedCGImage = coronalHoleMask.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #else
                let extractedCGImage = coronalHoleMask.cgImage
    #endif
                
                if let cgImage = extractedCGImage {
                    mapWidth = cgImage.width
                    mapHeight = cgImage.height
                    let colorSpace = CGColorSpaceCreateDeviceGray()
                    var rawData = [UInt8](repeating: 0, count: mapWidth * mapHeight)
                    
                    if let context = CGContext(data: &rawData, width: mapWidth, height: mapHeight, bitsPerComponent: 8, bytesPerRow: mapWidth, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: mapWidth, height: mapHeight))
                        topologicalMap = rawData
                        print("✅ CPU Topological Map successfully loaded (\(mapWidth)x\(mapHeight))")
                    }
                }
            }
            
            // Reusable closure to mathematically warp a 3D point identically to the Metal shader
            let applyTopologicalWarp: (simd_float3) -> simd_float3 = { pos in
                guard let map = topologicalMap, solarRadius > 0 else { return pos }
                
                let normalizedPos = normalize(pos)
                let clampedY = max(-1.0, min(1.0, normalizedPos.y))
                
                let u = 0.5 + atan2(normalizedPos.z, normalizedPos.x) / (2.0 * Float.pi)
                let v = 0.5 - asin(clampedY) / Float.pi
                
                let px = max(0, min(mapWidth - 1, Int(u * Float(mapWidth))))
                let py = max(0, min(mapHeight - 1, Int(v * Float(mapHeight))))
                
                let activityLevel = Float(map[py * mapWidth + px]) / 255.0
                
                let sinLat = clampedY
                let cosLat = sqrt(max(0.0, 1.0 - sinLat * sinLat))
                let oblateness = cosLat * 0.015
                
                let magneticBulge = (activityLevel - 0.1) * warpIntensity
                let totalDisplacement = (oblateness + magneticBulge) * solarRadius
                
                return pos + (normalizedPos * totalDisplacement)
            }
            
            // ---------------------------------------------------------
            // STAGE 2: FETCH & BUILD MAGNETIC LOOPS FROM FITS DATA
            // ---------------------------------------------------------
            print("Fetching FITS Magnetogram...")
            let magnetogramModeler = MagnetogramModeler()
            
            guard let fitsURL = try? await magnetogramModeler.fetchLatestSynopticMagnetogram(cachedIfExists: cachedIfExists),
                  let magData = try? magnetogramModeler.processFitsFile(at: fitsURL) else {
                print("Warning: Failed to process FITS data for magnetic volume.")
                return nil
            }
            
            // THE AMBIENT FIELD
            let rawMagneticBuckets = magnetogramModeler.exportRawBuckets(from: magData, thresholdGauss: 20.0)
            
            print("Generating Ambient 3D PFSS Vector Field...")
            let ambientPFSSArray = self.generateVolumetricFieldFromBuckets(
                device: device,
                buckets: rawMagneticBuckets,
                solarRadius: solarRadius
            ).volumeData
            
            // THE GEOMETRY DEFORMATION
            var magneticLines = magnetogramModeler.calculateMagneticLoops(from: magData)
            let regionalFlows = self.extractMacroRegionalFlows(from: magneticLines)
            
            // Intercept splines on CPU to apply ambient field deformation & Solar Rotation
            magneticLines = magneticLines.map { line in
                let warpedP0 = applyTopologicalWarp(line.p0)
                let warpedP4 = applyTopologicalWarp(line.p4)
                
                var (newP0, newP1, newP2, newP3, newP4) = self.applyMagneticInfluenceToSpline(
                    p0: warpedP0,
                    p1: line.p1,
                    p2: line.p2,
                    p3: line.p3,
                    p4: warpedP4,
                    isOpen: line.isOpen,
                    pfssVolume: ambientPFSSArray,
                    regionalFlows: regionalFlows,
                    solarRadius: solarRadius
                )
                
                if line.isOpen {
                    newP1 = self.applySolarRotationShift(point: newP1, solarRadius: solarRadius)
                    newP2 = self.applySolarRotationShift(point: newP2, solarRadius: solarRadius)
                    newP3 = self.applySolarRotationShift(point: newP3, solarRadius: solarRadius)
                    newP4 = self.applySolarRotationShift(point: newP4, solarRadius: solarRadius)
                } else {
                    newP1 = self.applySolarRotationShift(point: newP1, solarRadius: solarRadius, rotationRate: 0.25)
                    newP2 = self.applySolarRotationShift(point: newP2, solarRadius: solarRadius, rotationRate: 0.25)
                    newP3 = self.applySolarRotationShift(point: newP3, solarRadius: solarRadius, rotationRate: 0.25)
                }
                
                return MagneticLoopLine(p0: newP0, p1: newP1, p2: newP2, p3: newP3, p4: newP4, isOpen: line.isOpen, intensity: line.intensity)
            }
            
            // ---------------------------------------------------------
            // STAGE 3: FLOW FIELD RASTERIZATION
            // ---------------------------------------------------------
            print("Generating final Flow Volume via Spline Rasterization...")
            let volumeResult = self.generateMagneticVolumeTexture(
                device: device,
                lines: magneticLines,
                solarRadius: solarRadius,
                resolution: resolution
            )
            
            self.debugAnalyzeMagneticTexture(volumeResult.texture)
            return volumeResult.texture
        }

    /// Fetches, generates, and time-aligns all CME events into a single container node.
    /// - Parameters:
    ///   - sphere: The central SCNSphere whose radius dictates the starting boundary.
    ///   - pointsPerEvent: The vertex density for each individual flux rope.
    ///   - startTime: The start date string (yyyy-MM-dd).
    ///   - endTime: The end date string (yyyy-MM-dd).
    /// - Returns: An SCNNode containing all aligned CME child nodes.
    public func generateCoronalSurfaceUsingMegnetoGram(
            device: MTLDevice,
            sphere: SCNSphere,
            maxPointsPerCME: Int = 125000,
            startTime: String,
            endTime: String,
            cachedIfExists: Bool = true,
            renderCME: Bool = true,
            renderMagneticLoops: Bool = true,       // 🚨 NEW PARAMETER
            renderThermalAtmosphere: Bool = true,   // 🚨 NEW PARAMETER
            stellarConfig: StellarConfig = StellarConfig()
        ) async throws -> SCNNode {
                        
            // Unpack the configs
            let cMEConfig = stellarConfig.cmeConfig
            let energyTunnelConfig = stellarConfig.energyTunnelConfig
            // 1. Fetch the averaged data using the securely injected API key
            let request = CMERequest(startDate: startTime, endDate: endTime, apiKey: self.apiKey)
                        
            var events: [AveragedCMEData] = []
            var actualSimulationStart = startTime
            var actualSimulationEnd = endTime

            do {
                let result = try await donkiService.fetchAndAverageCMEData(request: request, cachedIfExists: cachedIfExists)
                events = result.events
                            
                // Override the query parameters with the actual bounds from the cache
                // .prefix(10) strips the 'T02:09Z' off the end so it cleanly matches "yyyy-MM-dd"
                if let realStart = result.actualStartTime { actualSimulationStart = String(realStart.prefix(10)) }
                if let realEnd = result.actualEndTime { actualSimulationEnd = String(realEnd.prefix(10)) }
            } catch {
                print("Warning: CME Generation Failed (\(error)). Proceeding with base sun & magnetic loops only.")
            }
                        
            // 2. Create the parent container
            let coronalSurfaceNode = SCNNode()
                        
            // 3. Setup Date Parsers to establish t = 0 and timeline boundaries
            let queryFormatter = DateFormatter()
            queryFormatter.dateFormat = "yyyy-MM-dd"
            queryFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                        
            let simulationStart = queryFormatter.date(from: actualSimulationStart) ?? Date()
            // Cheesy workaround for the simulation end; currently the realEnd computation above cuts off the time, so adding a day to the end to get all events back
            let simulationEnd = queryFormatter.date(from: actualSimulationEnd)?.addingTimeInterval(86400) ?? simulationStart.addingTimeInterval(86400 * 30)
            
            // Calculate the timeline compression ratio (Maps the entire query window into a visually driven loop duration)
            let totalRealSeconds = simulationEnd.timeIntervalSince(simulationStart)
            let visualLoopDuration: Double = cMEConfig.visualLoopDuration
            let compressionRatio = visualLoopDuration / max(1.0, totalRealSeconds)
                        
            let donkiFormatter = DateFormatter()
            donkiFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
            donkiFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                        
            let backupISOFormatter = ISO8601DateFormatter()
            backupISOFormatter.formatOptions = [.withInternetDateTime]
                        
            let geometryBuilder = CMEGeometryBuilder()
            let sRadius = Float(sphere.radius)
                        
            // 🚨 FIX: Sync this exactly with the GPU vertex shader to prevent loop separation
            let warpIntensity: Float = cMEConfig.warpIntensity
                        
            // --- NEW: CPU TOPOLOGICAL SAMPLER ---
            print("Fetching AIA 193 image for CPU Topological Warping...")
            let sdoService = NASASDOService()
            var topologicalMap: [UInt8]? = nil
            var mapWidth = 0
            var mapHeight = 0
                        
            // 🚨 FIX: Hoist the image reference so we can pass it down to the material builder later
            var fetchedTopologicalImage: Any? = nil
                        
            if let coronalHoleMask = try? await sdoService.fetchLatestImage(wavelength: .aia193, resolution: 4096, cachedIfExists: cachedIfExists) {
                            
                fetchedTopologicalImage = coronalHoleMask // Store it to avoid double-fetching
                            
                // FIX: Safely extract the CGImage depending on the OS architecture
        #if os(macOS)
                let extractedCGImage = coronalHoleMask.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
                let extractedCGImage = coronalHoleMask.cgImage
        #endif
                            
                if let cgImage = extractedCGImage {
                    mapWidth = cgImage.width
                    mapHeight = cgImage.height
                    let colorSpace = CGColorSpaceCreateDeviceGray()
                    var rawData = [UInt8](repeating: 0, count: mapWidth * mapHeight)
                                
                    if let context = CGContext(data: &rawData, width: mapWidth, height: mapHeight, bitsPerComponent: 8, bytesPerRow: mapWidth, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: mapWidth, height: mapHeight))
                        topologicalMap = rawData
                        print("✅ CPU Topological Map successfully loaded (\(mapWidth)x\(mapHeight))")
                    }
                }
            }
                        
            // Reusable closure to mathematically warp a 3D point identically to the Metal shader
            let applyTopologicalWarp: (simd_float3) -> simd_float3 = { pos in
                guard let map = topologicalMap, sRadius > 0 else { return pos }
                            
                let normalizedPos = normalize(pos)
                            
                // 🚨 SAFEGUARD: Clamp Y strictly to [-1.0, 1.0] to prevent asin() from returning NaN
                let clampedY = max(-1.0, min(1.0, normalizedPos.y))
                            
                // Calculate UV coordinates matching SceneKit's spherical mapping
                let u = 0.5 + atan2(normalizedPos.z, normalizedPos.x) / (2.0 * Float.pi)
                let v = 0.5 - asin(clampedY) / Float.pi
                            
                let px = max(0, min(mapWidth - 1, Int(u * Float(mapWidth))))
                let py = max(0, min(mapHeight - 1, Int(v * Float(mapHeight))))
                            
                let activityLevel = Float(map[py * mapWidth + px]) / 255.0
                            
                let sinLat = clampedY // Reuse the safe Y value
                let cosLat = sqrt(max(0.0, 1.0 - sinLat * sinLat))
                let oblateness = cosLat * 0.015
                            
                let magneticBulge = (activityLevel - 0.1) * warpIntensity
                let totalDisplacement = (oblateness + magneticBulge) * sRadius
                            
                return pos + (normalizedPos * totalDisplacement)
            }
            // -------------------------------------
                        
            // --- FETCH, BUILD & DEFORM GLOBAL MAGNETIC LOOPS FROM FITS DATA ---
            print("Fetching FITS Magnetogram...")
            let magnetogramModeler = MagnetogramModeler()
                        
            var openMagneticLines: [MagneticLoopLine] = []
            var rawMagneticBuckets: [MagneticBucket] = []
            var sharedMagneticVolume: MTLTexture? = nil
                        
            if let fitsURL = try? await magnetogramModeler.fetchLatestSynopticMagnetogram(cachedIfExists: cachedIfExists),
               let magData = try? magnetogramModeler.processFitsFile(at: fitsURL) {
                            
                // STAGE 1: THE AMBIENT FIELD
                rawMagneticBuckets = magnetogramModeler.exportRawBuckets(from: magData, thresholdGauss: 20.0)
                            
                print("Generating Ambient 3D PFSS Vector Field...")
                let ambientPFSSArray = self.generateVolumetricFieldFromBuckets(
                    device: device,
                    buckets: rawMagneticBuckets,
                    solarRadius: sRadius
                ).volumeData
                            
                // STAGE 2: THE GEOMETRY DEFORMATION
                let magneticLoopStart = CACurrentMediaTime()
                var magneticLines = magnetogramModeler.calculateMagneticLoops(from: magData)
                            
                // 🚨 GLOBAL TOPOLOGY: Extract the macro-winds from the splines BEFORE we deform them
                let regionalFlows = self.extractMacroRegionalFlows(from: magneticLines)
                            
                // Intercept splines on CPU to apply ambient field deformation & Solar Rotation
                magneticLines = magneticLines.map { line in
                    // 🚨 NEW: Warp the root points to match the GPU's active region bulging
                    let warpedP0 = applyTopologicalWarp(line.p0)
                    let warpedP4 = applyTopologicalWarp(line.p4)
                                
                    // A. Bend the apex based on the ambient voxel vectors AND the global macro-winds
                    var (newP0, newP1, newP2, newP3, newP4) = self.applyMagneticInfluenceToSpline(
                        p0: warpedP0,
                        p1: line.p1,
                        p2: line.p2,
                        p3: line.p3,
                        p4: warpedP4,
                        isOpen: line.isOpen,
                        pfssVolume: ambientPFSSArray,
                        regionalFlows: regionalFlows,
                        solarRadius: sRadius
                    )

                    // B. Apply the Archimedean Parker Spiral twisting force based on solar rotation
                    if line.isOpen {
                        newP1 = self.applySolarRotationShift(point: newP1, solarRadius: sRadius)
                        newP2 = self.applySolarRotationShift(point: newP2, solarRadius: sRadius)
                        newP3 = self.applySolarRotationShift(point: newP3, solarRadius: sRadius)
                        newP4 = self.applySolarRotationShift(point: newP4, solarRadius: sRadius)
                    } else {
                        newP1 = self.applySolarRotationShift(point: newP1, solarRadius: sRadius, rotationRate: 0.25)
                        newP2 = self.applySolarRotationShift(point: newP2, solarRadius: sRadius, rotationRate: 0.25)
                        newP3 = self.applySolarRotationShift(point: newP3, solarRadius: sRadius, rotationRate: 0.25)
                    }
                                
                    return MagneticLoopLine(p0: newP0, p1: newP1, p2: newP2, p3: newP3, p4: newP4, isOpen: line.isOpen, intensity: line.intensity)
                }
                            
                let magneticLoopEnd = CACurrentMediaTime()
                print("generateCoronalSurfaceUsingMegnetoGram: processed & deformed magnetic loops in \(magneticLoopEnd - magneticLoopStart) seconds.")
                            
                openMagneticLines = magneticLines.filter { $0.isOpen }
                            
                // STAGE 3: THE FLOW FIELD (GPU RASTERIZATION)
                print("Generating final CME Flow Volume via Spline Rasterization...")
                let magneticResolution = 64
                let volumeResult = self.generateMagneticVolumeTexture(
                    device: device,
                    lines: magneticLines,
                    solarRadius: sRadius,
                    resolution: magneticResolution
                )
                sharedMagneticVolume = volumeResult.texture
                            
                let magneticVectorField = self.generateMagneticVectorFieldFromVolumeData(
                    volumeData: volumeResult.volumeData,
                    solarRadius: sRadius,
                    resolution: magneticResolution
                )
                            
                magneticVectorField.opacity = 0.2
                            
                // STAGE 4: VISUAL GEOMETRY
                let globalMagneticNode = geometryBuilder.createCoronalSurface(from: magneticLines, energyTunnelConfig: energyTunnelConfig, solarRadius: sRadius)
                            
                // 🚨 CONDITIONALLY ADD MAGNETIC LOOPS
                if renderMagneticLoops {
                    coronalSurfaceNode.addChildNode(globalMagneticNode)
                }
            }
                        
            var firstIgnitionTime: Float? = nil
                        
            // 4. Generate and align each CME event ONLY if the flag is true
            if renderCME {
                var sharedVolumeProperty: SCNMaterialProperty? = nil
                if let magneticVolume = sharedMagneticVolume {
                    sharedVolumeProperty = SCNMaterialProperty(contents: magneticVolume)
                    print("✅ Shared PFSS Volume Property mapped safely to KVC engine.")
                }
                            
                let calculatedPointsPerEvent = max(500, maxPointsPerCME / max(1, events.count))
                            
                for (i, event) in events.enumerated() {
                    guard event.latitude != nil, event.longitude != nil else { continue }
                                
                    let parsedDate = donkiFormatter.date(from: event.startTime) ?? backupISOFormatter.date(from: event.startTime)
                    guard let eventDate = parsedDate else {
                        print("Skipped CME: Unrecognized Date Format - \(event.startTime)")
                        continue
                    }
                                
                    let realIgnitionOffset = eventDate.timeIntervalSince(simulationStart)
                    let safeIgnitionTime = Float(realIgnitionOffset * compressionRatio)
                                
                    if firstIgnitionTime == nil || safeIgnitionTime < firstIgnitionTime! {
                        firstIgnitionTime = safeIgnitionTime
                    }
                                
                    // NOTE: The user's internal `createCoronalEjectionNode` logic calculates root positions.
                    // If CMEs are strictly generated from the surface, they may also require the `applyTopologicalWarp`
                    // inside `createCoronalEjectionNode` depending on its internal math structure.
                    let cmeNode = try! geometryBuilder.createCoronalEjectionNode(
                        for: event,
                        openLines: openMagneticLines,
                        pointCount: cMEConfig.pointCount,
                        solarRadius: Float(sphere.radius),
                        config:  stellarConfig.cmeConfig)

                    //  ANTI-CULL OVERRIDE: Force a massive bounding box so SceneKit never deletes it
                    cmeNode.geometry?.boundingBox = (
                        min: SCNVector3(-50.0, -50.0, -50.0),
                        max: SCNVector3(50.0, 50.0, 50.0)
                    )
                    
                    if let material = cmeNode.geometry?.materials.first {
                        let scnLoopTimeCME = Float(visualLoopDuration)
                        let scnIgnitionTime = safeIgnitionTime.truncatingRemainder(dividingBy: scnLoopTimeCME)
                                    
                        // Event timeline
                        material.setValue(NSNumber(value: scnIgnitionTime), forKey: "u_ignitionTime")
                        material.setValue(NSNumber(value: scnLoopTimeCME), forKey: "u_loopTime")
                        material.setValue(NSNumber(value: cMEConfig.scnFrameTimeSnapshot), forKey: "u_scnFrameTimeSnapshot")

                        // 🚨 BIND IMMEDIATELY: Ensure the timeline variables are never left unbound
                        material.setValue(NSNumber(value: cMEConfig.globalTime), forKey: "u_globalTime")
                        material.setValue(NSNumber(value: sRadius), forKey: "u_solarRadius")
                        material.setValue(NSNumber(value: cMEConfig.thickness), forKey: "u_thickness")
                                    
                        // Scaling of the event speed into scn units is done inside the metal geometry shader
                        let rawSpeed = Float(event.speed) ?? cMEConfig.defaultSpeed
                        let rawHalfAngleRadians = (Float(event.halfAngle) ?? cMEConfig.defaultHalfAngle) * 3.1415927 / 180.0
                        
                        material.setValue(NSNumber(value: cMEConfig.ejectionMultiplier), forKey: "u_ejectionMultiplier")
                        material.setValue(NSNumber(value: rawSpeed), forKey: "u_speed")
                        material.setValue(NSNumber(value: rawHalfAngleRadians), forKey: "u_halfAngle")
                        let tanHalfAngle = Float(tan(rawHalfAngleRadians))
                        material.setValue(NSNumber(value: tanHalfAngle), forKey: "u_tanHalfAngle")
                                    
                        if let vp = sharedVolumeProperty {
                            material.setValue(vp, forKey: "u_magneticVolume")
                        } else {
                            print("Warning: Missing Magnetic Volume, CME will not render correctly.")
                        }
                    }
                    // Add CME prefix for filtering during material uniform changes
                    cmeNode.name = "CME_\(i)"
                    coronalSurfaceNode.addChildNode(cmeNode)
                }
            }
                        
            // 5. Apply Solar Surface Materials (NOAA + NASA SDO Composite)
            // 🚨 FIX: Pass the securely hoisted topological image, eliminating the race condition
            try await applySolarSurfaceMaterials(to: sphere, topologicalImage: fetchedTopologicalImage, cachedIfExists: cachedIfExists)

            // --- THERMAL DISTORTION SHELL
            // 🚨 CONDITIONALLY ADD THERMAL ATMOSPHERE
            if renderThermalAtmosphere {
                // Get the surface material of the sun to bind to the halo and distortion
                if let surfaceMaterial = sphere.materials.first,
                   let surfaceContents = surfaceMaterial.diffuse.contents,
                   let metalSurfaceTexture = TextureLoaderUtility.loadTexture(from: surfaceContents, device: device) {
                    
                    let thermalShellNode = self.generateThermalAtmosphericNode(
                        radius: Float(sphere.radius),
                        thermalRadius: 1.2,
                        surfaceTexture: metalSurfaceTexture, // Now guaranteed to be a valid MTLTexture
                        voxelCube: sharedMagneticVolume!,
                        config: stellarConfig.thermalConfig
                    )
                    coronalSurfaceNode.addChildNode(thermalShellNode)
                }
            }
            
            return coronalSurfaceNode
        }
    
    public func addDistortionTechniqueToScene(sceneView: SCNView, initialTint: simd_float4 = simd_float4(1.0, 0.92, 0.80, 1.0)) {
            let techniqueDict: [String: Any] = [
                "symbols": [
                    "timeSymbol": ["semantic": "time", "type": "float"],
                    "starTintSymbol": ["type": "vec4"]
                ],
                "passes": [
                    "mainScenePass": [
                        "draw": "DRAW_SCENE",
                        "outputs": ["color": "SCENE_BUFFER"],
                        "excludeCategoryMask": 4
                    ],
                    "cmePass": [
                        "draw": "DRAW_SCENE",
                        "outputs": ["color": "CME_BUFFER"],
                        "includeCategoryMask": 4
                    ],
                    "distortionPass": [
                        "draw": "DRAW_QUAD",
                        "metalVertexShader": "distortionVertex",
                        "metalFragmentShader": "distortionFragment",
                        "inputs": [
                            "colorSampler": "SCENE_BUFFER",
                            "refractionSampler": "CME_BUFFER",
                            "time": "timeSymbol"
                        ],
                        "outputs": ["color": "DISTORTED_BUFFER"]
                    ],
                    "blurPass": [
                        "draw": "DRAW_QUAD",
                        "metalVertexShader": "distortionVertex",
                        "metalFragmentShader": "blurFragment",
                        "inputs": [
                            "sceneToBlur": "DISTORTED_BUFFER"
                        ],
                        "outputs": ["color": "BLURRED_BUFFER"]
                    ],
                    "tintPass": [
                        "draw": "DRAW_QUAD",
                        "metalVertexShader": "distortionVertex",
                        "metalFragmentShader": "tintFragment",
                        "inputs": [
                            "blurredScene": "BLURRED_BUFFER",
                            "starTint": "starTintSymbol"
                        ],
                        "outputs": ["color": "COLOR"]
                    ]
                ],
                "targets": [
                    "CME_BUFFER": ["type": "color"],
                    "SCENE_BUFFER": ["type": "color"],
                    "DISTORTED_BUFFER": ["type": "color"],
                    "BLURRED_BUFFER": ["type": "color"]
                ],
                "sequence": ["mainScenePass", "cmePass", "distortionPass", "blurPass", "tintPass"]
            ]
            
            guard let technique = SCNTechnique(dictionary: techniqueDict) else { return }
            
            // Final attempt: Ensure the tint buffer matches the expected vector4 layout
            let tintValue = NSValue(scnVector4: SCNVector4(
                CGFloat(initialTint.x), CGFloat(initialTint.y),
                CGFloat(initialTint.z), CGFloat(initialTint.w)
            ))
            technique.setValue(tintValue, forKey: "starTintSymbol")
            
            sceneView.technique = technique
        }
    
}

extension SwiftDKNI {
    
    /// Updates the material uniforms for the primary energy tunnels node
    public func updateEnergyTunnelConfigToMaterial(config: EnergyTunnelConfig, node: SCNNode) {
        // Locate the specific node named "energyTunnels"
        guard let tunnelNode = node.childNode(withName: "energyTunnels", recursively: true),
              let material = tunnelNode.geometry?.materials.first else {
            print("Warning: Could not locate node named 'energyTunnels' or its material.")
            return
        }
        
        var tunnelRadius = config.tunnelRadiusBase
        material.setValue(Data(bytes: &tunnelRadius, count: MemoryLayout<Float>.size), forKey: "u_tunnelRadiusBase")
        
        var baseSize = config.particleBaseSize
        material.setValue(Data(bytes: &baseSize, count: MemoryLayout<Float>.size), forKey: "u_particleBaseSize")
        
        var variance = config.particleVariance
        material.setValue(Data(bytes: &variance, count: MemoryLayout<Float>.size), forKey: "u_particleVariance")
        
        var warp = config.warpIntensity
        material.setValue(Data(bytes: &warp, count: MemoryLayout<Float>.size), forKey: "u_warpIntensity")
        
        var boil = config.boilSpeed
        material.setValue(Data(bytes: &boil, count: MemoryLayout<Float>.size), forKey: "u_boilSpeed")
        
        var twinkle = config.twinkleSpeed
        material.setValue(Data(bytes: &twinkle, count: MemoryLayout<Float>.size), forKey: "u_twinkleSpeed")
        
        material.setValue(NSValue(scnVector3: config.coreColor), forKey: "u_coreColor")
        material.setValue(NSValue(scnVector3: config.midColor), forKey: "u_midColor")
        material.setValue(NSValue(scnVector3: config.edgeColor), forKey: "u_edgeColor")
        
        var hdrMultiplier = config.hdrMultiplier
        material.setValue(Data(bytes: &hdrMultiplier, count: MemoryLayout<Float>.size), forKey: "u_hdrMultiplier")
    }
    
    /// Iterates through all Coronal Mass Ejection nodes and updates their global uniform overrides
    public func updateCMEConfigTomaterial(config: CMEConfig, node: SCNNode) {
        // Enumerate through all children to find matching CME prefixes
        node.enumerateChildNodes { (child, stop) in
            guard let name = child.name, name.hasPrefix("CME_"),
                  let material = child.geometry?.materials.first else {
                return
            }
            
            // Update the global timeline and snapshot controls
            material.setValue(NSNumber(value: config.globalTime), forKey: "u_globalTime")
            material.setValue(NSNumber(value: config.scnFrameTimeSnapshot), forKey: "u_scnFrameTimeSnapshot")
            
            // Update physical deformation constraints
            material.setValue(NSNumber(value: config.thickness), forKey: "u_thickness")
            material.setValue(NSNumber(value: config.ejectionMultiplier), forKey: "u_ejectionMultiplier")
            
            // Note: u_loopTime and u_ignitionTime are typically baked per-event during instantiation.
            // If you need to force a global loop duration override on the fly, you can uncomment below:
            // material.setValue(NSNumber(value: Float(config.visualLoopDuration)), forKey: "u_loopTime")
        }
    }

    /// Updates a specific material uniform for the primary energy tunnels node based on a provided key
    public func updateEnergyTunnelConfigToMaterial(config: EnergyTunnelConfig, key: String, node: SCNNode) {
        // Locate the specific node named "energyTunnels"
        guard let tunnelNode = node.childNode(withName: "energyTunnels", recursively: true),
              let material = tunnelNode.geometry?.materials.first else {
            print("Warning: Could not locate node named 'energyTunnels' or its material.")
            return
        }
        
        switch key {
        case "u_tunnelRadiusBase":
            var value = config.tunnelRadiusBase
            material.setValue(Data(bytes: &value, count: MemoryLayout<Float>.size), forKey: key)
            
        case "u_particleBaseSize":
            var value = config.particleBaseSize
            material.setValue(Data(bytes: &value, count: MemoryLayout<Float>.size), forKey: key)
            
        case "u_particleVariance":
            var value = config.particleVariance
            material.setValue(Data(bytes: &value, count: MemoryLayout<Float>.size), forKey: key)
            
        case "u_warpIntensity":
            var value = config.warpIntensity
            material.setValue(Data(bytes: &value, count: MemoryLayout<Float>.size), forKey: key)
            
        case "u_boilSpeed":
            var value = config.boilSpeed
            material.setValue(Data(bytes: &value, count: MemoryLayout<Float>.size), forKey: key)
            
        case "u_twinkleSpeed":
            var value = config.twinkleSpeed
            material.setValue(Data(bytes: &value, count: MemoryLayout<Float>.size), forKey: key)
            
        case "u_coreColor":
            material.setValue(NSValue(scnVector3: config.coreColor), forKey: key)
            
        case "u_midColor":
            material.setValue(NSValue(scnVector3: config.midColor), forKey: key)
            
        case "u_edgeColor":
            material.setValue(NSValue(scnVector3: config.edgeColor), forKey: key)
            
        case "u_dyingColor": // Added for completeness, in case you bind it later
            material.setValue(NSValue(scnVector3: config.dyingColor), forKey: key)
            
        case "u_hdrMultiplier":
            var value = config.hdrMultiplier
            material.setValue(Data(bytes: &value, count: MemoryLayout<Float>.size), forKey: key)
            
        default:
            print("Warning: Unrecognized uniform key '\(key)' for EnergyTunnelConfig.")
        }
    }

    /// Iterates through all Coronal Mass Ejection nodes and updates a specific global uniform override based on a key
    public func updateCMEConfigTomaterial(config: CMEConfig, key: String, node: SCNNode) {
        let valueToSet: Any
        
        // Evaluate the key once before looping to optimize performance
        switch key {
        case "u_globalTime":
            valueToSet = NSNumber(value: config.globalTime)
        case "u_scnFrameTimeSnapshot":
            valueToSet = NSNumber(value: config.scnFrameTimeSnapshot)
        case "u_thickness":
            valueToSet = NSNumber(value: config.thickness)
        case "u_ejectionMultiplier":
            valueToSet = NSNumber(value: config.ejectionMultiplier)
        case "u_loopTime":
            valueToSet = NSNumber(value: Float(config.visualLoopDuration))
        case "u_warpIntensity": // NEW: Added missing warp intensity key
            valueToSet = NSNumber(value: config.warpIntensity)
        case "u_coreColor": // Added in case you switch colors to use this function
            valueToSet = NSValue(scnVector3: config.coreColor)
        case "u_midColor": // Added in case you switch colors to use this function
            valueToSet = NSValue(scnVector3: config.midColor)
        case "u_edgeColor": // Added in case you switch colors to use this function
            valueToSet = NSValue(scnVector3: config.edgeColor)
        default:
            print("Warning: Unrecognized uniform key '\(key)' for CMEConfig.")
            return
        }
        
        // Enumerate through all children to find matching CME prefixes
        node.enumerateChildNodes { (child, stop) in
            guard let name = child.name, name.hasPrefix("CME_"),
                  let material = child.geometry?.materials.first else {
                return
            }
            
            // Apply the pre-calculated uniform value
            material.setValue(valueToSet, forKey: key)
        }
    }

    // Updates thermal node config
    public func updateThermalConfigToMaterial(config: StarThermalConfig, key: String, node: SCNNode) {
            // Locate the specific node named "thermalAtmosphere"
            guard let thermalNode = node.childNode(withName: "thermalAtmosphere", recursively: true),
                  let material = thermalNode.geometry?.materials.first else {
                print("Warning: Could not locate node named 'thermalAtmosphere' or its material.")
                return
            }
            
            switch key {
            case "u_warpIntensity":
                material.setValue(NSNumber(value: config.warpIntensity), forKey: key)
                
            case "u_directionMultiplier":
                material.setValue(NSNumber(value: config.directionMultiplier), forKey: key)
                
            case "u_haloInner":
                material.setValue(NSNumber(value: config.haloInner), forKey: key)
                
            case "u_haloOuter":
                material.setValue(NSNumber(value: config.haloOuter), forKey: key)
                
            case "u_maskMin":
                material.setValue(NSNumber(value: config.maskMin), forKey: key)
                
            case "u_maskMax":
                material.setValue(NSNumber(value: config.maskMax), forKey: key)
                
            case "u_contrastPower":
                material.setValue(NSNumber(value: config.contrastPower), forKey: key)
                
            case "u_minMultiplier":
                material.setValue(NSNumber(value: config.minMultiplier), forKey: key)
                
            case "u_maxMultiplier":
                material.setValue(NSNumber(value: config.maxMultiplier), forKey: key)
                
            case "u_opacity":
                material.setValue(NSNumber(value: config.opacity), forKey: key)
                
            case "u_color":
                material.setValue(NSValue(scnVector3: config.color), forKey: key)
                
            // --- NEW: Added missing blending and color keys ---
            case "u_surfaceColorInfluence":
                material.setValue(NSNumber(value: config.surfaceColorInfluence), forKey: key)
                
            case "u_deepColor":
                material.setValue(NSValue(scnVector3: config.deepColor), forKey: key)
                
            case "u_hotColor":
                material.setValue(NSValue(scnVector3: config.hotColor), forKey: key)
                
            default:
                print("Warning: Unrecognized uniform key '\(key)' for StarThermalConfig.")
            }
        }
}
