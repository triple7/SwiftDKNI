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
    
    // A blisteringly fast random float generator using Accelerate (vDSP)
    private func generateAcceleratedRandoms(count: Int, min: Float, max: Float) -> [Float] {
        // 1. Generate raw random bytes instantly at the C-level
        var randomInts = [UInt32](repeating: 0, count: count)
        arc4random_buf(&randomInts, count * MemoryLayout<UInt32>.size)
        
        var randomFloats = [Float](repeating: 0.0, count: count)
        
        // 2. Convert UInt32 to Float natively using vector hardware
        vDSP_vfltu32(randomInts, 1, &randomFloats, 1, vDSP_Length(count))
        
        // 3. Divide by UInt32.max to normalize everything to 0.0 ... 1.0
        var divisor = Float(UInt32.max)
        vDSP_vsdiv(randomFloats, 1, &divisor, &randomFloats, 1, vDSP_Length(count))
        
        // 4. Scale to the requested range (min ... max) using Vector Multiply and Add
        var range = max - min
        var offset = min
        vDSP_vsmsa(randomFloats, 1, &range, &offset, &randomFloats, 1, vDSP_Length(count))
        
        return randomFloats
    }
    
    public func buildAcceleratedEnergyTunnels(from lines: [MagneticLoopLine], particlesPerLine: Int = 20, solarRadius: Float) -> SCNNode {
        
        let validLines = lines.filter { !$0.isOpen }
        let totalParticles = validLines.count * particlesPerLine
        guard totalParticles > 0 else { return SCNNode() }
        
        // 1. Generate ALL random numbers instantly via Accelerate
        let offsets = generateAcceleratedRandoms(count: totalParticles, min: 0.0, max: 1.0)
        let speeds  = generateAcceleratedRandoms(count: totalParticles, min: 0.05, max: 0.25)
        let phases  = generateAcceleratedRandoms(count: totalParticles, min: 0.0, max: 1.0)
        
        // 2. Pre-allocate arrays
        var vertexDataArray = [Float](repeating: 0.0, count: totalParticles * 3)
        var normalDataArray = [Float](repeating: 0.0, count: totalParticles * 3)
        var uvDataArray     = [Float](repeating: 0.0, count: totalParticles * 2)
        var colorDataArray  = [Float](repeating: 0.0, count: totalParticles * 4)
        var indices         = [Int32](repeating: 0, count: totalParticles)
        
        let pi = Float.pi
        let twoPi = Float.pi * 2.0
        var pIdx = 0
        
        // 3. Use UnsafeMutableBufferPointers for zero-overhead memory writing
        vertexDataArray.withUnsafeMutableBufferPointer { vPtr in
        normalDataArray.withUnsafeMutableBufferPointer { nPtr in
        uvDataArray.withUnsafeMutableBufferPointer { uPtr in
        colorDataArray.withUnsafeMutableBufferPointer { cPtr in
        indices.withUnsafeMutableBufferPointer { iPtr in
            
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
                    // Direct pointer arithmetic - no Swift Array overhead
                    let vOffset = pIdx * 3
                    vPtr[vOffset] = p1.x
                    vPtr[vOffset + 1] = p1.y
                    vPtr[vOffset + 2] = p1.z
                    
                    let nOffset = pIdx * 3
                    nPtr[nOffset] = p0Norm.x
                    nPtr[nOffset + 1] = p0Norm.y
                    nPtr[nOffset + 2] = p0Norm.z
                    
                    let uOffset = pIdx * 2
                    uPtr[uOffset] = speeds[pIdx]
                    uPtr[uOffset + 1] = offsets[pIdx]
                    
                    let cOffset = pIdx * 4
                    cPtr[cOffset] = lat2Norm
                    cPtr[cOffset + 1] = lon2Norm
                    cPtr[cOffset + 2] = phases[pIdx]
                    cPtr[cOffset + 3] = loopIntensity
                    
                    iPtr[pIdx] = Int32(pIdx)
                    pIdx += 1
                }
            }
        }}}}}
        
        // 4. Construct SCNGeometry exactly as before
        let vertexData = Data(bytes: vertexDataArray, count: vertexDataArray.count * MemoryLayout<Float>.size)
        let vertexSource = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)

        let normalData = Data(bytes: normalDataArray, count: normalDataArray.count * MemoryLayout<Float>.size)
        let normalSource = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)

        let uvData = Data(bytes: uvDataArray, count: uvDataArray.count * MemoryLayout<Float>.size)
        let uvSource = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)

        let colorData = Data(bytes: colorDataArray, count: colorDataArray.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: totalParticles, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)

        let element = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size), primitiveType: .point, primitiveCount: totalParticles, bytesPerIndex: MemoryLayout<Int32>.size)
        element.pointSize = 5.0
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 15.0

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, uvSource, colorSource], elements: [element])
        
        // (Material and Shader setup remains identical to the previous implementation)
        // ...
        
        return SCNNode(geometry: geometry)
    }
}
