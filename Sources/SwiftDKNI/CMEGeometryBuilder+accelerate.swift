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
    
    internal func generateLinearArray(count: Int, min: Float, max: Float) -> [Float] {
        // Guard against a count of 0 or 1 to prevent division-by-zero math inside vDSP
        guard count > 1 else { return [min] }
        var result = [Float](repeating: 0.0, count: count)
        
        var startVal = min
        var endVal = max
        
        // vDSP_vgen generates a linearly spaced sequence between startVal and endVal
        vDSP_vgen(&startVal, &endVal, &result, 1, vDSP_Length(count))
        
        return result
    }
    
    public func buildAcceleratedEnergyTunnels(from lines: [MagneticLoopLine], particlesPerUnitLength: Float = 50.0, solarRadius: Float) -> SCNNode {
                    
            let validLines = lines
            
            // 1. PRE-CALCULATE DYNAMIC PARTICLE COUNTS
            var lineParticleCounts: [Int] = []
            var totalParticles = 0
                    
            for line in validLines {
                let approxLength = simd_distance(line.p0, line.p1) +
                                   simd_distance(line.p1, line.p2) +
                                   simd_distance(line.p2, line.p3) +
                                   simd_distance(line.p3, line.p4)
                
                let count = max(10, Int(approxLength * particlesPerUnitLength))
                lineParticleCounts.append(count)
                totalParticles += count
            }
                    
            guard totalParticles > 0 else { return SCNNode() }
                    
            // 2. Generate ALL randoms upfront using Accelerate
            let offsets = generateAcceleratedRandoms(count: totalParticles, min: 0.0, max: 1.0)
            let speeds  = generateAcceleratedRandoms(count: totalParticles, min: 0.05, max: 0.25)
            let phases  = generateAcceleratedRandoms(count: totalParticles, min: 0.0, max: 1.0)
                    
            let totalVertices = totalParticles * 4
            
            // --- GEOMETRY PACKING ARCHITECTURE ---
            var vertexDataArray = [Float](repeating: 0.0, count: totalVertices * 3) // p2 (Apex)
            var normalDataArray = [Float](repeating: 0.0, count: totalVertices * 3) // p1 (Ascending Twist)
            
            var uv0DataArray    = [Float](repeating: 0.0, count: totalVertices * 2) // Quad UVs
            
            // Packing 9 floats (p3, p0, p4) into five float2 UV channels
            var uv1DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
            var uv2DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
            var uv3DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
            var uv4DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
            var uv5DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
            
            var colorDataArray  = [Float](repeating: 0.0, count: totalVertices * 4) // Particle Params
                    
            var indices = [UInt32](repeating: 0, count: totalParticles * 6)
                    
            var pIdx = 0
            let quadUVs: [simd_float2] = [
                simd_float2(0, 0), simd_float2(1, 0),
                simd_float2(0, 1), simd_float2(1, 1)
            ]
                    
            for (lineIdx, line) in validLines.enumerated() {
                
                // Premultiply the solar radius on the CPU
                let p0 = line.p0 * solarRadius
                let p1 = line.p1 * solarRadius
                let p2 = line.p2 * solarRadius
                let p3 = line.p3 * solarRadius
                let p4 = line.p4 * solarRadius
                
                let loopIntensity = min(1.0, abs(line.intensity) / 1000.0)
                let particlesForThisLine = lineParticleCounts[lineIdx]
                    
                for _ in 0..<particlesForThisLine {
                    let speed = speeds[pIdx]
                    let offset = offsets[pIdx]
                    let phase = phases[pIdx]
                        
                    for j in 0..<4 {
                        let vIdx = (pIdx * 4) + j
                        let vOffset3 = vIdx * 3
                        
                        vertexDataArray[vOffset3]     = p2.x
                        vertexDataArray[vOffset3 + 1] = p2.y
                        vertexDataArray[vOffset3 + 2] = p2.z
                            
                        normalDataArray[vOffset3]     = p1.x
                        normalDataArray[vOffset3 + 1] = p1.y
                        normalDataArray[vOffset3 + 2] = p1.z
                        
                        let vOffset2 = vIdx * 2
                        uv0DataArray[vOffset2]     = quadUVs[j].x
                        uv0DataArray[vOffset2 + 1] = quadUVs[j].y
                        
                        // Cross-packing p3, p0, p4 into 2-component arrays
                        uv1DataArray[vOffset2]     = p3.x
                        uv1DataArray[vOffset2 + 1] = p3.y
                        
                        uv2DataArray[vOffset2]     = p3.z
                        uv2DataArray[vOffset2 + 1] = p0.x
                        
                        uv3DataArray[vOffset2]     = p0.y
                        uv3DataArray[vOffset2 + 1] = p0.z
                        
                        uv4DataArray[vOffset2]     = p4.x
                        uv4DataArray[vOffset2 + 1] = p4.y
                        
                        uv5DataArray[vOffset2]     = p4.z
                        uv5DataArray[vOffset2 + 1] = 0.0 // Padding
                            
                        let cOffset = vIdx * 4
                        colorDataArray[cOffset]     = speed
                        colorDataArray[cOffset + 1] = offset
                        colorDataArray[cOffset + 2] = phase
                        colorDataArray[cOffset + 3] = loopIntensity
                    }
                        
                    let iIdx = pIdx * 6
                    let baseV = UInt32(pIdx * 4)
                    indices[iIdx]     = baseV
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
            
            let uv3Data = Data(bytes: uv3DataArray, count: uv3DataArray.count * MemoryLayout<Float>.size)
            let uv3Source = SCNGeometrySource(data: uv3Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
            
            let uv4Data = Data(bytes: uv4DataArray, count: uv4DataArray.count * MemoryLayout<Float>.size)
            let uv4Source = SCNGeometrySource(data: uv4Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
            
            let uv5Data = Data(bytes: uv5DataArray, count: uv5DataArray.count * MemoryLayout<Float>.size)
            let uv5Source = SCNGeometrySource(data: uv5Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
                    
            let colorData = Data(bytes: colorDataArray, count: colorDataArray.count * MemoryLayout<Float>.size)
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)

            let element = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size), primitiveType: .triangles, primitiveCount: totalParticles * 2, bytesPerIndex: MemoryLayout<UInt32>.size)

            // The order here natively maps to _geometry.texcoords[0] through [5] in the shader
            let geometry = SCNGeometry(sources: [vertexSource, normalSource, uv0Source, uv1Source, uv2Source, uv3Source, uv4Source, uv5Source, colorSource], elements: [element])
                    
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.blendMode = .add
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = true
            material.isDoubleSided = true
                    
            let dummyTex = createDummyTexture()
            material.diffuse.contents = dummyTex
            material.ambient.contents = dummyTex
            material.specular.contents = dummyTex
            material.transparent.contents = dummyTex
            material.emission.contents = dummyTex

            let fileManager = FileManager.default
            let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let starsDirectoryURL = docsDir.appendingPathComponent("stars")
                    
            let geometryURL = starsDirectoryURL.appendingPathComponent("energytunnel_geometry.metal")
            let fragmentURL = starsDirectoryURL.appendingPathComponent("energytunnel_fragment.metal")
                    
            do {
                let geometryShader = try String(contentsOf: geometryURL, encoding: .utf8)
                let fragmentShader = try String(contentsOf: fragmentURL, encoding: .utf8)
                    
                material.shaderModifiers = [
                    .geometry: geometryShader,
                    .surface: fragmentShader
                ]
                    
                material.setValue(NSNumber(value: solarRadius), forKey: "u_solarRadius")
                    
                var defaultTunnelRadius: Float = 0.005
                material.setValue(Data(bytes: &defaultTunnelRadius, count: MemoryLayout<Float>.size), forKey: "u_tunnelRadiusBase")
                var defaultBaseSize: Float = 0.08
                material.setValue(Data(bytes: &defaultBaseSize, count: MemoryLayout<Float>.size), forKey: "u_particleBaseSize")
                var defaultVariance: Float = 0.02
                material.setValue(Data(bytes: &defaultVariance, count: MemoryLayout<Float>.size), forKey: "u_particleVariance")
                    
                var defaultWarp: Float = 0.05
                material.setValue(Data(bytes: &defaultWarp, count: MemoryLayout<Float>.size), forKey: "u_warpIntensity")
                var defaultBoil: Float = 2.0
                material.setValue(Data(bytes: &defaultBoil, count: MemoryLayout<Float>.size), forKey: "u_boilSpeed")
                var defaultTwinkle: Float = 15.0
                material.setValue(Data(bytes: &defaultTwinkle, count: MemoryLayout<Float>.size), forKey: "u_twinkleSpeed")
                    
                let coreColor = SCNVector3(1.0, 0.95, 0.8)
                material.setValue(NSValue(scnVector3: coreColor), forKey: "u_coreColor")
                let midColor = SCNVector3(1.0, 0.4, 0.0)
                material.setValue(NSValue(scnVector3: midColor), forKey: "u_midColor")
                let edgeColor = SCNVector3(0.4, 0.02, 0.0)
                material.setValue(NSValue(scnVector3: edgeColor), forKey: "u_edgeColor")

                var hdrMultiplier: Float = 0.8
                material.setValue(Data(bytes: &hdrMultiplier, count: MemoryLayout<Float>.size), forKey: "u_hdrMultiplier")
            } catch {
                print("CRITICAL: Failed to load shader files: \(error)")
                material.shaderModifiers = [:]
            }
                    
            geometry.materials = [material]
                    
            let bound = CGFloat(solarRadius * 10.0)
            let minVec = SCNVector3(-bound, -bound, -bound)
            let maxVec = SCNVector3(bound, bound, bound)
            geometry.boundingBox = (min: minVec, max: maxVec)
                    
            let node = SCNNode(geometry: geometry)
            node.categoryBitMask = 2
            node.renderingOrder = 10
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
