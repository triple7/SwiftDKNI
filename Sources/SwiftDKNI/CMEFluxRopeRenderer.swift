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
    func createCoronalEjectionNode(
        for event: AveragedCMEData,
        openLines: [MagneticLoopLine], // ADDED: Now accepts the FITS lines
        pointCount: Int,
        solarRadius: Float = 1.0
    ) throws -> SCNNode {
        
        // 1. Generate the correlated point cloud geometry
        // We extract the DONKI spatial data to filter the FITS magnetic lines
        let geometry = geometryBuilder.buildDONKICorrelatedCMECloud(
            eventLatitude: Float(event.latitude ?? 0.0),
            eventLongitude: Float(event.longitude ?? 0.0),
            eventHalfAngle: Float(event.halfAngle ?? 45.0),
            openLines: openLines,
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
        
        // FIX: Swapped .fragment to .surface to preserve your HDR Vertex Colors (No more pink!)
        material.shaderModifiers = [
            .geometry: geometrySource,
            .surface: fragmentSource
        ]
        
        material.blendMode = .add
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        
        // 4. Bind Uniforms natively (No Data buffers required)
        let thickness: Float = 0.3
        material.setValue(thickness, forKey: "u_thickness")
        
        let initialTime: Float = 0.0
        material.setValue(initialTime, forKey: "u_globalTime")
        
        let ignitionTime: Float = 0.0
        material.setValue(ignitionTime, forKey: "u_ignitionTime")
        
        let visualSpeedScale: Float = 0.001
        let scaledSpeed = Float(event.speed) * visualSpeedScale
        material.setValue(scaledSpeed, forKey: "u_speed")
        
        let halfAngleRad = Float(event.halfAngle ?? 45.0) * .pi / 180.0
        material.setValue(halfAngleRad, forKey: "u_halfAngle")
        
        geometry.materials = [material]
        
        let node = SCNNode(geometry: geometry)
        // Add the distortion bitmask to pick up the SCNTechnique
        node.categoryBitMask = 2
        
        return node
    }
    
}
