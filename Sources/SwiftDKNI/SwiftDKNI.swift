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
    
            // Fetch the regions
            let noaaService = NOAADataService()
            let activeRegions = try await noaaService.fetchActiveRegions()

            // Generate the mask
            if let sunspotMask = generateSunspotTexture(from: activeRegions) {
                if let baseMaterial = sphere.materials.first {
                    baseMaterial.lightingModel = .constant
                    // Fetch the latest 2K image from SDO (AIA 171 is the classic, high-contrast gold plasma)
                    let sdoService = NASASDOService()
                    if let liveSunTexture = try? await sdoService.fetchLatestImage(wavelength: .aia171, resolution: 2048) {
                        baseMaterial.diffuse.contents = liveSunTexture
                    }
                    
                    baseMaterial.multiply.contents = sunspotMask
                    baseMaterial.multiply.intensity = 0.85
                    
                    // 1. The Metal GLSL Shader String
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
                    
                    // 2. Inject it into the material
                    baseMaterial.shaderModifiers = [
                        .geometry: plasmaSwirlShader
                    ]
                }
            }
            
            // Create the Halo (5% larger than the base star)
            let haloRadius = sphere.radius * 1.05
            let haloSphere = SCNSphere(radius: CGFloat(haloRadius))
            let haloNode = SCNNode(geometry: haloSphere)
            haloNode.isHidden = true
            coronalSurfaceNode.addChildNode(haloNode)
            let haloMaterial = SCNMaterial()
            haloMaterial.lightingModel = .constant
            haloMaterial.writesToDepthBuffer = false
            haloMaterial.blendMode = .alpha

            let sdoService = NASASDOService()
            // Fetch the Coronal Hole mask
            if let coronalHoleMask = try? await sdoService.fetchLatestImage(wavelength: .aia193, resolution: 2048) {
                
                haloMaterial.diffuse.contents = coronalHoleMask
                let coronalHoleShader = """
                #pragma transparent
                #pragma body

                // 1. Sample the real-time SDO AIA 193 texture
                float3 textureColor = _surface.diffuse.rgb;
                float luminance = dot(textureColor, float3(0.299, 0.587, 0.114));

                // 2. The Fresnel Calculation: Determine the viewing angle
                // 'viewDir' is the vector from the camera to the pixel.
                // 'normal' is the surface direction pointing outward.
                float3 N = normalize(_surface.normal);
                float3 V = normalize(_surface.viewDir);

                // dot(N, V) is 1.0 at the absolute center of the star, and drops to 0.0 at the exact horizon edge.
                float edgeFade = dot(N, V);

                // 3. Create the organic atmosphere falloff
                // We want the atmosphere to be invisible in the middle, swell slightly near the edges, 
                // but smoothly drop to 0 opacity right before it hits the hard geometry edge.
                float atmosphereGlow = pow(1.0 - edgeFade, 3.0) * edgeFade;

                // 4. Layer the Coronal Holes back in
                // Instead of a harsh cut, the coronal holes smoothly damp down the glow intensity.
                float holeMask = smoothstep(0.05, 0.6, luminance);

                // Combine the organic glow profile with the dynamic solar data
                float finalAlpha = atmosphereGlow * holeMask;

                // 5. Output a natural, hot-plasma cream/pale-gold atmospheric haze
                float3 plasmaColor = float3(0.95, 0.85, 0.7); 
                _surface.diffuse = float4(plasmaColor, finalAlpha * 0.6); // 60% peak opacity within the cloud
                """
                
                haloMaterial.shaderModifiers = [
                    .surface: coronalHoleShader
                ]
            }
            return coronalSurfaceNode
        }
}
