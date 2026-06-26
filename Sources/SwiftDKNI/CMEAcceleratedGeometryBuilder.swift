//
//  CMEAcceleratedGeometryBuilder.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//


import SceneKit
import Accelerate
import simd

private struct ConcurrentPointer<T>: @unchecked Sendable {
    let baseAddress: UnsafeMutablePointer<T>
}

public final class CMEGeometryBuilder: Sendable {
    
    /// Generates a boundary shell point cloud geometry utilizing modern Apple Accelerate Swift wrappers.
    /// - Parameters:
    ///   - event: The averaged space weather dataset.
    ///   - pointCount: Total number of vertices to generate for the shell.
    ///   - solarRadius: The radius of your central SCNSphere node.
    private struct ConcurrentPointer<T>: @unchecked Sendable {
        let baseAddress: UnsafeMutablePointer<T>
    }

    func buildBoundaryShellAccelerated(for event: AveragedCMEData, pointCount: Int = 10000, solarRadius: Float = 1.0) -> SCNGeometry {
        
        // 1. Generate uniform random distribution vectors (Now including 'w' for volumetric depth)
        let u = (0..<pointCount).map { _ in Float.random(in: 0...1) }
        let v = (0..<pointCount).map { _ in Float.random(in: 0...1) }
        let w = (0..<pointCount).map { _ in Float.random(in: 0...1) } // The radial depth factor
        
        // Pre-allocate destination buffers
        var zLocal = [Float](repeating: 0.0, count: pointCount)
        var xLocal = [Float](repeating: 0.0, count: pointCount)
        var yLocal = [Float](repeating: 0.0, count: pointCount)
        var radii  = [Float](repeating: 0.0, count: pointCount)
        
        let halfAngleRad = Float(event.halfAngle) * .pi / 180.0
        let cosMaxAngle = cos(halfAngleRad)
        let oneMinusCosMax = 1.0 - cosMaxAngle
        let twoPi = 2.0 * Float.pi
        
        // 2. Vectorized Math Operations using modern Swift Accelerate wrappers
        
        // phi = u * 2 * pi
        let phi = vDSP.multiply(twoPi, u)
        
        // Vectorized trigonometric calculations
        let sinPhi = vForce.sin(phi)
        let cosPhi = vForce.cos(phi)
        
        // zLocal = (v * oneMinusCosMax) + cosMaxAngle
        vDSP.multiply(oneMinusCosMax, v, result: &zLocal)
        vDSP.add(cosMaxAngle, zLocal, result: &zLocal)
        
        // sinTheta = sqrt(1.0 - zLocal^2)
        let zSquared = vDSP.square(zLocal)
        let negativeZSquared = vDSP.multiply(-1.0, zSquared)
        let oneMinusZSquared = vDSP.add(1.0, negativeZSquared)
        let sinTheta = vForce.sqrt(oneMinusZSquared)

        // xLocal = sinTheta * cosPhi, yLocal = sinTheta * sinPhi
        vDSP.multiply(sinTheta, cosPhi, result: &xLocal)
        vDSP.multiply(sinTheta, sinPhi, result: &yLocal)
        
        // --- THE FIX: VOLUMETRIC RADIAL DISTRIBUTION ---
        // Use the DONKI CME speed to determine the physical height of the flare
        let visualSpeedScale: Float = 0.001
        let cmeHeight = Float(event.speed) * visualSpeedScale
        
        // radii = solarRadius + (w * cmeHeight)
        // This pushes the points out of the 2D surface and fills the 3D cone volume
        vDSP.multiply(cmeHeight, w, result: &radii)
        vDSP.add(solarRadius, radii, result: &radii)
        
        // 3. Compute Rotation Alignment using simd matrix functions
        let latRad = Float(event.latitude ?? 0.0) * .pi / 180.0
        let lonRad = Float(event.longitude ?? 0.0) * .pi / 180.0
        
        let targetX = cos(latRad) * cos(lonRad)
        let targetY = sin(latRad)
        let targetZ = cos(latRad) * sin(lonRad)
        
        let defaultAxis = simd_float3(0, 0, 1)
        let targetAxis = simd_float3(targetX, targetY, targetZ)

        let quaternion = simd_quatf(from: defaultAxis, to: targetAxis)
        let rotationMatrix = simd_matrix3x3(quaternion)
        
        // Prepare contiguous memory blocks for SceneKit
        var vertices = [simd_float3](repeating: simd_float3(0, 0, 0), count: pointCount)
        var normals = [simd_float3](repeating: simd_float3(0, 0, 0), count: pointCount)
        
        // 4. Parallel batch transformation across CPU cores
        let safeX = xLocal
        let safeY = yLocal
        let safeZ = zLocal
        let safeRadii = radii // Pass the pre-calculated radial depths
        
        vertices.withUnsafeMutableBufferPointer { vBuffer in
            normals.withUnsafeMutableBufferPointer { nBuffer in
                
                guard let vBase = vBuffer.baseAddress,
                      let nBase = nBuffer.baseAddress else { return }
                
                let vConcurrent = ConcurrentPointer(baseAddress: vBase)
                let nConcurrent = ConcurrentPointer(baseAddress: nBase)
                
                DispatchQueue.concurrentPerform(iterations: pointCount) { idx in
                    // Read from the immutable copies
                    let localVec = simd_float3(safeX[idx], safeY[idx], safeZ[idx])
                    let alignedDirection = rotationMatrix * localVec
                    
                    // Write directly to memory
                    nConcurrent.baseAddress[idx] = alignedDirection
                    
                    // Multiply by the unique radius, not the flat solarRadius!
                    vConcurrent.baseAddress[idx] = alignedDirection * safeRadii[idx]
                }
            }
        }
        
        // 5. Build SCNGeometry Layout Structures
        let vertexData = Data(bytes: vertices, count: pointCount * MemoryLayout<simd_float3>.size)
        let normalData = Data(bytes: normals, count: pointCount * MemoryLayout<simd_float3>.size)
        
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: pointCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size
        )
        
        let normalSource = SCNGeometrySource(
            data: normalData, semantic: .normal, vectorCount: pointCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size
        )
        
        let indices = Array(0..<Int32(pointCount))
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .point, primitiveCount: pointCount,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }

    // Helper to generate a constant array of 1.0s for vectorized subtraction
    private func positiveOneArray(count: Int) -> [Float] {
        return [Float](repeating: 1.0, count: count)
    }
}
