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

    func createMagneticLoopMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        
        // By setting contents to pure white, we allow the vertex colors
        // to pass through exactly as they are calculated.
        #if os(macOS)
        material.diffuse.contents = NSColor.white
        #else
        material.diffuse.contents = UIColor.white
        #endif
        
        material.blendMode = .add
        material.isDoubleSided = true
        return material
    }

    func buildMagneticLoops(for event: AveragedCMEData, loopCount: Int = 40, pointsPerLoop: Int = 50, solarRadius: Float = 1.0) -> SCNGeometry {
        
        let latRad = Float(event.latitude ?? 0.0) * .pi / 180.0
        let lonRad = Float(event.longitude ?? 0.0) * .pi / 180.0
        
        let coreNormal = simd_float3(
            cos(latRad) * cos(lonRad),
            sin(latRad),
            cos(latRad) * sin(lonRad)
        )
        
        let up = abs(coreNormal.y) > 0.99 ? simd_float3(1, 0, 0) : simd_float3(0, 1, 0)
        let tangent = simd_normalize(simd_cross(up, coreNormal))
        let bitangent = simd_normalize(simd_cross(coreNormal, tangent))
        
        var vertices: [simd_float3] = []
        var colors: [simd_float4] = [] // NEW: Array to hold RGBA values per point
        var indices: [Int32] = []
        var currentIndex: Int32 = 0
        
        for _ in 0..<loopCount {
            let footprintSpread = Float.random(in: 0.02...0.15)
            let angle = Float.random(in: 0...(2 * .pi))
            
            let offset = (tangent * cos(angle) + bitangent * sin(angle)) * footprintSpread
            
            var startPoint = simd_normalize(coreNormal + offset)
            var endPoint = simd_normalize(coreNormal - offset)
            
            startPoint *= solarRadius
            endPoint *= solarRadius
            
            let loopHeight = Float(event.speed) * 0.0001 * Float.random(in: 0.2...0.6)
            
            var controlPoint = simd_normalize(coreNormal)
            controlPoint *= (solarRadius + loopHeight)
            
            for i in 0..<pointsPerLoop {
                let t = Float(i) / Float(pointsPerLoop - 1)
                let oneMinusT = 1.0 - t
                
                // 1. Geometry Math
                let p0 = startPoint * (oneMinusT * oneMinusT)
                let p1 = controlPoint * (2.0 * oneMinusT * t)
                let p2 = endPoint * (t * t)
                vertices.append(p0 + p1 + p2)
                
                // --- NEW: TEMPERATURE & OPACITY GRADIENT MATH ---
                // t = 0.0 is the start base, t = 1.0 is the end base, t = 0.5 is the apex.
                // This normalizes the distance from the apex so 0 is the apex and 1 is the bases.
                let distanceFromApex = abs(t - 0.5) * 2.0
                
                // Base (Hot): Bright Yellow/White, 100% Opacity
                // Apex (Cool): Deep Red, 30% Opacity
                let r: Float = 1.0
                let g: Float = 0.1 + (0.8 * distanceFromApex) // Dips to 0.1 at apex
                let b: Float = 0.0 + (0.5 * distanceFromApex) // Dips to 0.0 at apex
                let a: Float = 0.3 + (0.7 * distanceFromApex) // Dips to 30% opacity at apex
                
                colors.append(simd_float4(r, g, b, a))
                // ------------------------------------------------
                
                if i > 0 {
                    indices.append(currentIndex - 1)
                    indices.append(currentIndex)
                }
                currentIndex += 1
            }
        }
        
        // Build Data blocks
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<simd_float3>.size)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<simd_float4>.size) // NEW
        
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size
        )
        
        // NEW: Tell SceneKit how to read the vertex colors
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float4>.size
        )
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .line, primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        // Add the colorSource to the geometry return
        return SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
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
