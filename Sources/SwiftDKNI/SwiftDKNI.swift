import Foundation
import SceneKit

// MARK: - Core Singleton
final public class SwiftDKNI: Sendable {
    // Initialized with the AstreOS API key
    public static let shared = SwiftDKNI(apiKey: "qnAfMmkLcxyAvwNKV2saZ13raQO7cwvc4a3y97z6")
    
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
            
            // 1. Fetch the averaged data using the stored API key
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
                // (Assuming your AveragedCMEData uses Float? for these properties)
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
                    // Because we are using an SCNProgram, uniforms MUST be passed as Data, not NSNumber
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
                    // The multiply blend creates the dark, high-contrast holes
                    baseMaterial.multiply.contents = sunspotMask
                    baseMaterial.multiply.intensity = 0.85 // Adjust for darkness
                    
                    // 1. The Metal GLSL Shader String
                    let plasmaSwirlShader = """
                    #pragma body

                    // Slow the boil down to a heavy, rolling speed
                    float flowTime = u_time * 0.15;

                    // Stack two different waves (one large/slow, one small/fast) for organic turbulence
                    // The amplitude is dropped all the way down to 0.003
                    float warpX = (sin(_geometry.texcoords[0].y * 12.0 + flowTime) 
                                 + sin(_geometry.texcoords[0].y * 28.0 - flowTime * 1.5)) * 0.003;
                                  
                    float warpY = (cos(_geometry.texcoords[0].x * 14.0 - flowTime) 
                                 + cos(_geometry.texcoords[0].x * 24.0 + flowTime * 1.2)) * 0.003;

                    // Apply the micro-distortion
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
            coronalSurfaceNode.addChildNode(haloNode)
            let haloMaterial = SCNMaterial()
            haloMaterial.lightingModel = .constant
            haloMaterial.writesToDepthBuffer = false
            haloMaterial.blendMode = .alpha

            let sdoService = NASASDOService()
            // Fetch the Coronal Hole mask
            if let coronalHoleMask = try? await sdoService.fetchLatestImage(wavelength: .aia193, resolution: 2048) {
                
                    // Feed the NASA image into the diffuse property
                    haloMaterial.diffuse.contents = coronalHoleMask
                let coronalHoleShader = """
                #pragma transparent
                #pragma body

                // 1. Sample the color of the SDO AIA 193 texture
                float3 textureColor = _surface.diffuse.rgb;

                // 2. Calculate the luminance (how physically bright the pixel is)
                float luminance = dot(textureColor, float3(0.299, 0.587, 0.114));

                // 3. The Magic: Alpha Erosion
                // We use smoothstep to create a harsh threshold. 
                // If the pixel is dark (luminance < 0.15), it's a Coronal Hole -> Alpha becomes 0.0 (invisible)
                // If the pixel is bright (luminance > 0.4), it's dense plasma -> Alpha becomes 1.0 (visible)
                float alphaMask = smoothstep(0.15, 0.4, luminance);

                // 4. Override the visual color to an ethereal atmospheric glow (e.g., icy blue/white)
                // and multiply the final opacity by our eroded alpha mask.
                float3 atmosphereColor = float3(0.7, 0.85, 1.0); 
                _surface.diffuse = float4(atmosphereColor, alphaMask * 0.4); // 40% max opacity so it looks like ghost gas
                """

                // Inject the shader into the surface entry point
                    haloMaterial.shaderModifiers = [
                        .surface: coronalHoleShader
                    ]
            }
            return coronalSurfaceNode
        }
    
}
