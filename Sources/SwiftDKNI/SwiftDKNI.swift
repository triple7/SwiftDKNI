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
    private let renderer = CMEFluxRopeRenderer()
    
    private init(apiKey: String) {
        self.apiKey = apiKey
    }
}

// MARK: - Surface Generation Extension
extension SwiftDKNI {
    
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
            renderCME: Bool = true
        ) async throws -> SCNNode {
            
            // 1. Fetch the averaged data using the securely injected API key
            let request = CMERequest(startDate: startTime, endDate: endTime, apiKey: self.apiKey)
            
            var events: [AveragedCMEData] = []
            do {
                events = try await donkiService.fetchAndAverageCMEData(request: request, cachedIfExists: cachedIfExists)
            } catch {
                print("Warning: CME Generation Failed (\(error)). Proceeding with base sun & magnetic loops only.")
            }
            
            // 2. Create the parent container
            let coronalSurfaceNode = SCNNode()
            
            // 3. Setup Date Parsers to establish t = 0 and timeline boundaries
            let queryFormatter = DateFormatter()
            queryFormatter.dateFormat = "yyyy-MM-dd"
            queryFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            
            let simulationStart = queryFormatter.date(from: startTime) ?? Date()
            let simulationEnd = queryFormatter.date(from: endTime) ?? simulationStart.addingTimeInterval(86400 * 30)
            
            // Calculate the timeline compression ratio (Maps the entire query window into a 60-second visual loop)
            let totalRealSeconds = simulationEnd.timeIntervalSince(simulationStart)
            let visualLoopDuration: Double = 60.0
            let compressionRatio = visualLoopDuration / max(1.0, totalRealSeconds)
            
            let donkiFormatter = DateFormatter()
            donkiFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
            donkiFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            
            let backupISOFormatter = ISO8601DateFormatter()
            backupISOFormatter.formatOptions = [.withInternetDateTime]
            
            let geometryBuilder = CMEGeometryBuilder()
            
            // --- FETCH, BUILD & DEFORM GLOBAL MAGNETIC LOOPS FROM FITS DATA ---
            print("Fetching FITS Magnetogram...")
            let magnetogramModeler = MagnetogramModeler()
            
            var openMagneticLines: [MagneticLoopLine] = []
            var rawMagneticBuckets: [MagneticBucket] = []
            var sharedMagneticVolume: MTLTexture? = nil
            
            let sRadius = Float(sphere.radius)
            
            if let fitsURL = try? await magnetogramModeler.fetchLatestSynopticMagnetogram(cachedIfExists: cachedIfExists),
               let magData = try? magnetogramModeler.processFitsFile(at: fitsURL) {
                
                // 🚨 STAGE 1: THE AMBIENT FIELD
                // Extract un-capped buckets and generate the ambient PFSS Volume Matrix on the CPU
                rawMagneticBuckets = magnetogramModeler.exportRawBuckets(from: magData, thresholdGauss: 20.0)
                
                print("Generating Ambient 3D PFSS Vector Field...")
                // Note: Assuming generateVolumetricFieldFromBuckets returns (volumeData: [simd_float4], texture: MTLTexture?)
                let ambientPFSSArray = self.generateVolumetricFieldFromBuckets(
                    device: device,
                    buckets: rawMagneticBuckets,
                    solarRadius: sRadius
                ).volumeData
                
                // 🚨 STAGE 2: THE GEOMETRY DEFORMATION
                // Trace the base magnetic loop paths from the map
                let magneticLoopStart = CACurrentMediaTime()
                var magneticLines = magnetogramModeler.calculateMagneticLoops(from: magData)
                
                // Intercept splines on CPU to apply ambient field deformation & Solar Rotation
                magneticLines = magneticLines.map { line in
                    // A. Bend the apex based on the ambient voxel vectors
                    var (newP0, newP1, newP2) = self.applyMagneticInfluenceToSpline(
                        startPoint: line.p0,
                        apexPoint: line.p1,
                        endPoint: line.p2,
                        isOpen: line.isOpen,
                        pfssVolume: ambientPFSSArray,
                        solarRadius: sRadius
                    )
                    
                    // B. Apply the Archimedean Parker Spiral twisting force based on solar rotation
                    if line.isOpen {
                        newP1 = self.applySolarRotationShift(point: newP1, solarRadius: sRadius)
                        newP2 = self.applySolarRotationShift(point: newP2, solarRadius: sRadius)
                    } else {
                        newP1 = self.applySolarRotationShift(point: newP1, solarRadius: sRadius, rotationRate: 0.25)
                    }
                    
                    return MagneticLoopLine(p0: newP0, p1: newP1, p2: newP2, isOpen: line.isOpen, intensity: line.intensity)
                }
                
                let magneticLoopEnd = CACurrentMediaTime()
                print("generateCoronalSurfaceUsingMegnetoGram: processed & deformed magnetic loops in \(magneticLoopEnd - magneticLoopStart) seconds.")
                
                openMagneticLines = magneticLines.filter { $0.isOpen }
                
                // 🚨 STAGE 3: THE FLOW FIELD (GPU RASTERIZATION)
                // Rasterize the fully deformed splines into the final 3D Texture for the CMEs
                print("Generating final CME Flow Volume via Spline Rasterization...")
                let volumeResult = self.generateMagneticVolumeTexture(
                    device: device,
                    lines: magneticLines,
                    solarRadius: sRadius
                )
                sharedMagneticVolume = volumeResult.texture
                
                // 🚨 STAGE 4: VISUAL GEOMETRY
                // Construct and add the physical volumetric spline tubes to the scene
                let globalMagneticNode = geometryBuilder.createCoronalSurface(from: magneticLines, solarRadius: sRadius)
                coronalSurfaceNode.addChildNode(globalMagneticNode)
            }
            
            // 4. Generate and align each CME event ONLY if the flag is true
            if renderCME {
                // Create the SceneKit wrapper once outside the loop to protect memory channels
                var sharedVolumeProperty: SCNMaterialProperty? = nil
                if let magneticVolume = sharedMagneticVolume {
                    sharedVolumeProperty = SCNMaterialProperty(contents: magneticVolume)
                    print("✅ Shared PFSS Volume Property mapped safely to KVC engine.")
                }
                
                // DYNAMIC THROTTLE: Distribute the max points across all active events to prevent vertex overflow
                let calculatedPointsPerEvent = max(500, maxPointsPerCME / max(1, events.count))
                
                for event in events {
                    guard event.latitude != nil, event.longitude != nil else { continue }
                    
                    let parsedDate = donkiFormatter.date(from: event.startTime) ?? backupISOFormatter.date(from: event.startTime)
                    guard let eventDate = parsedDate else {
                        print("Skipped CME: Unrecognized Date Format - \(event.startTime)")
                        continue
                    }
                    
                    // Map the real timestamp into the loop timeline using our compression ratio
                    let realIgnitionOffset = eventDate.timeIntervalSince(simulationStart)
                    let safeIgnitionTime = Float(realIgnitionOffset * compressionRatio)
                    
                    let cmeNode = try! renderer.createCoronalEjectionNode(
                        for: event,
                        openLines: openMagneticLines,
                        pointCount: calculatedPointsPerEvent,
                        solarRadius: sRadius
                    )
                    
                    if let material = cmeNode.geometry?.materials.first {
                        material.setValue(NSNumber(value: safeIgnitionTime), forKey: "u_ignitionTime")

                        // Bind the pre-allocated material property containing our 3D texture
                        if let vp = sharedVolumeProperty {
                            material.setValue(vp, forKey: "u_magneticVolume")
                        }
                    }
                    coronalSurfaceNode.addChildNode(cmeNode)
                }
            }
            
            // 5. Fetch the active regions
            let noaaService = NOAADataService()
            let activeRegions = try await noaaService.fetchActiveRegions(cachedIfExists: cachedIfExists)
            
            // Generate the surface layers
            if let sunspotMask = generateSunspotTexture(from: activeRegions, textureSize: CGSize(width: 4096, height: 2048)) {
                if let baseMaterial = sphere.materials.first {
                    
                    baseMaterial.lightingModel = .constant
                    let sdoService = NASASDOService()
                    
                    // --- LAYER 1: Core Surface Plasma (AIA 171) ---
                    if let liveSunTexture = try? await sdoService.fetchLatestImage(wavelength: .aia171, resolution: 4096, cachedIfExists: cachedIfExists) {
                        baseMaterial.diffuse.contents = liveSunTexture
                    }
                    
                    // --- LAYER 2: Active Regions Mask (NOAA) ---
                    baseMaterial.multiply.contents = sunspotMask
                    baseMaterial.multiply.intensity = 0.85
                    
                    // --- LAYER 3: Atmospheric Coronal Holes (AIA 193) ---
                    if let coronalHoleMask = try? await sdoService.fetchLatestImage(wavelength: .aia193, resolution: 4096, cachedIfExists: cachedIfExists) {
                        baseMaterial.transparent.contents = coronalHoleMask
                    } else {
        #if os(macOS)
                        baseMaterial.transparent.contents = NSColor.white
        #else
                        baseMaterial.transparent.contents = UIColor.white
        #endif
                    }
                    
                    // --- SHADER 1: The Geometry Swirl ---
                    let plasmaSwirlShader = """
                        #pragma body
                        
                        float flowTime = u_time * 0.15;
                        
                        float warpX = (sin(_geometry.texcoords[0].y * 12.0 + flowTime) 
                                     + sin(_geometry.texcoords[0].y * 28.0 - flowTime * 1.5)) * 0.003;
                                                                     
                        float warpY = (cos(_geometry.texcoords[0].x * 14.0 - flowTime) 
                                     + cos(_geometry.texcoords[0].x * 24.0 + flowTime * 1.2)) * 0.003;
                        
                        _geometry.texcoords[0].x += warpX;
                        _geometry.texcoords[0].y += warpY;
                        """
                    
                    // --- SHADER 2: Multi-Band Atmosphere Composite ---
                    let multiBandSolarShader = """
                        #pragma transparent
                        #pragma body
                        
                        // 1. Sample the primary surface texture (NOAA / Core Plasma)
                        float4 surfaceColor = _surface.diffuse;
                        
                        // 2. Read the secondary NASA SDO Band texture 
                        float4 uvBandSample = _surface.transparent;
                        float uvIntensity = dot(uvBandSample.rgb, float3(0.299, 0.587, 0.114));
                        
                        // 3. Mathematical Fresnel Profile for the Limb Glow
                        float3 N = normalize(_surface.normal);
                        float3 V = normalize(_surface.view);
                        float edgeFactor = 1.0 - max(0.0, dot(N, V));
                        
                        float atmosphericHaze = pow(edgeFactor, 6.0);
                        
                        // Blend the UV Band Data into the Haze
                        float3 atmosphereColor = float3(0.98, 0.90, 0.75); 
                        float finalAtmosphereOpacity = atmosphericHaze * (0.2 + uvIntensity * 0.8);
                        
                        _surface.diffuse.rgb = mix(surfaceColor.rgb, atmosphereColor, finalAtmosphereOpacity * 0.35);
                        _surface.diffuse.rgb += _surface.emission.rgb;
                        """
                    
                    baseMaterial.shaderModifiers = [
                        .geometry: plasmaSwirlShader,
                        .surface: multiBandSolarShader
                    ]
                }
            }
            
            return coronalSurfaceNode
        }

    public func addDistortionTechniqueToScene(sceneView: SCNView) {
        let techniqueDict: [String: Any] = [
            "symbols": [
                "timeSymbol": [
                    "semantic": "time",
                    "type": "float"
                ]
            ],
            "passes": [
                // PASS 1: Render the whole scene (Sun + Skybox) into SCENE_BUFFER
                "mainScenePass": [
                    "draw": "DRAW_SCENE",
                    "inputs": [:],
                    "outputs": ["color": "SCENE_BUFFER"]
                ],
                // PASS 2: Render ONLY the CMEs into CME_BUFFER
                "cmePass": [
                    "draw": "DRAW_SCENE",
                    "inputs": [:],
                    "outputs": ["color": "CME_BUFFER"],
                    "includeCategoryMask": 4
                ],
                // PASS 3: Composite the scene and the distorted CME_BUFFER
                "distortionPass": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "distortionVertex",
                    "metalFragmentShader": "distortionFragment",
                    "inputs": [
                        "colorSampler": "SCENE_BUFFER",    // Reads from SCENE_BUFFER
                        "refractionSampler": "CME_BUFFER",
                        "time": "timeSymbol"
                    ],
                    "outputs": ["color": "COLOR"]          // Outputs to the final screen
                ]
            ],
            "targets": [
                "CME_BUFFER": [
                    "type": "color",
                    "size": "relative",
                    "scaleFactor": 1.0,
                    "pixelFormat": "rgba8"
                ],
                "SCENE_BUFFER": [
                    "type": "color",
                    "size": "relative",
                    "scaleFactor": 1.0,
                    "pixelFormat": "rgba8"
                ]
            ],
            "sequence": ["mainScenePass", "cmePass", "distortionPass"]
        ]
        
        sceneView.technique = SCNTechnique(dictionary: techniqueDict)
    }
}
