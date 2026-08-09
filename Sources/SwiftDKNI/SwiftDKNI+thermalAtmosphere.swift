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
        surfaceTexture: MTLTexture, // Pulled straight from the underlying sphere material
        voxelCube: MTLTexture,      // The magnetic voxel grid
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

        // We set a neutral base color; the surface texture and shader will dynamically tint the final output
        #if os(macOS)
        thermalMaterial.diffuse.contents = NSColor.white
        #else
        thermalMaterial.diffuse.contents = UIColor.white
        #endif

        // Load the Metal Modifiers for vertex warping and synchronized surface coloring
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

        // Bind scalars securely to the shaders
        var warpIntensity = config.warpIntensity
        var directionMultiplier = config.directionMultiplier
        var shaderThermalRadius = thermalShellRadius
        
        thermalMaterial.setValue(Data(bytes: &warpIntensity, count: MemoryLayout<Float>.size), forKey: "u_warpIntensity")
        thermalMaterial.setValue(Data(bytes: &directionMultiplier, count: MemoryLayout<Float>.size), forKey: "u_directionMultiplier")
        thermalMaterial.setValue(Data(bytes: &shaderThermalRadius, count: MemoryLayout<Float>.size), forKey: "u_thermalRadius")
        
        // Bind the 3D voxel grid and the 2D surface texture as material properties
        let voxelProperty = SCNMaterialProperty(contents: voxelCube)
        let surfaceProperty = SCNMaterialProperty(contents: surfaceTexture)
        
        thermalMaterial.setValue(voxelProperty, forKey: "voxelCube")
        thermalMaterial.setValue(surfaceProperty, forKey: "solarSurfaceTexture")
        
        thermalSphere.materials = [thermalMaterial]

        let thermalShellNode = SCNNode(geometry: thermalSphere)
        thermalShellNode.name = "thermal"
        
        thermalShellNode.renderingOrder = 40
        
        return thermalShellNode
    }
}

