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
        
        // 1. Ignore all scene lights; this object generates its own light
        material.lightingModel = .constant
        
        // 2. Base Color: A very deep, hot magenta/orange
        // We use NSColor (or UIColor on iOS) for basic emission
        #if os(macOS)
        let loopColor = NSColor(red: 1.0, green: 0.3, blue: 0.1, alpha: 1.0)
        #else
        let loopColor = UIColor(red: 1.0, green: 0.3, blue: 0.1, alpha: 1.0)
        #endif
        
        // Set both diffuse and emission to the same color
        material.diffuse.contents = loopColor
        material.emission.contents = loopColor
        
        // 3. Additive Blending
        // When loops overlap, their colors are added together (Red + Green = Yellow/White).
        // This creates the illusion of intense, volumetric heat at the base where lines cluster.
        material.blendMode = .add
        
        // 4. Ensure it renders correctly from all angles
        material.isDoubleSided = true
        
        // Optional: If you want to push the HDR values manually past 1.0
        // to force your camera's bloom threshold to trigger hard:
        // material.setValue(NSNumber(value: 2.5), forKey: "emissionIntensity")
        
        return material
    }

    func buildMagneticLoops(for event: AveragedCMEData, loopCount: Int = 40, pointsPerLoop: Int = 50, solarRadius: Float = 1.0) -> SCNGeometry {
        
        let latRad = Float(event.latitude ?? 0.0) * .pi / 180.0
        let lonRad = Float(event.longitude ?? 0.0) * .pi / 180.0
        
        // 1. Establish the exact center of the Active Region on the sphere
        let coreNormal = simd_float3(
            cos(latRad) * cos(lonRad),
            sin(latRad),
            cos(latRad) * sin(lonRad)
        )
        
        // 2. Calculate local Tangent and Bitangent vectors to spread the loops around the core
        let up = abs(coreNormal.y) > 0.99 ? simd_float3(1, 0, 0) : simd_float3(0, 1, 0)
        let tangent = simd_normalize(simd_cross(up, coreNormal))
        let bitangent = simd_normalize(simd_cross(coreNormal, tangent))
        
        var vertices: [simd_float3] = []
        var indices: [Int32] = []
        
        var currentIndex: Int32 = 0
        
        // 3. Procedurally generate 'loopCount' magnetic arches
        for _ in 0..<loopCount {
            // Randomize the footprint spread (how wide the base of the loop is)
            let footprintSpread = Float.random(in: 0.02...0.15)
            let angle = Float.random(in: 0...(2 * .pi))
            
            // Offset the start and end points in opposite directions on the surface
            let offset = (tangent * cos(angle) + bitangent * sin(angle)) * footprintSpread
            
            var startPoint = simd_normalize(coreNormal + offset)
            var endPoint = simd_normalize(coreNormal - offset)
            
            startPoint *= solarRadius
            endPoint *= solarRadius
            
            // --- THE FIX: TIGHTER, LOWER CONTROL POINTS ---
            // Reduced the speed scalar from 0.0005 to 0.0001
            // Adjusted the random bounds from 0.5...1.5 down to 0.2...0.6
            // This prevents the control point from stretching the curve into a sharp spike
            let loopHeight = Float(event.speed) * 0.0001 * Float.random(in: 0.2...0.6)
            
            var controlPoint = simd_normalize(coreNormal)
            controlPoint *= (solarRadius + loopHeight)
            // ----------------------------------------------
            
            // 4. Interpolate points along the loop using a Quadratic Bézier Curve
            for i in 0..<pointsPerLoop {
                let t = Float(i) / Float(pointsPerLoop - 1)
                let oneMinusT = 1.0 - t
                
                // Bézier math: P(t) = (1-t)^2*P0 + 2(1-t)t*P1 + t^2*P2
                let p0 = startPoint * (oneMinusT * oneMinusT)
                let p1 = controlPoint * (2.0 * oneMinusT * t)
                let p2 = endPoint * (t * t)
                
                let curvePoint = p0 + p1 + p2
                vertices.append(curvePoint)
                
                // Connect lines (0-1, 1-2, 2-3...)
                if i > 0 {
                    indices.append(currentIndex - 1)
                    indices.append(currentIndex)
                }
                currentIndex += 1
            }
        }
        
        // 5. Build SCNGeometry using Line segments
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<simd_float3>.size)
        
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size
        )
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .line, primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        return SCNGeometry(sources: [vertexSource], elements: [element])
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
