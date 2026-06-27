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
    public func generateCoronalSurface(
        sphere: SCNSphere,
        pointsPerEvent: Int,
        startTime: String,
        endTime: String
    ) async throws -> SCNNode {
        
        // 1. Fetch the averaged data using the securely injected API key
        let request = CMERequest(startDate: startTime, endDate: endTime, apiKey: self.apiKey)
        let events = try await donkiService.fetchAndAverageCMEData(request: request)
        
        // 2. Create the parent container
        let coronalSurfaceNode = SCNNode()
        
        // 3. Setup Date Parsers to establish t = 0
        let queryFormatter = DateFormatter()
        queryFormatter.dateFormat = "yyyy-MM-dd"
        queryFormatter.timeZone = TimeZone(secondsFromGMT: 0) // Align to UTC
        // The simulation starts exactly at the requested start date
        let simulationStart = queryFormatter.date(from: startTime) ?? Date()
        
        // Trap 1 Fix: NASA DONKI Format: "yyyy-MM-dd'T'HH:mm'Z'" (Missing seconds)
        let donkiFormatter = DateFormatter()
        donkiFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        donkiFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        let backupISOFormatter = ISO8601DateFormatter()
        backupISOFormatter.formatOptions = [.withInternetDateTime]
        
        // magnetic loop material across events
        let geometryBuilder = CMEGeometryBuilder()
        let magneticLoopMaterial = geometryBuilder.createMagneticLoopMaterial()
        magneticLoopMaterial.lightingModel = .constant
        magneticLoopMaterial.blendMode = .add
        magneticLoopMaterial.writesToDepthBuffer = false
        // Optional: Makes the lines thicker and softer if supported by Metal
        magneticLoopMaterial.isDoubleSided = true
        
        // 4. Generate and align each event
        for event in events {
            
            // Trap 2 Fix: Drop far-sided events missing coordinate data
            guard event.latitude != nil, event.longitude != nil else {
                print("Skipped CME: Missing spatial coordinates (Far-sided event)")
                continue
            }
            
            // Try NASA's truncated string first, fallback to strict ISO
            let parsedDate = donkiFormatter.date(from: event.startTime) ?? backupISOFormatter.date(from: event.startTime)
            
            guard let eventDate = parsedDate else {
                print("Skipped CME: Unrecognized Date Format - \(event.startTime)")
                continue
            }
            
            // Calculate the time offset in seconds from the start of the simulation
            let ignitionOffset = Float(eventDate.timeIntervalSince(simulationStart))
            
            // Prevent historical events from throwing negative time offsets if data overlaps
            let safeIgnitionTime = max(0.0, ignitionOffset)
            
            // Generate the specialized node using the SCNSphere's exact physical radius
            let cmeNode = try! renderer.createCoronalEjectionNode(
                for: event,
                pointCount: pointsPerEvent,
                solarRadius: Float(sphere.radius)
            )
            
            // Bind the calculated ignition time to the node's material
            if let material = cmeNode.geometry?.materials.first {
                var ignitionFloat = safeIgnitionTime
                let ignitionData = Data(bytes: &ignitionFloat, count: MemoryLayout<Float>.size)
                material.setValue(ignitionData, forKey: "u_ignitionTime")
            }
            
            coronalSurfaceNode.addChildNode(cmeNode)
            
            // Add the magnetic loops
            let magneticLoopNode = SCNNode()
            let magneticLoopGeometry = geometryBuilder.buildMagneticLoops(for: event, solarRadius: Float(sphere.radius))
            magneticLoopGeometry.materials = [magneticLoopMaterial]
            magneticLoopNode.geometry = magneticLoopGeometry
            coronalSurfaceNode.addChildNode(magneticLoopNode)
            
            
        }
        
        // Fetch the active regions
        let noaaService = NOAADataService()
        let activeRegions = try await noaaService.fetchActiveRegions()
        
        // Generate the surface layers
        if let sunspotMask = generateSunspotTexture(from: activeRegions) {
            if let baseMaterial = sphere.materials.first {
                
                baseMaterial.lightingModel = .constant
                let sdoService = NASASDOService()
                
                // --- LAYER 1: Core Surface Plasma (AIA 171) ---
                if let liveSunTexture = try? await sdoService.fetchLatestImage(wavelength: .aia171, resolution: 2048) {
                    baseMaterial.diffuse.contents = liveSunTexture
                }
                
                // --- LAYER 2: Active Regions Mask (NOAA) ---
                baseMaterial.multiply.contents = sunspotMask
                baseMaterial.multiply.intensity = 0.85
                
                // --- LAYER 3: Atmospheric Coronal Holes (AIA 193) ---
                // We map this to the transparent slot purely to upload it to the GPU for the shader
                if let coronalHoleMask = try? await sdoService.fetchLatestImage(wavelength: .aia193, resolution: 2048) {
                    baseMaterial.transparent.contents = coronalHoleMask
                } else {
                    // Fallback to pure white if the NASA API drops the request to prevent a purple shadow
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
                // SceneKit pre-samples the transparent material property for us
                float4 uvBandSample = _surface.transparent;
                float uvIntensity = dot(uvBandSample.rgb, float3(0.299, 0.587, 0.114));

                // 3. Mathematical Fresnel Profile for the Limb Glow
                float3 N = normalize(_surface.normal);
                float3 V = normalize(_surface.view); // FIXED: Apple uses '_surface.view'
                float edgeFactor = 1.0 - max(0.0, dot(N, V));

                // Sharpens the curve: It keeps the atmosphere completely invisible on the front face,
                // and forces it to swell up rapidly ONLY as it reaches the absolute edge.
                float atmosphericHaze = pow(edgeFactor, 6.0); // Cranked from 4.0 to 6.0

                // Blend the UV Band Data into the Haze
                float3 atmosphereColor = float3(0.98, 0.90, 0.75); 
                float finalAtmosphereOpacity = atmosphericHaze * (0.2 + uvIntensity * 0.8);

                // Drop the overall mix factor from 0.5 to 0.35 to let the heavy orange plasma breathe
                _surface.diffuse.rgb = mix(surfaceColor.rgb, atmosphereColor, finalAtmosphereOpacity * 0.35);
                // Ensure the blinding white-hot CME loops can still burn right through the mix
                _surface.diffuse.rgb += _surface.emission.rgb;
                """
                
                // Apply both shader modifiers simultaneously
                baseMaterial.shaderModifiers = [
                    .geometry: plasmaSwirlShader,
                    .surface: multiBandSolarShader
                ]
            }
        }
        
        return coronalSurfaceNode
    }
}
