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
        
        // 4 Vertices per particle quad
        let totalVertices = totalParticles * 4
        var vertexDataArray = [Float](repeating: 0.0, count: totalVertices * 3)
        var normalDataArray = [Float](repeating: 0.0, count: totalVertices * 3)
        
        var uv0DataArray    = [Float](repeating: 0.0, count: totalVertices * 2) // Base Quad UVs
        var uv1DataArray    = [Float](repeating: 0.0, count: totalVertices * 2) // Speed & Offset
        var uv2DataArray    = [Float](repeating: 0.0, count: totalVertices * 2) // Phase & Intensity
        var tangentDataArray = [Float](repeating: 0.0, count: totalVertices * 4) // Lat, Lon, Quad X/Y
        
        var indices = [UInt32](repeating: 0, count: totalParticles * 6) // 2 Triangles per quad
        
        let pi = Float.pi
        let twoPi = Float.pi * 2.0
        var pIdx = 0
        
        // Base Quad offsets (-1 to 1 for perfect math circle generation)
        let quadOffsets: [simd_float2] = [
            simd_float2(-1, -1), simd_float2(1, -1),
            simd_float2(-1,  1), simd_float2(1,  1)
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
                
                // Construct 4 vertices for each particle quad
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
                    uv0DataArray[vOffset2] = quadOffsets[j].x
                    uv0DataArray[vOffset2 + 1] = quadOffsets[j].y
                    
                    uv1DataArray[vOffset2] = speed
                    uv1DataArray[vOffset2 + 1] = offset
                    
                    uv2DataArray[vOffset2] = phase
                    uv2DataArray[vOffset2 + 1] = loopIntensity
                    
                    let vOffset4 = vIdx * 4
                    tangentDataArray[vOffset4] = lat2Norm
                    tangentDataArray[vOffset4 + 1] = lon2Norm
                    tangentDataArray[vOffset4 + 2] = quadOffsets[j].x
                    tangentDataArray[vOffset4 + 3] = quadOffsets[j].y
                }
                
                // Add standard CCW Triangles for the quad
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
        
        let tangentData = Data(bytes: tangentDataArray, count: tangentDataArray.count * MemoryLayout<Float>.size)
        let tangentSource = SCNGeometrySource(data: tangentData, semantic: .tangent, vectorCount: totalVertices, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)

        let element = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size), primitiveType: .triangles, primitiveCount: totalParticles * 2, bytesPerIndex: MemoryLayout<UInt32>.size)

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, uv0Source, uv1Source, uv2Source, tangentSource], elements: [element])
        
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        
        // Force SceneKit to activate diffuse, ambient, and specular UV channels
#if os(macOS)
        let dummyColor = NSColor.black
#else
        let dummyColor = UIColor.black
#endif
        material.diffuse.contents = dummyColor
        material.ambient.contents = dummyColor
        material.specular.contents = dummyColor
        
        material.setValue(NSNumber(value: solarRadius), forKey: "u_solarRadius")
        
        material.shaderModifiers = [
            .geometry: """
            #pragma arguments
            float u_solarRadius;

            #pragma body
            float3 p1 = _geometry.position.xyz; 
            float3 p0 = _geometry.normal * u_solarRadius;
            
            float speed = _geometry.texcoords[1].x;
            float offset = _geometry.texcoords[1].y;
            
            float phase = _geometry.texcoords[2].x;
            float loopIntensity = _geometry.texcoords[2].y;
            
            float lat2Norm = _geometry.tangent.x;
            float lon2Norm = _geometry.tangent.y;
            float quadX = _geometry.tangent.z;
            float quadY = _geometry.tangent.w;
            
            float lat2 = (lat2Norm * 3.14159f) - 1.57079f;
            float lon2 = (lon2Norm * 6.28318f) - 3.14159f;
            float3 p2 = float3(cos(lat2)*sin(lon2), sin(lat2), cos(lat2)*cos(lon2)) * u_solarRadius;
            
            float t = fract(offset + (scn_frame.time * speed));
            
            float u = 1.0f - t;
            float tt = t * t;
            float uu = u * u;
            float3 basePos = (p0 * uu) + (p1 * (2.0f * u * t)) + (p2 * tt);
            
            // Extract camera-facing billboard vectors
            float3 camRight = scn_node.inverseModelViewTransform[0].xyz;
            float3 camUp    = scn_node.inverseModelViewTransform[1].xyz;
            
            // Particle pulsing size effect based on time
            float particleSize = (0.012f + (sin(t * 3.14159f) * 0.012f)) * u_solarRadius;
            float3 localOffset = (camRight * quadX + camUp * quadY) * particleSize;
            
            // Final Quad projection
            _geometry.position.xyz = basePos + localOffset;
            
            // Repack variables into UVs strictly for the fragment shader
            _geometry.texcoords[0] = float2(quadX, quadY);
            _geometry.texcoords[1] = float2(t, phase);
            _geometry.texcoords[2] = float2(loopIntensity, 0.0f);
            """,
            
            .fragment: """
            #pragma transparent
            #pragma body
            
            // Extract our physics payload directly from the UVs
            float2 quadUV = _surface.diffuseTexcoord;
            float t = _surface.ambientTexcoord.x;
            float phase = _surface.ambientTexcoord.y;
            float loopIntensity = _surface.specularTexcoord.x;

            // Mathematical Plasma Circle (-1 to +1)
            float dist = length(quadUV);
            if (dist > 1.0f) {
                discard_fragment();
            }

            float3 coreColor = float3(1.0f, 0.9f, 0.5f);
            float3 midColor  = float3(1.0f, 0.4f, 0.0f);
            float3 baseColor = mix(midColor, coreColor, loopIntensity);

            // Calculate soft, glowing falloff
            float alpha = smoothstep(1.0f, 0.1f, dist);
            float timeFade = sin(t * 3.14159f);
            float twinkle = (sin(scn_frame.time * 15.0f + phase * 6.28318f) * 0.5f) + 0.5f;
            
            // Additive Blending magic: Corners must be pitch black (0,0,0) to be invisible
            _surface.emission.rgb = baseColor * 6.0f * (alpha * timeFade * twinkle);
            
            // Prevent diffuse from interfering
            _surface.diffuse.rgb = float3(0.0f);
            """
        ]
        
        geometry.materials = [material]
        
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 2
        return node
    }
}
