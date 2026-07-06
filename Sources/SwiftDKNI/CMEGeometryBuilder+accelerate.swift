//
//  Untitled.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 4/7/2026.
//


import Foundation
import SceneKit
import Accelerate
import simd

extension CMEGeometryBuilder {
    
    internal func generateAcceleratedRandoms(count: Int, min: Float, max: Float) -> [Float] {
        var randomInts = [UInt32](repeating: 0, count: count)
        arc4random_buf(&randomInts, count * MemoryLayout<UInt32>.size)
        
        var randomFloats = [Float](repeating: 0.0, count: count)
        vDSP_vfltu32(randomInts, 1, &randomFloats, 1, vDSP_Length(count))
        
        var divisor = Float(UInt32.max)
        vDSP_vsdiv(randomFloats, 1, &divisor, &randomFloats, 1, vDSP_Length(count))
        
        var range = max - min
        var offset = min
        vDSP_vsmsa(randomFloats, 1, &range, &offset, &randomFloats, 1, vDSP_Length(count))
        
        return randomFloats
    }
    
    public func buildAcceleratedEnergyTunnels(from lines: [MagneticLoopLine], particlesPerLine: Int = 20, solarRadius: Float) -> SCNNode {
        
        let validLines = lines.filter { !$0.isOpen }
        let totalParticles = validLines.count * particlesPerLine
        guard totalParticles > 0 else { return SCNNode() }
        
        let offsets = generateAcceleratedRandoms(count: totalParticles, min: 0.0, max: 1.0)
        let speeds  = generateAcceleratedRandoms(count: totalParticles, min: 0.05, max: 0.25)
        let phases  = generateAcceleratedRandoms(count: totalParticles, min: 0.0, max: 1.0)
        
        let totalVertices = totalParticles * 4
        var vertexDataArray = [Float](repeating: 0.0, count: totalVertices * 3)
        var normalDataArray = [Float](repeating: 0.0, count: totalVertices * 3)
        
        var uv0DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
        var uv1DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
        var uv2DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
        var colorDataArray  = [Float](repeating: 0.0, count: totalVertices * 4)
        
        var indices = [UInt32](repeating: 0, count: totalParticles * 6)
        
        let pi = Float.pi
        let twoPi = Float.pi * 2.0
        var pIdx = 0
        
        let quadUVs: [simd_float2] = [
            simd_float2(0, 0), simd_float2(1, 0),
            simd_float2(0, 1), simd_float2(1, 1)
        ]
        
        for line in validLines {
            let p1 = line.p1 * solarRadius
            let p0Norm = simd_normalize(line.p0)
            let p2Norm = simd_normalize(line.p2)
            
            let lat2 = asin(max(-1.0, min(1.0, p2Norm.y)))
            let lon2 = atan2(p2Norm.x, p2Norm.z)
            
            let lat2Norm = (lat2 + (pi / 2.0)) / pi
            let lon2Norm = (lon2 + pi) / twoPi
            let loopIntensity = min(1.0, abs(line.intensity) / 1000.0)
            
            for _ in 0..<particlesPerLine {
                let speed = speeds[pIdx]
                let offset = offsets[pIdx]
                let phase = phases[pIdx]
                
                for j in 0..<4 {
                    let vIdx = (pIdx * 4) + j
                    
                    let vOffset3 = vIdx * 3
                    vertexDataArray[vOffset3] = p1.x
                    vertexDataArray[vOffset3 + 1] = p1.y
                    vertexDataArray[vOffset3 + 2] = p1.z
                    
                    normalDataArray[vOffset3] = p0Norm.x
                    normalDataArray[vOffset3 + 1] = p0Norm.y
                    normalDataArray[vOffset3 + 2] = p0Norm.z
                    
                    let vOffset2 = vIdx * 2
                    uv0DataArray[vOffset2] = quadUVs[j].x
                    uv0DataArray[vOffset2 + 1] = quadUVs[j].y
                    
                    uv1DataArray[vOffset2] = speed
                    uv1DataArray[vOffset2 + 1] = offset
                    
                    uv2DataArray[vOffset2] = lat2Norm
                    uv2DataArray[vOffset2 + 1] = lon2Norm
                    
                    let cOffset = vIdx * 4
                    colorDataArray[cOffset] = phase
                    colorDataArray[cOffset + 1] = loopIntensity
                    colorDataArray[cOffset + 2] = 1.0
                    colorDataArray[cOffset + 3] = 1.0
                }
                
                let iIdx = pIdx * 6
                let baseV = UInt32(pIdx * 4)
                indices[iIdx] = baseV
                indices[iIdx + 1] = baseV + 1
                indices[iIdx + 2] = baseV + 2
                
                indices[iIdx + 3] = baseV + 1
                indices[iIdx + 4] = baseV + 3
                indices[iIdx + 5] = baseV + 2
                
                pIdx += 1
            }
        }
        
        let vertexData = Data(bytes: vertexDataArray, count: vertexDataArray.count * MemoryLayout<Float>.size)
        let vertexSource = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)
        
