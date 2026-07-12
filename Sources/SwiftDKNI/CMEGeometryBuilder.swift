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
            eventSpeed: Float,
            openLines: [MagneticLoopLine],
            pointCount: Int = 15000,
            solarRadius: Float = 1.0
        ) -> SCNGeometry {
            
            guard !openLines.isEmpty else {
                print("No open magnetic lines")
                return SCNGeometry()
            }
            
            let donkiCenter = simd_normalize(sphericalToCartesian(lat: eventLatitude, lon: eventLongitude))
            
            let noiseX = generateAcceleratedRandoms(count: pointCount, min: -1.0, max: 1.0)
            let noiseY = generateAcceleratedRandoms(count: pointCount, min: -1.0, max: 1.0)
            let noiseZ = generateAcceleratedRandoms(count: pointCount, min: -1.0, max: 1.0)
            let spreads = generateAcceleratedRandoms(count: pointCount, min: 0.0, max: 1.0)
            
            let totalVertices = pointCount * 4
            var vertexDataArray = [Float](repeating: 0.0, count: totalVertices * 3)
            var normalDataArray = [Float](repeating: 0.0, count: totalVertices * 3)
            var uv0DataArray    = [Float](repeating: 0.0, count: totalVertices * 2)
            
            // 🚨 NEW: The missing color semantic array that forces SceneKit into the transparent pipeline
            var colorDataArray  = [Float](repeating: 1.0, count: totalVertices * 4)
            
            var indices         = [UInt32](repeating: 0, count: pointCount * 6)
            
            let quadUVs: [simd_float2] = [
                simd_float2(0, 0), simd_float2(1, 0),
                simd_float2(0, 1), simd_float2(1, 1)
            ]
            
            let rootOrigin = donkiCenter * solarRadius
            let baseSpread = solarRadius * 0.08
            
            for i in 0..<pointCount {
                let nX = noiseX[i]
                let nY = noiseY[i]
                let nZ = noiseZ[i]
                
                let rawNoise = simd_float3(nX, nY, nZ)
                let noiseVec = length(rawNoise) > 0.001 ? simd_normalize(rawNoise) : simd_float3(0, 1, 0)
                
                let finalPos = rootOrigin + (noiseVec * spreads[i] * baseSpread)

                let tiny: Float = 0.001
                let safeOffsets: [simd_float3] = [
                    simd_float3(-tiny, -tiny, 0),
                    simd_float3(tiny, -tiny, 0),
                    simd_float3(-tiny,  tiny, 0),
                    simd_float3(tiny,  tiny, 0)
                ]

                for j in 0..<4 {
                    let vIdx = (i * 4) + j
                    let v3 = vIdx * 3
                    
                    vertexDataArray[v3] = finalPos.x + safeOffsets[j].x
                    vertexDataArray[v3 + 1] = finalPos.y + safeOffsets[j].y
                    vertexDataArray[v3 + 2] = finalPos.z + safeOffsets[j].z
                    
                    normalDataArray[v3] = 0.0
                    normalDataArray[v3 + 1] = 0.0
                    normalDataArray[v3 + 2] = 1.0
                    
                    let v2 = vIdx * 2
                    uv0DataArray[v2] = quadUVs[j].x
                    uv0DataArray[v2 + 1] = quadUVs[j].y
                    
                    // colorDataArray is already initialized to 1.0 (white, fully opaque alpha),
                    // so no loop assignment is needed here.
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
            
            let vertexData = Data(bytes: vertexDataArray, count: vertexDataArray.count * MemoryLayout<Float>.size)
            let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)
            
            let normalData = Data(bytes: normalDataArray, count: normalDataArray.count * MemoryLayout<Float>.size)
            let normalSource = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)
            
            let uv0Data = Data(bytes: uv0DataArray, count: uv0DataArray.count * MemoryLayout<Float>.size)
            let uvSource = SCNGeometrySource(data: uv0Data, semantic: .texcoord, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
            
            // 🚨 NEW: Create the color source
            let colorData = Data(bytes: colorDataArray, count: colorDataArray.count * MemoryLayout<Float>.size)
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)
            
            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
            let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: pointCount * 2, bytesPerIndex: MemoryLayout<UInt32>.size)
            
            // 🚨 Pass the colorSource to the final geometry
            return SCNGeometry(sources: [source, normalSource, uvSource, colorSource], elements: [element])
        }

    public func buildDataDrivenMagneticLoops(from lines: [MagneticLoopLine], pointsPerUnitLength: Float = 35.0, solarRadius: Float) -> SCNGeometry {
        var vertices: [simd_float3] = []
        var indices: [Int32] = []
        var texcoords: [simd_float2] = []
        var colors: [simd_float4] = []
        
        var currentIndex: Int32 = 0
        
        for line in lines {
            guard !line.isOpen else { continue }
            
            let phase = Float.random(in: 0.0...1.0)
            
            // 1. Calculate the approximate physical length of this specific bezier curve
            let approxLength = simd_distance(line.p0, line.p1) + simd_distance(line.p1, line.p2)
            
            // 2. Scale the number of points by the physical length (minimum 10 points)
            let dynamicPoints = max(10, Int(approxLength * pointsPerUnitLength))
            
            for i in 0...dynamicPoints {
                let t = Float(i) / Float(dynamicPoints)
                
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
    
    public func createCoronalEjectionNode(
            for event: AveragedCMEData,
            openLines: [MagneticLoopLine],
            pointCount: Int,
            solarRadius: Float = 1.0
        ) throws -> SCNNode {
            
            let geometry = self.buildDONKICorrelatedCMECloud(
                eventLatitude: Float(event.latitude ?? 0.0),
                eventLongitude: Float(event.longitude ?? 0.0),
                eventHalfAngle: Float(event.halfAngle ?? 45.0),
                eventSpeed: Float(event.speed),
                openLines: openLines,
                pointCount: pointCount,
                solarRadius: solarRadius
            )
            
            let bound = CGFloat(solarRadius * 10.0)
            geometry.boundingBox = (min: SCNVector3(-bound, -bound, -bound), max: SCNVector3(bound, bound, bound))
            
            let material = SCNMaterial()
            
            // 🚨 Exactly mirroring the working Tunnels material structure
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
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let geometryShaderURL = documentsURL.appendingPathComponent("stars/coronal_geometry.metal")
            let fragmentShaderURL = documentsURL.appendingPathComponent("stars/coronal_fragment.metal")
            
            do {
                let geometrySource = try String(contentsOf: geometryShaderURL, encoding: .utf8)
                let fragmentSource = try String(contentsOf: fragmentShaderURL, encoding: .utf8)
                
                material.shaderModifiers = [
                    .geometry: geometrySource,
                    .surface: fragmentSource
                ]
            } catch {
                print("CRITICAL: Failed to load CME shader files: \(error)")
                material.shaderModifiers = [:]
            }
            
            geometry.materials = [material]
            
            let node = SCNNode(geometry: geometry)
            node.categoryBitMask = 2
            node.renderingOrder = 10
            
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
        let energyTunnelsNode = buildAcceleratedEnergyTunnels(from: lines, solarRadius: solarRadius)
        energyTunnelsNode.categoryBitMask = 4
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
    
    private func createTransparentDummyTexture() -> XImage {
        let size = CGSize(width: 4, height: 4)
#if os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.0, alpha: 0.5).setFill()
        let bounds = NSRect(origin: .zero, size: size)
        bounds.fill()
        image.unlockFocus()
        return image
#else
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        UIColor(white: 0.0, alpha: 0.5).setFill()
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
