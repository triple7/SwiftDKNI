//
//  CMEGeometryBuilder.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//

import Foundation
import SceneKit
import CoreGraphics
import Accelerate
import simd

extension MagneticLoopLine {
    func position(at t: Float) -> simd_float3 {
        let u = 1.0 - t
        let tt = t * t
        let uu = u * u
        
        let term1 = p0 * uu
        let term2 = p1 * (2.0 * u * t)
        let term3 = p2 * tt
        
        return term1 + term2 + term3
    }
    
    func tangent(at t: Float) -> simd_float3 {
        let u = 1.0 - t
        let dP1 = (p1 - p0) * (2.0 * u)
        let dP2 = (p2 - p1) * (2.0 * t)
        return simd_normalize(dP1 + dP2)
    }
}

public final class CMEGeometryBuilder: @unchecked Sendable {
    
    public init() {}
    
    private func sphericalToCartesian(lat: Float, lon: Float, radius: Float = 1.0) -> simd_float3 {
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        return simd_float3(
            cos(latRad) * sin(lonRad) * radius,
            sin(latRad) * radius,
            cos(latRad) * cos(lonRad) * radius
        )
    }
    
    public func buildDONKICorrelatedCMECloud(
            eventLatitude: Float,
            eventLongitude: Float,
            eventHalfAngle: Float,
            openLines: [MagneticLoopLine],
            pointCount: Int = 15000,
            solarRadius: Float = 1.0
        ) -> SCNGeometry {
            
            guard !openLines.isEmpty else { return SCNGeometry() }
            
            let donkiCenter = simd_normalize(sphericalToCartesian(lat: eventLatitude, lon: eventLongitude))
            let halfAngleRad = eventHalfAngle * .pi / 180.0
            
            var matchedLines: [MagneticLoopLine] = []
            for line in openLines {
                let rootPos = simd_normalize(line.p0)
                let dotProduct = simd_dot(donkiCenter, rootPos)
                let angle = acos(max(-1.0, min(1.0, dotProduct)))
                
                if angle <= halfAngleRad {
                    matchedLines.append(line)
                }
            }
            
            if matchedLines.isEmpty {
                let sortedLines = openLines.sorted { a, b in
                    let dotA = simd_dot(donkiCenter, simd_normalize(a.p0))
                    let dotB = simd_dot(donkiCenter, simd_normalize(b.p0))
                    return dotA > dotB
                }
                matchedLines = Array(sortedLines.prefix(3))
            }
            
            // 1. Generate randoms for 3D positioning
            let tValues = generateAcceleratedRandoms(count: pointCount, min: 0.0, max: 1.0)
            let noiseX = generateAcceleratedRandoms(count: pointCount, min: -1.0, max: 1.0)
            let noiseY = generateAcceleratedRandoms(count: pointCount, min: -1.0, max: 1.0)
            let noiseZ = generateAcceleratedRandoms(count: pointCount, min: -1.0, max: 1.0)
            let spreads = generateAcceleratedRandoms(count: pointCount, min: 0.0, max: 1.0)
            
            // 2. Allocate ONLY what the GPU needs (Vertices and Quad UVs)
            let totalVertices = pointCount * 4
            var vertexDataArray = [Float](repeating: 0.0, count: totalVertices * 3)
            var uv0DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
            var indices         = [UInt32](repeating: 0, count: pointCount * 6)
            
            let quadUVs: [simd_float2] = [
                simd_float2(-1, -1), simd_float2(1, -1),
                simd_float2(-1,  1), simd_float2(1,  1)
            ]
            
            for i in 0..<pointCount {
                let line = matchedLines.randomElement()!
                let t = tValues[i]
                
                let centerPos = line.position(at: t) * solarRadius
                
                let voidFactor = pow(t, 2.5)
                let entropySpread = (solarRadius * 0.03) + (voidFactor * solarRadius * 2.5)
                
                let noiseVec = simd_normalize(simd_float3(noiseX[i], noiseY[i], noiseZ[i]))
                let finalPos = centerPos + (noiseVec * (spreads[i] * entropySpread))
                
                // Build the Quad (No colors, no extra UVs)
                for j in 0..<4 {
                    let vIdx = (i * 4) + j
                    
                    let v3 = vIdx * 3
                    vertexDataArray[v3] = finalPos.x
                    vertexDataArray[v3 + 1] = finalPos.y
                    vertexDataArray[v3 + 2] = finalPos.z
                    
                    let v2 = vIdx * 2
                    uv0DataArray[v2] = quadUVs[j].x
                    uv0DataArray[v2 + 1] = quadUVs[j].y
                }
                
                let iIdx = i * 6
                let baseV = UInt32(i * 4)
                indices[iIdx] = baseV
                indices[iIdx + 1] = baseV + 1
                indices[iIdx + 2] = baseV + 2
                indices[iIdx + 3] = baseV + 1
                indices[iIdx + 4] = baseV + 3
                indices[iIdx + 5] = baseV + 2
            }
            
            // 3. Construct the lightweight geometry
            let vertexData = Data(bytes: vertexDataArray, count: vertexDataArray.count * MemoryLayout<Float>.size)
            let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)
            
            let uv0Data = Data(bytes: uv0DataArray, count: uv0DataArray.count * MemoryLayout<Float>.size)
            let uvSource = SCNGeometrySource(data: uv0Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
            
            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
            let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: pointCount * 2, bytesPerIndex: MemoryLayout<UInt32>.size)
            