        let normalData = Data(bytes: normalDataArray, count: normalDataArray.count * MemoryLayout<Float>.size)
        let normalSource = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)
        
        let uv0Data = Data(bytes: uv0DataArray, count: uv0DataArray.count * MemoryLayout<Float>.size)
        let uv0Source = SCNGeometrySource(data: uv0Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
        
        let uv1Data = Data(bytes: uv1DataArray, count: uv1DataArray.count * MemoryLayout<Float>.size)
        let uv1Source = SCNGeometrySource(data: uv1Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
        
        let uv2Data = Data(bytes: uv2DataArray, count: uv2DataArray.count * MemoryLayout<Float>.size)
        let uv2Source = SCNGeometrySource(data: uv2Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
        
        let colorData = Data(bytes: colorDataArray, count: colorDataArray.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)
        
        let element = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size), primitiveType: .triangles, primitiveCount: totalParticles * 2, bytesPerIndex: MemoryLayout<UInt32>.size)
        
        let geometry = SCNGeometry(sources: [vertexSource, normalSource, uv0Source, uv1Source, uv2Source, colorSource], elements: [element])
        
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        
        let dummyTex = createDummyTexture()
        material.diffuse.contents = dummyTex
        material.ambient.contents = dummyTex
        material.specular.contents = dummyTex
        
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let starsDirectoryURL = docsDir.appendingPathComponent("stars")
        
        let geometryURL = starsDirectoryURL.appendingPathComponent("energytunnel_geometry.metal")
        let fragmentURL = starsDirectoryURL.appendingPathComponent("energytunnel_fragment.metal")
        
        do {
            let geometryShader = try String(contentsOf: geometryURL, encoding: .utf8)
            let fragmentShader = try String(contentsOf: fragmentURL, encoding: .utf8)
            
            // 1. ATTACH THE SHADERS FIRST
            // This exposes the #pragma arguments to SceneKit's KVC pipeline
            material.shaderModifiers = [
                .geometry: geometryShader,
                .fragment: fragmentShader
            ]
            print("Successfully loaded energytunnel shaders from disk.")
            
            // 2. INJECT THE UNIFORMS SECOND
            material.setValue(NSNumber(value: solarRadius), forKey: "u_solarRadius")
            
            // --- Geometry Shader Uniforms ---
            var defaultTunnelRadius: Float = 0.025
            material.setValue(Data(bytes: &defaultTunnelRadius, count: MemoryLayout<Float>.size), forKey: "u_tunnelRadiusBase")
            
            var defaultBaseSize: Float = 0.08
            material.setValue(Data(bytes: &defaultBaseSize, count: MemoryLayout<Float>.size), forKey: "u_particleBaseSize")
            
            var defaultVariance: Float = 0.02
            material.setValue(Data(bytes: &defaultVariance, count: MemoryLayout<Float>.size), forKey: "u_particleVariance")
            
            // --- Fragment Shader Uniforms ---
            var defaultWarp: Float = 0.08
            material.setValue(Data(bytes: &defaultWarp, count: MemoryLayout<Float>.size), forKey: "u_warpIntensity")
            
            var defaultBoil: Float = 2.0
            material.setValue(Data(bytes: &defaultBoil, count: MemoryLayout<Float>.size), forKey: "u_boilSpeed")
            
            var defaultTwinkle: Float = 15.0
            material.setValue(Data(bytes: &defaultTwinkle, count: MemoryLayout<Float>.size), forKey: "u_twinkleSpeed")
            
            // --- Thermal Color Defaults ---
            let coreColor = SCNVector3(1.0, 0.95, 0.8)
            material.setValue(NSValue(scnVector3: coreColor), forKey: "u_coreColor")
            
            let midColor = SCNVector3(1.0, 0.4, 0.0)
            material.setValue(NSValue(scnVector3: midColor), forKey: "u_midColor")
            
            let edgeColor = SCNVector3(0.4, 0.02, 0.0)
            material.setValue(NSValue(scnVector3: edgeColor), forKey: "u_edgeColor")
            
        } catch {
            print("CRITICAL: Failed to load shader files from Documents/stars/: \(error)")
            material.shaderModifiers = [:]
        }
        
        // 3. ATTACH THE MATERIAL TO THE GEOMETRY
        geometry.materials = [material]
        
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 2
        return node
}
    
    private func createDummyTexture() -> XImage {
        let size = CGSize(width: 4, height: 4)
#if os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        let bounds = NSRect(origin: .zero, size: size)
        bounds.fill()
        image.unlockFocus()
        return image
#else
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        UIColor.black.setFill()
        let bounds = CGRect(origin: .zero, size: size)
        UIRectFill(bounds)
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
#endif
    }
}
