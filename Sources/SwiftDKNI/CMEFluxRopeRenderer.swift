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
        
        // 2. Create the Material
        let material = SCNMaterial()
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let geometryShaderURL = documentsURL.appendingPathComponent("stars/coronal_geometry.metal")
        let fragmentShaderURL = documentsURL.appendingPathComponent("stars/coronal_fragment.metal")
        let geometrySource = try String(contentsOf: geometryShaderURL, encoding: .utf8)
        let fragmentSource = try String(contentsOf: fragmentShaderURL, encoding: .utf8)
        material.shaderModifiers = [
            .geometry: geometrySource,
            .fragment: fragmentSource
        ]
        material.blendMode = .add
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        
        // 4. Bind Uniforms natively (No Data buffers required)
        // Make sure these keys EXACTLY match the names in your #pragma arguments block
        
        let thickness: Float = 0.3
        material.setValue(thickness, forKey: "u_thickness")
        
        let initialTime: Float = 5.0 // set to 0.0 when animating
        material.setValue(initialTime, forKey: "u_globalTime")
        
        let ignitionTime: Float = 0.0
        material.setValue(ignitionTime, forKey: "u_ignitionTime")
        
        let visualSpeedScale: Float = 0.001
        let scaledSpeed = Float(event.speed) * visualSpeedScale
        material.setValue(scaledSpeed, forKey: "u_speed")
        
        let halfAngleRad = Float(event.halfAngle) * .pi / 180.0
        material.setValue(halfAngleRad, forKey: "u_halfAngle")
        
        geometry.materials = [material]
        // Add the distortion bitmask to pick up the SCNTechnique
        
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 2
        return node
    }
}