            return SCNGeometry(sources: [source, uvSource], elements: [element])
        }

    public func buildDataDrivenMagneticLoops(from lines: [MagneticLoopLine], pointsPerLoop: Int = 50, solarRadius: Float) -> SCNGeometry {
        var vertices: [simd_float3] = []
        var indices: [Int32] = []
        var texcoords: [simd_float2] = []
        var colors: [simd_float4] = []
        
        var currentIndex: Int32 = 0
        
        for line in lines {
            guard !line.isOpen else { continue }
            
            let phase = Float.random(in: 0.0...1.0)
            
            for i in 0...pointsPerLoop {
                let t = Float(i) / Float(pointsPerLoop)
                
                vertices.append(line.position(at: t) * solarRadius)
                texcoords.append(simd_float2(t, phase))
                
                let coreColor = simd_float4(1.0, 0.7, 0.4, 0.15)
                let edgeColor = simd_float4(0.8, 0.2, 0.0, 0.05)
                
                let apexness = 1.0 - (abs(t - 0.5) * 2.0)
                colors.append(mixColor(edgeColor, coreColor, factor: apexness))
                
                if i > 0 {
                    indices.append(currentIndex - 1)
                    indices.append(currentIndex)
                }
                currentIndex += 1
            }
        }
        
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<simd_float3>.size)
        let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: vertices.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size)
        
        let uvData = Data(bytes: texcoords, count: texcoords.count * MemoryLayout<simd_float2>.size)
        let uvSource = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: texcoords.count, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<simd_float2>.size)
        
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<simd_float4>.size)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<simd_float4>.size)
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: indexData, primitiveType: .line, primitiveCount: indices.count / 2, bytesPerIndex: MemoryLayout<Int32>.size)
        
        return SCNGeometry(sources: [source, uvSource, colorSource], elements: [element])
    }
    
    private func buildEnergyTunnels(from lines: [MagneticLoopLine], particlesPerLine: Int = 20, solarRadius: Float) -> SCNNode {
            let validLines = lines.filter { !$0.isOpen }
            let totalParticles = validLines.count * particlesPerLine
            guard totalParticles > 0 else { return SCNNode() }
            
            // 1. Generate ALL randoms upfront using Accelerate
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
                    // 2. Read directly from Accelerate arrays (No Float.random here)
                    let offset = offsets[pIdx]
                    let speed = speeds[pIdx]
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
            material.diffuse.mappingChannel = 0
            material.ambient.mappingChannel = 1
            material.specular.mappingChannel = 2
            
            material.setValue(NSNumber(value: solarRadius), forKey: "u_solarRadius")
            
            // Load the external energy tunnel shaders
            let fileManager = FileManager.default
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let geometryShaderURL = documentsURL.appendingPathComponent("stars/energytunnel_geometry.metal")
            let fragmentShaderURL = documentsURL.appendingPathComponent("stars/energytunnel_fragment.metal")
            
            guard let geometrySource = try? String(contentsOf: geometryShaderURL, encoding: .utf8),
                  let fragmentSource = try? String(contentsOf: fragmentShaderURL, encoding: .utf8) else {
                print("FATAL ERROR: Could not load energy tunnel shaders from Documents directory.")
                return SCNNode()
            }
            
            material.shaderModifiers = [
                .geometry: geometrySource,
                .surface: fragmentSource
            ]
            
            geometry.materials = [material]
            let bound = CGFloat(solarRadius * 10.0)
            let minVec = SCNVector3(-bound, -bound, -bound)
            let maxVec = SCNVector3(bound, bound, bound)
            geometry.boundingBox = (min: minVec, max: maxVec)
            
            let node = SCNNode(geometry: geometry)
            node.categoryBitMask = 2
            return node
        }

    public func createCoronalSurface(from lines: [MagneticLoopLine], solarRadius: Float) -> SCNNode {
        let masterNode = SCNNode()
        
        let baseLoopStart = CACurrentMediaTime()
        let baseLoopsNode = SCNNode(geometry: buildDataDrivenMagneticLoops(from: lines, solarRadius: solarRadius))
        let baseLoopEnd = CACurrentMediaTime()
        print("createCoronalSurface: Base loops created in \(baseLoopEnd - baseLoopStart) seconds.")
        let baseMaterial = SCNMaterial()
        baseMaterial.isDoubleSided = true
        baseMaterial.blendMode = .add
        baseMaterial.writesToDepthBuffer = false
        baseMaterial.readsFromDepthBuffer = true
        baseLoopsNode.geometry?.materials = [baseMaterial]
        baseLoopsNode.categoryBitMask = 2
        
        let tunnelStart = CACurrentMediaTime()
        let energyTunnelsNode = buildEnergyTunnels(from: lines, particlesPerLine: 20, solarRadius: solarRadius)
        let tunnelEnd = CACurrentMediaTime()
        print("createCoronalSurface: Created energy tunnels in \(tunnelEnd - tunnelStart) seconds.")
        
        masterNode.addChildNode(baseLoopsNode)
        masterNode.addChildNode(energyTunnelsNode)
        
        return masterNode
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

fileprivate func mixColor(_ a: simd_float4, _ b: simd_float4, factor: Float) -> simd_float4 {
    let f = max(0.0, min(1.0, factor))
    return a + (b - a) * f
}
