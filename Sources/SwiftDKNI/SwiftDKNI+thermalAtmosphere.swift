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
        surfaceTexture: MTLTexture,
        voxelCube: MTLTexture,
        config: StarThermalConfig = StarThermalConfig()
    ) -> SCNNode {
        
        print("--- THERMAL NODE DEBUG ---")
        print("Radius: \(radius), Thermal Multiplier: \(thermalRadius)")
        print("Surface Texture Size: \(surfaceTexture.width)x\(surfaceTexture.height)")
        print("Voxel Cube Size: \(voxelCube.width)x\(voxelCube.height)x\(voxelCube.depth)")
        
        let thermalShellRadius = radius * thermalRadius
        let thermalSphere = SCNSphere(radius: CGFloat(thermalShellRadius))
        thermalSphere.segmentCount = 256
        
        let thermalMaterial = SCNMaterial()
        thermalMaterial.lightingModel = .constant
        thermalMaterial.blendMode = .add
        thermalMaterial.writesToDepthBuffer = false
        thermalMaterial.readsFromDepthBuffer = true
        thermalMaterial.isDoubleSided = true
        
        // FIX 2: Force SceneKit to generate and pass UV coordinates to the shader
        // by assigning a valid texture to the diffuse channel instead of a flat color.
        thermalMaterial.diffuse.contents = surfaceTexture
        
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
            print("Shaders loaded successfully.")
        } catch {
            print("CRITICAL: Failed to load Thermal shader files: \(error)")
            thermalMaterial.shaderModifiers = [:]
        }
        
        // Bind scalars
        let warpIntensity = config.warpIntensity
        let directionMultiplier = config.directionMultiplier
        let shaderThermalRadius = thermalShellRadius
        
        print("Binding Uniforms - Warp: \(warpIntensity), DirMult: \(directionMultiplier)")
        
        // FIX 1: Use NSNumber to guarantee SceneKit bridges the floats to Metal
        thermalMaterial.setValue(NSNumber(value: warpIntensity), forKey: "u_warpIntensity")
        thermalMaterial.setValue(NSNumber(value: directionMultiplier), forKey: "u_directionMultiplier")
        thermalMaterial.setValue(NSNumber(value: shaderThermalRadius), forKey: "u_thermalRadius")
        
        let voxelProperty = SCNMaterialProperty(contents: voxelCube)
        thermalMaterial.setValue(voxelProperty, forKey: "voxelCube")
        
        let surfaceProperty = SCNMaterialProperty(contents: surfaceTexture)
        thermalMaterial.setValue(surfaceProperty, forKey: "solarSurfaceTexture")
        
        thermalSphere.materials = [thermalMaterial]
        
        let thermalShellNode = SCNNode(geometry: thermalSphere)
        thermalShellNode.name = "thermal"
        thermalShellNode.renderingOrder = 40
        
        print("--------------------------")
        
        return thermalShellNode
    }
    
}
