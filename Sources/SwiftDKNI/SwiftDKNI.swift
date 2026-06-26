import Foundation
import SceneKit

// MARK: - Core Singleton
final public class SwiftDKNI:Sendable {
    public static let shared = SwiftDKNI()
    
    // Hold references to our pipeline services
    private let donkiService = DONKIService()
    private let renderer = CMEFluxRopeRenderer()
    
    private init() {}
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
            
            // 1. Fetch the averaged data
            let request = CMERequest(startDate: startTime, endDate: endTime, apiKey: "DEMO_KEY")
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
            
            return coronalSurfaceNode
        }
    
}
