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
        // The simulation starts exactly at the requested start date
        let simulationStart = queryFormatter.date(from: startTime) ?? Date()
        
        // DONKI dates are returned in ISO8601 format (e.g., "2026-05-01T12:00Z")
        let isoFormatter = ISO8601DateFormatter()
        // Some DONKI endpoints omit the fractional seconds but keep the Z.
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        // 4. Generate and align each event
        for event in events {
            guard let eventDate = isoFormatter.date(from: event.startTime) else {
                continue
            }
            
            // Calculate the time offset in seconds from the start of the simulation
            let ignitionOffset = Float(eventDate.timeIntervalSince(simulationStart))
            
            // Prevent historical events from throwing negative time offsets if data overlaps
            let safeIgnitionTime = max(0.0, ignitionOffset)
            
            // Generate the specialized node using the SCNSphere's exact physical radius
            let cmeNode = renderer.createCoronalEjectionNode(
                for: event,
                pointCount: pointsPerEvent,
                solarRadius: Float(sphere.radius)
            )
            
            // Bind the calculated ignition time to the node's material
            if let material = cmeNode.geometry?.materials.first {
                material.setValue(NSNumber(value: safeIgnitionTime), forKey: "u_ignitionTime")
            }
            
            coronalSurfaceNode.addChildNode(cmeNode)
        }
        
        return coronalSurfaceNode
    }
}
