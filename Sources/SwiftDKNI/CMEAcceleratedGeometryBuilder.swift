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
        
        #if os(macOS)
        material.diffuse.contents = NSColor.white
        #else
        material.diffuse.contents = UIColor.white
        #endif
        
        material.blendMode = .add
        material.isDoubleSided = true
        
        // --- NEW: THE FLOW SHADER ---
        let flowShader = """
        #pragma transparent
        
        // 1. Read the custom UV track using SceneKit's Metal surface struct
        float trackPosition = _surface.diffuseTexcoord.x;
        float phaseOffset = _surface.diffuseTexcoord.y;
        
        // 2. Control the speed of the plasma flow
        float speed = 0.6; 
        
        // 3. The Math: Metal uses scn_frame.time instead of old GLSL u_time
        float flow = fract(trackPosition - (scn_frame.time * speed) + phaseOffset);
        
        // 4. Shape the "Pulse". We invert the flow so the head is 1.0 and the tail fades to 0.0
        float tail = 1.0 - flow;
        
        // 5. Sharpen the pulse using a power curve. 
        // An exponent of 8.0 makes a tight, bright head with a fast-fading tail.
        float pulse = pow(tail, 8.0);
        
        // 6. Apply the mask to the existing vertex colors
        _surface.emission *= pulse;
        _surface.transparent.a *= pulse;
        """
        
        // Inject the shader into the surface rendering pass
        material.shaderModifiers = [.surface: flowShader]
        
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
        var colors: [simd_float4] = []
        var uvs: [simd_float2] = [] // NEW: Texture coordinates to act as the "track"
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
            
            // NEW: Randomize animation start time and flow direction for each loop
            let phaseOffset = Float.random(in: 0.0...1.0)
            let flowsForward = Bool.random()
            
            for i in 0..<pointsPerLoop {
                let t = Float(i) / Float(pointsPerLoop - 1)
                let oneMinusT = 1.0 - t
                
                // Geometry Math
                let p0 = startPoint * (oneMinusT * oneMinusT)
                let p1 = controlPoint * (2.0 * oneMinusT * t)
                let p2 = endPoint * (t * t)
                vertices.append(p0 + p1 + p2)
                
                // Temperature Gradient (Apex is at t=0.5)
                let distanceFromApex = abs(t - 0.5) * 2.0
                let r: Float = 1.0
                let g: Float = 0.1 + (0.8 * distanceFromApex)
                let b: Float = 0.0 + (0.5 * distanceFromApex)
                let a: Float = 0.3 + (0.7 * distanceFromApex)
                colors.append(simd_float4(r, g, b, a))
                
                // NEW: Set the UV address for the Shader.
                // X is the position on the track, Y is the random start time delay.
                let trackPosition = flowsForward ? t : (1.0 - t)
                uvs.append(simd_float2(trackPosition, phaseOffset))
                
                if i > 0 {
                    indices.append(currentIndex - 1)
                    indices.append(currentIndex)
                }
                currentIndex += 1
            }
        }
        
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<simd_float3>.size)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<simd_float4>.size)
        let uvData = Data(bytes: uvs, count: uvs.count * MemoryLayout<simd_float2>.size) // NEW
        
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size
        )
        
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float4>.size
        )
        
        // NEW: Tell SceneKit about our UV track
        let uvSource = SCNGeometrySource(
            data: uvData, semantic: .texcoord, vectorCount: uvs.count,
            usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float2>.size
        )
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .line, primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        return SCNGeometry(sources: [vertexSource, colorSource, uvSource], elements: [element])
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
