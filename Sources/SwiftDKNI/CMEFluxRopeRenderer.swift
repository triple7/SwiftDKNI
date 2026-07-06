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
        openLines: [MagneticLoopLine],
        pointCount: Int,
        solarRadius: Float = 1.0
    ) throws -> SCNNode {
        
        let geometry = geometryBuilder.buildDONKICorrelatedCMECloud(
            eventLatitude: Float(event.latitude ?? 0.0),
            eventLongitude: Float(event.longitude ?? 0.0),
            eventHalfAngle: Float(event.halfAngle ?? 45.0),
            openLines: openLines,
            pointCount: pointCount, // 🚨 The source of the geometry explosion
            solarRadius: solarRadius
        )
        
        // Prevent the CPU from aggressively culling the geometry
        let bound = CGFloat(solarRadius * 10.0)
        geometry.boundingBox = (min: SCNVector3(-bound, -bound, -bound), max: SCNVector3(bound, bound, bound))
        
        let material = SCNMaterial()
        
        // Assign a basic color to diffuse to lock the UV channels open
#if os(macOS)
        material.diffuse.contents = NSColor.white
#else
        material.diffuse.contents = UIColor.white
#endif
        material.diffuse.mappingChannel = 0
        material.transparent.mappingChannel = 0

        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let geometryShaderURL = documentsURL.appendingPathComponent("stars/coronal_geometry.metal")
        let fragmentShaderURL = documentsURL.appendingPathComponent("stars/coronal_fragment.metal")
        let geometrySource = try String(contentsOf: geometryShaderURL, encoding: .utf8)
        let fragmentSource = try String(contentsOf: fragmentShaderURL, encoding: .utf8)
        
        material.shaderModifiers = [
            .geometry: geometrySource,
            .surface: fragmentSource
        ]
        
        // --- 🚨 CRITICAL BLEND & DEPTH FIXES ---
        material.blendMode = .add
        material.lightingModel = .constant
        
        // Must read from depth buffer so the sun occludes particles behind it!
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        
        // 3. Safely box Floats for SceneKit KVC
        
        var thicknessFloat: Float = 0.3
        material.setValue(Data(bytes: &thicknessFloat, count: MemoryLayout<Float>.size), forKey: "u_thickness")
        
        var initialTimeFloat: Float = 0.0
        material.setValue(Data(bytes: &initialTimeFloat, count: MemoryLayout<Float>.size), forKey: "u_globalTime")
        
        var ignitionTimeFloat: Float = 0.0
        material.setValue(Data(bytes: &ignitionTimeFloat, count: MemoryLayout<Float>.size), forKey: "u_ignitionTime")
        
        var visualSpeedScale: Float = 0.001
        var scaledSpeedFloat: Float = Float(event.speed) * visualSpeedScale
        material.setValue(Data(bytes: &scaledSpeedFloat, count: MemoryLayout<Float>.size), forKey: "u_speed")
        
        var solarRadiusFloat: Float = solarRadius
        material.setValue(Data(bytes: &solarRadiusFloat, count: MemoryLayout<Float>.size), forKey: "u_solarRadius")
        
        var halfAngleFloat: Float = Float(event.halfAngle ?? 45.0) * .pi / 180.0
        material.setValue(Data(bytes: &halfAngleFloat, count: MemoryLayout<Float>.size), forKey: "u_halfAngle")
        geometry.materials = [material]
        
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 2
        
        return node
    }
    
}
