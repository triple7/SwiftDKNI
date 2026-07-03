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
    
    private func createSoftGlowTexture() -> XImage {
        let size = CGSize(width: 64, height: 64)
#if os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
#else
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let context = UIGraphicsGetCurrentContext()!
#endif
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0])!
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width / 2, options: [])
#if os(macOS)
        image.unlockFocus()
        return image
#else
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
#endif
    }
    
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
        
        var vertices: [simd_float3] = []
        var texcoords: [simd_float2] = []
        var colors: [simd_float4] = []
        
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
        
        for _ in 0..<pointCount {
            let line = matchedLines.randomElement()!
            let t = Float.random(in: 0.0...1.0)
            let centerPos = line.position(at: t) * solarRadius
            
            let voidFactor = pow(t, 2.5)
            let entropySpread = (solarRadius * 0.03) + (voidFactor * solarRadius * 2.5)
            
            let noise = simd_float3(
                Float.random(in: -1.0...1.0),
                Float.random(in: -1.0...1.0),
                Float.random(in: -1.0...1.0)
            )
            
            vertices.append(centerPos + (simd_normalize(noise) * Float.random(in: 0...entropySpread)))
            texcoords.append(simd_float2(t, Float.random(in: 0.0...1.0)))
            
            let coreColor = simd_float4(1.0, 0.9, 0.8, 1.0)
            let midColor  = simd_float4(1.0, 0.4, 0.0, 0.7)
            let redColor  = simd_float4(0.5, 0.0, 0.1, 0.3)
            let tipColor  = simd_float4(0.0, 0.0, 0.0, 0.0)
            
            let color: simd_float4
            if t < 0.15 {
                color = mixColor(coreColor, midColor, factor: t / 0.15)
            } else if t < 0.5 {
                color = mixColor(midColor, redColor, factor: (t - 0.15) / 0.35)
            } else {
                color = mixColor(redColor, tipColor, factor: (t - 0.5) / 0.5)
            }
            colors.append(color)
        }
        
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<simd_float3>.size)
        let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: vertices.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size)
        
        let uvData = Data(bytes: texcoords, count: texcoords.count * MemoryLayout<simd_float2>.size)
        let uvSource = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: texcoords.count, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<simd_float2>.size)
        
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<simd_float4>.size)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<simd_float4>.size)
        
        let indices = Array(0..<Int32(pointCount))
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: indexData, primitiveType: .point, primitiveCount: pointCount, bytesPerIndex: MemoryLayout<Int32>.size)
        
        element.pointSize = 12.0
        
        return SCNGeometry(sources: [source, uvSource, colorSource], elements: [element])
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
        var vertexDataArray: [Float] = []
        var normalDataArray: [Float] = []
        var uvDataArray: [Float] = []
        var colorDataArray: [Float] = []
        var indices: [Int32] = []
        
        let validLines = lines.filter { !$0.isOpen }
        let totalParticles = validLines.count * particlesPerLine
        
        vertexDataArray.reserveCapacity(totalParticles * 3)
        normalDataArray.reserveCapacity(totalParticles * 3)
        uvDataArray.reserveCapacity(totalParticles * 2)
        colorDataArray.reserveCapacity(totalParticles * 4)
        indices.reserveCapacity(totalParticles)
        
        var currentIndex: Int32 = 0
        let pi = Float.pi
        let twoPi = Float.pi * 2.0
        
        for line in validLines {
            let p1 = line.p1 * solarRadius
            
            let p0Norm = simd_normalize(line.p0)
            let p2Norm = simd_normalize(line.p2)
            
            let lat2 = asin(max(-1.0, min(1.0, p2Norm.y)))
            let lon2 = atan2(p2Norm.x, p2Norm.z)
            
            // ANTI-GEYSER FIX: SceneKit clamps negative colors to 0. Map to 0...1.
            let lat2Norm = (lat2 + (pi / 2.0)) / pi
            let lon2Norm = (lon2 + pi) / twoPi
            
            let loopIntensity = min(1.0, abs(line.intensity) / 1000.0)
            
            for _ in 0..<particlesPerLine {
                let offset = Float.random(in: 0.0...1.0)
                let speed = Float.random(in: 0.05...0.25)
                let phase = Float.random(in: 0.0...1.0)
                
                vertexDataArray.append(p1.x)
                vertexDataArray.append(p1.y)
                vertexDataArray.append(p1.z)
                
                normalDataArray.append(p0Norm.x)
                normalDataArray.append(p0Norm.y)
                normalDataArray.append(p0Norm.z)
                
                uvDataArray.append(speed)
                uvDataArray.append(offset)
                
                colorDataArray.append(lat2Norm)
                colorDataArray.append(lon2Norm)
                colorDataArray.append(phase)
                colorDataArray.append(loopIntensity)
                
                indices.append(currentIndex)
                currentIndex += 1
            }
        }
        
        let vertexData = Data(bytes: vertexDataArray, count: vertexDataArray.count * MemoryLayout<Float>.size)
        let vertexSource = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: Int(totalParticles), usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)

        let normalData = Data(bytes: normalDataArray, count: normalDataArray.count * MemoryLayout<Float>.size)
        let normalSource = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: Int(totalParticles), usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)

        let uvData = Data(bytes: uvDataArray, count: uvDataArray.count * MemoryLayout<Float>.size)
        let uvSource = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: Int(totalParticles), usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)

        let colorData = Data(bytes: colorDataArray, count: colorDataArray.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: Int(totalParticles), usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)

        let element = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size), primitiveType: .point, primitiveCount: Int(totalParticles), bytesPerIndex: MemoryLayout<Int32>.size)
        element.pointSize = 5.0
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 15.0

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, uvSource, colorSource], elements: [element])
        
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.diffuse.contents = createSoftGlowTexture()
        
        material.setValue(NSNumber(value: solarRadius), forKey: "u_solarRadius")
        
        material.shaderModifiers = [
            .geometry: """
            #pragma arguments
            float u_solarRadius;

            // NATIVE SCENEKIT VARYINGS (No structs, 100% crash proof)
            #pragma varyings
            float customT;
            float customPhase;
            float customLoopIntensity;

            #pragma body
            float3 p1 = _geometry.position.xyz; 
            float3 p0 = _geometry.normal * u_solarRadius;
            
            // Expand strictly positive colors back into spherical angles
            float lat2 = (_geometry.color.r * 3.14159f) - 1.57079f;
            float lon2 = (_geometry.color.g * 6.28318f) - 3.14159f;
            float3 p2 = float3(cos(lat2)*sin(lon2), sin(lat2), cos(lat2)*cos(lon2)) * u_solarRadius;
            
            float speed = _geometry.texcoords[0].x;
            float offset = _geometry.texcoords[0].y;
            
            // Physics time
            float t = fract(offset + (scn_frame.time * speed));
            
            // GPU Bezier Evaluation
            float u = 1.0f - t;
            float tt = t * t;
            float uu = u * u;
            float3 basePos = (p0 * uu) + (p1 * (2.0f * u * t)) + (p2 * tt);
            
            _geometry.position.xyz = basePos;
            
            // Output to native varyings
            out.customT = t;
            out.customPhase = _geometry.color.b;
            out.customLoopIntensity = _geometry.color.a;
            """,
            
            .fragment: """
            #pragma transparent
            #pragma body
            
            // Retrieve from native varyings
            float t = in.customT;
            float phase = in.customPhase;
            float loopIntensity = in.customLoopIntensity;

            float3 coreColor = float3(1.0f, 0.9f, 0.5f);
            float3 midColor  = float3(1.0f, 0.4f, 0.0f);
            float3 baseColor = mix(midColor, coreColor, loopIntensity);

            float alpha = sin(t * 3.14159f);
            float twinkle = (sin(scn_frame.time * 15.0f + phase * 6.28318f) * 0.5f) + 0.5f;
            
            _surface.emission.rgb = baseColor * 4.0f;
            _surface.transparent.a = _surface.diffuse.a * pow(alpha, 1.5f) * (0.4f + 0.6f * twinkle);
            """
        ]
        
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 2
        return node
    }
    
    public func createCoronalSurface(from lines: [MagneticLoopLine], solarRadius: Float) -> SCNNode {
        let masterNode = SCNNode()
        
        let baseLoopsNode = SCNNode(geometry: buildDataDrivenMagneticLoops(from: lines, solarRadius: solarRadius))
        let baseMaterial = SCNMaterial()
        baseMaterial.isDoubleSided = true
        baseMaterial.blendMode = .add
        baseMaterial.writesToDepthBuffer = false
        baseMaterial.readsFromDepthBuffer = true
        baseLoopsNode.geometry?.materials = [baseMaterial]
        baseLoopsNode.categoryBitMask = 2
        
        let energyTunnelsNode = buildEnergyTunnels(from: lines, particlesPerLine: 20, solarRadius: solarRadius)
        
        masterNode.addChildNode(baseLoopsNode)
        masterNode.addChildNode(energyTunnelsNode)
        
        return masterNode
    }
}

fileprivate func mixColor(_ a: simd_float4, _ b: simd_float4, factor: Float) -> simd_float4 {
    let f = max(0.0, min(1.0, factor))
    return a + (b - a) * f
}
