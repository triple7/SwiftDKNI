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
            eventSpeed: Float(event.speed),
            openLines: openLines,
            pointCount: pointCount,
            solarRadius: solarRadius
        )
        
        // Prevent the CPU from aggressively culling the geometry
        let bound = CGFloat(solarRadius * 10.0)
        geometry.boundingBox = (min: SCNVector3(-bound, -bound, -bound), max: SCNVector3(bound, bound, bound))
        
        let material = SCNMaterial()
        
        // --- PBR UPGRADE ---
        material.lightingModel = .physicallyBased
        material.blendMode = .add
        material.readsFromDepthBuffer = true  // CRITICAL: So CMEs hide behind the sun
        material.writesToDepthBuffer = false  // Keep false so additive plasma particles blend
        material.isDoubleSided = true
        
        // Allocate channels and kill ambient reflection
#if os(macOS)
        material.diffuse.contents = NSColor.black
        material.specular.contents = NSColor.black
        material.emission.contents = NSColor.black // Force SceneKit to allocate _surface.emission
#else
        material.diffuse.contents = UIColor.black
        material.specular.contents = UIColor.black
        material.emission.contents = UIColor.black
#endif
        
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
        
        let thickness: Float = 0.3
        material.setValue(thickness, forKey: "u_thickness")
        
        let initialTime: Float = 0.0
        material.setValue(initialTime, forKey: "u_globalTime")
        
        let ignitionTime: Float = 0.0
        material.setValue(ignitionTime, forKey: "u_ignitionTime")
        
        let visualSpeedScale: Float = 0.001
        let scaledSpeed = Float(event.speed) * visualSpeedScale
        material.setValue(scaledSpeed, forKey: "u_speed")
        
        material.setValue(NSNumber(value: solarRadius), forKey: "u_solarRadius")
        let halfAngleRad = Float(event.halfAngle ?? 45.0) * .pi / 180.0
        material.setValue(halfAngleRad, forKey: "u_halfAngle")
        
        geometry.materials = [material]
        
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 2
        
        return node
    }
    
}
