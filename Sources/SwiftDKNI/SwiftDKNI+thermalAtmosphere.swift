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
        voxelCube: MTLTexture, // Now accepts the raw MTLTexture directly
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
        
        let r = CGFloat(config.color.x)
        let g = CGFloat(config.color.y)
        let b = CGFloat(config.color.z)
        let a = CGFloat(config.opacity)
        
#if os(macOS)
        thermalMaterial.diffuse.contents = NSColor(red: r, green: g, blue: b, alpha: a)
#else
        thermalMaterial.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: a)
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
        
        // Bind scalars securely to the shader
        var warpIntensity = config.warpIntensity
        var directionMultiplier = config.directionMultiplier
        var shaderThermalRadius = thermalShellRadius // Needed to normalize the 3D texture map
        
        thermalMaterial.setValue(Data(bytes: &warpIntensity, count: MemoryLayout<Float>.size), forKey: "u_warpIntensity")
        thermalMaterial.setValue(Data(bytes: &directionMultiplier, count: MemoryLayout<Float>.size), forKey: "u_directionMultiplier")
        thermalMaterial.setValue(Data(bytes: &shaderThermalRadius, count: MemoryLayout<Float>.size), forKey: "u_thermalRadius")
        
        // Wrap the MTLTexture in an SCNMaterialProperty and bind it
        let voxelProperty = SCNMaterialProperty(contents: voxelCube)
        thermalMaterial.setValue(voxelProperty, forKey: "voxelCube")
        
        thermalSphere.materials = [thermalMaterial]
        
        let thermalShellNode = SCNNode(geometry: thermalSphere)
        thermalShellNode.name = "thermal"
        
        thermalShellNode.renderingOrder = 40
        
        return thermalShellNode
    }
    
}
