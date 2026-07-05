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
            sphere: SCNSphere,
            pointsPerEvent: Int,
            startTime: String,
            endTime: String,
            cachedIfExists: Bool = true, // Retained cache flag
            renderCME: Bool = true // ADDED: Global CME render flag
        ) async throws -> SCNNode {
            
            // 1. Fetch the averaged data using the securely injected API key
            let request = CMERequest(startDate: startTime, endDate: endTime, apiKey: self.apiKey)
            
            // FIX: Trap the error. If DONKI fails (like a 503), default to an empty array
            // instead of throwing and aborting the entire render.
            var events: [AveragedCMEData] = []
            do {
                // ADDED: Passed cachedIfExists flag
                events = try await donkiService.fetchAndAverageCMEData(request: request, cachedIfExists: cachedIfExists)
            } catch {
                print("Warning: CME Generation Failed (\(error)). Proceeding with base sun & magnetic loops only.")
            }
            
            // 2. Create the parent container
            let coronalSurfaceNode = SCNNode()
            
            // 3. Setup Date Parsers to establish t = 0
            let queryFormatter = DateFormatter()
            queryFormatter.dateFormat = "yyyy-MM-dd"
            queryFormatter.timeZone = TimeZone(secondsFromGMT: 0) // Align to UTC
            let simulationStart = queryFormatter.date(from: startTime) ?? Date()
            
            // Trap 1 Fix: NASA DONKI Format: "yyyy-MM-dd'T'HH:mm'Z'"
            let donkiFormatter = DateFormatter()
            donkiFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
            donkiFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            
            let backupISOFormatter = ISO8601DateFormatter()
            backupISOFormatter.formatOptions = [.withInternetDateTime]
            
            let geometryBuilder = CMEGeometryBuilder()
            
            // --- NEW: FETCH & BUILD GLOBAL MAGNETIC LOOPS FROM FITS DATA ---
            print("Fetching FITS Magnetogram...")
            let magnetogramModeler = MagnetogramModeler()
            
            // ADDED: Create a local array to hold the open lines for the CME generator
            var openMagneticLines: [MagneticLoopLine] = []
            
            // ADDED: Passed cachedIfExists flag
            if let fitsURL = try? await magnetogramModeler.fetchLatestSynopticMagnetogram(cachedIfExists: cachedIfExists),
               let magData = try? magnetogramModeler.processFitsFile(at: fitsURL) {
                
                // Calculate the 3D loop splines from the flat FITS image
                let magneticLoopStart = CACurrentMediaTime()
                let magneticLines = magnetogramModeler.calculateMagneticLoops(from: magData)
                let magneticLoopEnd = CACurrentMediaTime()
                print("generateCoronalSurfaceUsingMegnetoGram: processed magnetic loops in \(magneticLoopEnd - magneticLoopStart) seconds.")
                
                // ADDED: Filter and store only the open lines!
                openMagneticLines = magneticLines.filter { $0.isOpen }
                
                // Create the SceneKit node with glowing plasma materials already applied
                let globalMagneticNode = geometryBuilder.createCoronalSurface(from: magneticLines, solarRadius: Float(sphere.radius))
                coronalSurfaceNode.addChildNode(globalMagneticNode)
            }
            
            // 4. Generate and align each CME event ONLY if the flag is true
            if renderCME {
                for event in events {
                    
                    // Trap 2 Fix: Drop far-sided events missing coordinate data
                    guard event.latitude != nil, event.longitude != nil else {
                        print("Skipped CME: Missing spatial coordinates (Far-sided event)")
                        continue
                    }
                    
                    let parsedDate = donkiFormatter.date(from: event.startTime) ?? backupISOFormatter.date(from: event.startTime)
                    
                    guard let eventDate = parsedDate else {
                        print("Skipped CME: Unrecognized Date Format - \(event.startTime)")
                        continue
                    }
                    
                    let ignitionOffset = Float(eventDate.timeIntervalSince(simulationStart))
                    let safeIgnitionTime = max(0.0, ignitionOffset)
                    
                    // Generate the specialized node using the SCNSphere's exact physical radius
                    // ADDED: We now pass the openMagneticLines to map the DONKI event to the FITS splines
                    let cmeNode = try! renderer.createCoronalEjectionNode(
                        for: event,
                        openLines: openMagneticLines,
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
                    
                    // NOTE: We no longer generate local magnetic loop geometries per event here,
                    // as the entire global field is handled by the Magnetogram FITS block above!
                }
            }
            
            // 5. Fetch the active regions
            let noaaService = NOAADataService()
            // ADDED: Passed cachedIfExists flag
            let activeRegions = try await noaaService.fetchActiveRegions(cachedIfExists: cachedIfExists)
            
            // Generate the surface layers
            if let sunspotMask = generateSunspotTexture(from: activeRegions, textureSize: CGSize(width: 4096, height: 2048)) {
                if let baseMaterial = sphere.materials.first {
                    
                    baseMaterial.lightingModel = .constant
                    let sdoService = NASASDOService()
                    
                    // --- LAYER 1: Core Surface Plasma (AIA 171) ---
                    // ADDED: Passed cachedIfExists flag
                    if let liveSunTexture = try? await sdoService.fetchLatestImage(wavelength: .aia171, resolution: 4096, cachedIfExists: cachedIfExists) {
                        baseMaterial.diffuse.contents = liveSunTexture
                    }
                    
                    // --- LAYER 2: Active Regions Mask (NOAA) ---
                    baseMaterial.multiply.contents = sunspotMask
                    baseMaterial.multiply.intensity = 0.85
                    
                    // --- LAYER 3: Atmospheric Coronal Holes (AIA 193) ---
                    // ADDED: Passed cachedIfExists flag
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
