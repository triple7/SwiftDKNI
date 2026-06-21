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
    func createCoronalEjectionNode(for event: AveragedCMEData, pointCount: Int, solarRadius: Float = 1.0) -> SCNNode {
        
        // 1. Generate the base point cloud geometry
        let geometry = geometryBuilder.buildBoundaryShellAccelerated(
            for: event, 
            pointCount: pointCount,
            solarRadius: solarRadius
        )
        
        // 2. Configure the Plasma Material
        let material = SCNMaterial()
        material.lightingModel = .constant       // Plasma emits its own light; ignores scene shadows
        material.readsFromDepthBuffer = true     // Honors physical objects in front of it
        material.writesToDepthBuffer = false     // Prevents point sprites from unnaturally occluding each other
        material.blendMode = .add                // Additive blending creates the intense, bright plasma glow
        
        // 3. Attach the Vertex Shader Modifier
        material.shaderModifiers = [
            .geometry: getCoronalVertexShader()
        ]
        
        // 4. Bind the Custom Uniforms
        // Map the real-world speed to a visual scale factor suitable for SceneKit coordinates
        let visualSpeedScale: Float = 0.001 
        let scaledSpeed = Float(event.speed) * visualSpeedScale
        material.setValue(NSNumber(value: scaledSpeed), forKey: "u_speed")
        
        // Convert the half-angle to radians for the Metal shader's trigonometric functions
        let halfAngleRad = Float(event.halfAngle) * .pi / 180.0
        material.setValue(NSNumber(value: halfAngleRad), forKey: "u_halfAngle")
        
        // Initialize the animation timer
        material.setValue(NSNumber(value: 0.0), forKey: "u_time")
        
        geometry.materials = [material]
        
        // 5. Wrap and return the node
        let cmeNode = SCNNode(geometry: geometry)
        return cmeNode
    }
    
    /// Helper function providing the Metal vertex shader modifier string.
    private func getCoronalVertexShader() -> String {
        return """
        // Declare the custom variables bound from Swift via material.setValue()
        #pragma arguments
        float u_time;
        float u_speed;
        float u_halfAngle;
        
        #pragma body
        
        // 1. Establish the alignment of the particle
        // We use the default local Z-axis as the baseline unrotated center of the cap
        float3 centerAxis = float3(0.0, 0.0, 1.0); 
        
        // Compare the particle's outward normal (baked in Swift) against the center axis
        float alignment = dot(_geometry.normal, centerAxis);
        
        // 2. The Flux Rope Shaping Function
        float edgeThreshold = cos(u_halfAngle);
        float normalizedPosition = saturate((alignment - edgeThreshold) / (1.0 - edgeThreshold));
        
        // 3. Apply the morphology curve
        // Taking the square root inflates the center into a bulbous apex while keeping the edges thin
        float morphologyCurve = sqrt(normalizedPosition);
        
        // 4. Compute the expansion delta
        // Particles at the apex (curve = 1.0) move at max u_speed. Legs (curve = 0.0) stay anchored.
        float dynamicExpansion = u_speed * u_time * morphologyCurve;
        
        // 5. Transform the vertex outward along its normal
        _geometry.position.xyz += _geometry.normal * dynamicExpansion;
        
        // Pass the structural density (morphology) to the fragment shader's alpha channel
        _geometry.color = float4(1.0, 1.0, 1.0, morphologyCurve);
        """
    }
}
