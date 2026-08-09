//
//  SwiftDKNI+thermalAtmosphere.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 10/8/2026.
//

import SceneKit
import Metal
import Foundation

extension SwiftDKNI {
    
    public func generateThermalAtmosphericNode(
        radius: Float,
        thermalRadius: Float,
        surfaceContents: Any, // Accept Any (handles MTLTexture, NSImage, or UIImage safely)
        voxelCube: MTLTexture,
        config: StarThermalConfig = StarThermalConfig()
    ) -> SCNNode {
        
        let thermalShellRadius = radius * thermalRadius
        let thermalSphere = SCNSphere(radius: CGFloat(thermalShellRadius))
        thermalSphere.segmentCount = 256
        
        let thermalMaterial = SCNMaterial()
        thermalMaterial.lightingModel = .constant
        thermalMaterial.blendMode = .add
        thermalMaterial.writesToDepthBuffer = false
        thermalMaterial.readsFromDepthBuffer = true
        thermalMaterial.isDoubleSided = true
        
#if os(macOS)
        thermalMaterial.diffuse.contents = NSColor.white
#else
        thermalMaterial.diffuse.contents = UIColor.white
#endif
        
        // Load the Metal Modifiers
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let geometryShaderURL = documentsURL.appendingPathComponent("stars/thermal_geometry.metal")
        let surfaceShaderURL = documentsURL.appendingPathComponent("stars/thermal_surface.metal")
        
        do {
            let geometrySource = try String(contentsOf: geometryShaderURL, encoding: .utf8)
            let surfaceSource = try String(contentsOf: surfaceShaderURL, encoding: .utf8)
            
            thermalMaterial.shaderModifiers = [
                .geometry: geometrySource,
                .surface: surfaceSource
            ]
        } catch {
            print("CRITICAL: Failed to load Thermal shader files: \(error)")
            thermalMaterial.shaderModifiers = [:]
        }
        
        // Bind scalars
        var warpIntensity = config.warpIntensity
        var directionMultiplier = config.directionMultiplier
        var shaderThermalRadius = thermalShellRadius
        
        thermalMaterial.setValue(Data(bytes: &warpIntensity, count: MemoryLayout<Float>.size), forKey: "u_warpIntensity")
        thermalMaterial.setValue(Data(bytes: &directionMultiplier, count: MemoryLayout<Float>.size), forKey: "u_directionMultiplier")
        thermalMaterial.setValue(Data(bytes: &shaderThermalRadius, count: MemoryLayout<Float>.size), forKey: "u_thermalRadius")
        
        // Bind the 3D voxel grid
        let voxelProperty = SCNMaterialProperty(contents: voxelCube)
        thermalMaterial.setValue(voxelProperty, forKey: "voxelCube")
        
        // Safely wrap whatever content type the surface gave us into an SCNMaterialProperty for the shader
        let surfaceProperty = SCNMaterialProperty(contents: surfaceContents)
        thermalMaterial.setValue(surfaceProperty, forKey: "solarSurfaceTexture")
        
        thermalSphere.materials = [thermalMaterial]
        
        let thermalShellNode = SCNNode(geometry: thermalSphere)
        thermalShellNode.name = "thermal"
        thermalShellNode.renderingOrder = 40
        
        return thermalShellNode
    }
    
}
