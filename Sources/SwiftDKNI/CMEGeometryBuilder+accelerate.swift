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
    
    private func generateAcceleratedRandoms(count: Int, min: Float, max: Float) -> [Float] {
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
        
        var vertexDataArray = [Float](repeating: 0.0, count: totalParticles * 3)
        var normalDataArray = [Float](repeating: 0.0, count: totalParticles * 3)
        var colorDataArray  = [Float](repeating: 0.0, count: totalParticles * 4)
        
        // Multi-UV Channels
        var uv0DataArray    = [Float](repeating: 0.0, count: totalParticles * 2)
        var uv1DataArray    = [Float](repeating: 0.0, count: totalParticles * 2)
        
        var indices         = [Int32](repeating: 0, count: totalParticles)
        
        let pi = Float.pi
        let twoPi = Float.pi * 2.0
        var pIdx = 0
        
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
                let vOffset = pIdx * 3
                vertexDataArray[vOffset] = p1.x
                vertexDataArray[vOffset + 1] = p1.y
                vertexDataArray[vOffset + 2] = p1.z
                
                normalDataArray[vOffset] = p0Norm.x
                normalDataArray[vOffset + 1] = p0Norm.y
                normalDataArray[vOffset + 2] = p0Norm.z
                
                let cOffset = pIdx * 4
                colorDataArray[cOffset] = phases[pIdx]
                colorDataArray[cOffset + 1] = loopIntensity
                colorDataArray[cOffset + 2] = 1.0 // Unused but initialized safely
                colorDataArray[cOffset + 3] = 1.0
                
                let uvOffset = pIdx * 2
                uv0DataArray[uvOffset] = speeds[pIdx]
                uv0DataArray[uvOffset + 1] = offsets[pIdx]
                
                uv1DataArray[uvOffset] = lat2Norm
                uv1DataArray[uvOffset + 1] = lon2Norm
                
                indices[pIdx] = Int32(pIdx)
                pIdx += 1
            }
        }
        
        let vertexData = Data(bytes: vertexDataArray, count: vertexDataArray.count * MemoryLayout<Float>.size)
        let vertexSource = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)

        let normalData = Data(bytes: normalDataArray, count: normalDataArray.count * MemoryLayout<Float>.size)
        let normalSource = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)

        let colorData = Data(bytes: colorDataArray, count: colorDataArray.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)

        let uv0Data = Data(bytes: uv0DataArray, count: uv0DataArray.count * MemoryLayout<Float>.size)
        let uv0Source = SCNGeometrySource(data: uv0Data, semantic: .texcoord, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)

        let uv1Data = Data(bytes: uv1DataArray, count: uv1DataArray.count * MemoryLayout<Float>.size)
        let uv1Source = SCNGeometrySource(data: uv1Data, semantic: .texcoord, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)

        let element = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size), primitiveType: .point, primitiveCount: totalParticles, bytesPerIndex: MemoryLayout<Int32>.size)
        element.pointSize = 5.0
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 15.0

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource, uv0Source, uv1Source], elements: [element])
        
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.diffuse.contents = generateAcceleratedGlowTexture()
        
        material.setValue(NSNumber(value: solarRadius), forKey: "u_solarRadius")
        
        // NO VARYINGS! We use safe UVs and pass T down securely via the tangent channel
        material.shaderModifiers = [
            .geometry: """
            #pragma arguments
            float u_solarRadius;

            #pragma body
            float3 p1 = _geometry.position.xyz; 
            float3 p0 = _geometry.normal * u_solarRadius;
            
            float speed = _geometry.texcoords[0].x;
            float offset = _geometry.texcoords[0].y;
            
            float lat2Norm = _geometry.texcoords[1].x;
            float lon2Norm = _geometry.texcoords[1].y;
            
            float lat2 = (lat2Norm * 3.14159f) - 1.57079f;
            float lon2 = (lon2Norm * 6.28318f) - 3.14159f;
            float3 p2 = float3(cos(lat2)*sin(lon2), sin(lat2), cos(lat2)*cos(lon2)) * u_solarRadius;
            
            float t = fract(offset + (scn_frame.time * speed));
            
            float u = 1.0f - t;
            float tt = t * t;
            float uu = u * u;
            float3 basePos = (p0 * uu) + (p1 * (2.0f * u * t)) + (p2 * tt);
            
            _geometry.position.xyz = basePos;
            
            // Pass 't' to Fragment via tangent
            _geometry.tangent.x = t;
            """,
            
            .fragment: """
            #pragma transparent
            #pragma body
            
            // Unpack everything safely
            float t = _surface.tangent.x;
            float phase = _surface.color.r;
            float loopIntensity = _surface.color.g;

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
    
    private func generateAcceleratedGlowTexture() -> XImage {
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
}

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
