//
//  CMEFluxRopeRenderer.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//


import SceneKit
import Foundation

final public class CMEFluxRopeRenderer: Sendable {
    
    // Instance of your accelerated builder
    private let geometryBuilder = CMEGeometryBuilder()
    
    /// Generates the complete SCNNode containing the accelerated geometry and the Metal shader material.
    /// - Parameters:
    ///   - event: The averaged CME data used to generate the boundary shell.
    ///   - solarRadius: The radius of the SCNSphere representing the Sun.
    /// - Returns: A fully configured SCNNode ready to be added to the scene.
    /// Generates the complete SCNNode, loading the custom Metal shader from the Documents directory.
    func createCoronalEjectionNode(for event: AveragedCMEData, pointCount: Int, solarRadius: Float = 1.0) throws -> SCNNode {
        
        // 1. Generate the base point cloud geometry
        let geometry = geometryBuilder.buildBoundaryShellAccelerated(
            for: event,
            pointCount: pointCount,
            solarRadius: solarRadius
        )
        
        // 2. Create the Material & Program
        let material = SCNMaterial()
        let program = SCNProgram()
        
        // 3. Load and Compile the Metal Script from Documents/stars
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "Metal", code: 0, userInfo: [NSLocalizedDescriptionKey: "Metal not supported"])
        }
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let shaderURL = documentsURL.appendingPathComponent("stars/coronal.metal")
        
        let metalSource = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: metalSource, options: nil)
        
        // Assign the compiled library to the SceneKit program
        program.library = library
        program.vertexFunctionName = "coronal_vertex_main"
        program.fragmentFunctionName = "coronal_fragment_main"
        
        // 4. Map the Data Semantics explicitly
        program.setSemantic(SCNGeometrySource.Semantic.vertex.rawValue, forSymbol: "in.position", options: nil)
        program.setSemantic(SCNGeometrySource.Semantic.normal.rawValue, forSymbol: "in.normal", options: nil)
        program.setSemantic(SCNModelViewProjectionTransform, forSymbol: "scn_node", options: nil)
        
        // 5. Configure Material properties for the glowing plasma effect
        material.program = program
        material.lightingModel = .constant
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        material.blendMode = .add
        
        // Create a variation of thickness
        var thickness: Float = 0.3 // 30% speed variance
        material.setValue(Data(bytes: &thickness, count: MemoryLayout<Float>.size), forKey: "u_thickness")
        // 6. Bind the Uniforms using Data payloads (required for SCNProgram)
        // Global time will be updated continuously by your render loop
        var initialTime: Float = 0.0
        material.setValue(Data(bytes: &initialTime, count: MemoryLayout<Float>.size), forKey: "u_globalTime")
        
        // Ignition Time (Set to 0.0 here, updated by the alignment function later)
        var ignitionTime: Float = 0.0
        material.setValue(Data(bytes: &ignitionTime, count: MemoryLayout<Float>.size), forKey: "u_ignitionTime")
        
        // Speed
        let visualSpeedScale: Float = 0.001
        var scaledSpeed = Float(event.speed) * visualSpeedScale
        material.setValue(Data(bytes: &scaledSpeed, count: MemoryLayout<Float>.size), forKey: "u_speed")
        
        // Half Angle
        var halfAngleRad = Float(event.halfAngle) * .pi / 180.0
        material.setValue(Data(bytes: &halfAngleRad, count: MemoryLayout<Float>.size), forKey: "u_halfAngle")
        
        geometry.materials = [material]
        
        return SCNNode(geometry: geometry)
    }
    
    
}
