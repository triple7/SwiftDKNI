//
//  CMEAcceleratedGeometryBuilder.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//


import SceneKit
import CoreGraphics
import Accelerate
import simd

/// Handles the mathematical generation of Flux Ropes, Helical CME particles, and Magnetic Loops
public final class CMEGeometryBuilder: Sendable {
    
    public init() {}
    
    private struct ConcurrentPointer<T>: @unchecked Sendable {
        let baseAddress: UnsafeMutablePointer<T>
    }
    
    // MARK: - 1. Material & Shader Generation
    
    /// Generates a soft white-to-transparent radial gradient in memory
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
    
    public func createMagneticLoopMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        
        // Use the soft radial gradient to turn harsh pixels into volumetric plasma
        material.diffuse.contents = createSoftGlowTexture()
        material.blendMode = .add
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        
        let flowShader = """
        #pragma transparent
        
        // Read the custom UV track (x = curve position, y = random phase)
        float trackPosition = _surface.diffuseTexcoord.x;
        float phaseOffset = _surface.diffuseTexcoord.y;
        
        float speed = 0.6; 
        float flow = fract(trackPosition - (scn_frame.time * speed) + phaseOffset);
        
        // Shape the pulse: bright head, trailing tail
        float tail = 1.0 - flow;
        float pulse = max(0.1, pow(tail, 8.0));
        
        // Multiply vertex emission and texture alpha by the velocity pulse
        _surface.emission *= pulse;
        _surface.transparent.a *= pulse;
        """
        
        material.shaderModifiers = [.surface: flowShader]
        return material
    }
    
    // MARK: - 2. Temporal Math
    
    /// Calculates the current physical longitude of a historical solar event
    /// by factoring in the Sun's average synodic rotation rate (13.2 degrees/day).
    func calculateRotatedLongitude(originalLongitude: Float, eventDate: Date?, currentDate: Date = Date()) -> Float {
        guard let eventDate = eventDate else {
            return originalLongitude
        }
        
        // The Sun rotates approx 13.2 degrees per day relative to an Earth observer
        let solarRotationRatePerDay: Float = 13.2
        
        // Calculate how many days ago the event happened
        let timeInterval = currentDate.timeIntervalSince(eventDate)
        let daysPassed = Float(timeInterval / (60 * 60 * 24))
        
        // Calculate the rotational offset
        let offsetDegrees = daysPassed * solarRotationRatePerDay
        
        // Add offset to the original longitude (Sunspots move East to West across the face)
        var newLongitude = originalLongitude + offsetDegrees
        
        // Normalize the longitude to stay within standard -180 to 180 spherical coordinates
        newLongitude = newLongitude.truncatingRemainder(dividingBy: 360.0)
        
        if newLongitude > 180.0 {
            newLongitude -= 360.0
        } else if newLongitude < -180.0 {
            newLongitude += 360.0
        }
        
        return newLongitude
    }
    
    // MARK: - 3. The Flux Rope Mathematics (SIMD)
    
    /// A single Bezier curve representing a stretched magnetic field line
    private struct MagneticFieldLine {
        let p0: simd_float3 // Root 1
        let p1: simd_float3 // Apex (Stretched by solar wind/ejection)
        let p2: simd_float3 // Root 2
        
        // Evaluates position along the curve (t = 0.0 to 1.0)
        func position(at t: Float) -> simd_float3 {
            let u = 1.0 - t
            let tt = t * t
            let uu = u * u
            
            let term1 = p0 * uu
            let term2 = p1 * (2.0 * u * t)
            let term3 = p2 * tt
            
            return term1 + term2 + term3
        }
        
        // Evaluates the forward direction (tangent) along the curve
        func tangent(at t: Float) -> simd_float3 {
            let u = 1.0 - t
            let dP1 = (p1 - p0) * (2.0 * u)
            let dP2 = (p2 - p1) * (2.0 * t)
            return simd_normalize(dP1 + dP2)
        }
    }
    
    /// Generates the mathematical skeleton for both the loops and the particles to share
    private func generateFluxRopeSkeleton(lat: Float, lon: Float, radius: Float, speed: Float, halfAngle: Float, lineCount: Int) -> [MagneticFieldLine] {
        var lines: [MagneticFieldLine] = []
        
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        
        // Center point of the eruption on the surface
        let centerDir = simd_float3(
            cos(latRad) * sin(lonRad),
            sin(latRad),
            cos(latRad) * cos(lonRad)
        )
        
        // Establish a local coordinate system to spread the roots
        let up = simd_float3(0, 1, 0)
        var right = simd_cross(centerDir, up)
        if simd_length(right) < 0.001 { right = simd_float3(1, 0, 0) }
        right = simd_normalize(right)
        let localUp = simd_normalize(simd_cross(right, centerDir))
        
        // The force of the CME stretches the loops massively outward
        let heightMultiplier = 1.2 + (speed / 1000.0) // Faster CMEs stretch loops higher
        let spreadRad = (halfAngle > 0 ? halfAngle : 20.0) * .pi / 180.0
        
        for _ in 0..<lineCount {
            // Randomize root spread on the surface
            let r1 = Float.random(in: -1.0...1.0) * spreadRad
            let r2 = Float.random(in: -1.0...1.0) * spreadRad
            let rootOffset1 = (right * r1) + (localUp * r2)
            let rootOffset2 = (right * -r1) + (localUp * -r2) // Opposite side of the active region
            
            let p0 = simd_normalize(centerDir + rootOffset1) * radius
            let p2 = simd_normalize(centerDir + rootOffset2) * radius
            
            // The Skew: Push the apex outward along the eruption vector, blowing it into space
            let outwardSkew = centerDir * (radius * heightMultiplier)
            let noiseOffset = (right * Float.random(in: -0.2...0.2)) + (localUp * Float.random(in: -0.2...0.2))
            
            let p1 = (centerDir * radius) + outwardSkew + (noiseOffset * radius)
            
            lines.append(MagneticFieldLine(p0: p0, p1: p1, p2: p2))
        }
        
        return lines
    }
    
    // MARK: - 4. Geometry Generators
    
    /// Builds the visible magnetic arches
    public func buildMagneticLoops(for event: AveragedCMEData, loopCount: Int = 40, pointsPerLoop: Int = 50, solarRadius: Float = 1.0) -> SCNGeometry {
        let lat = Float(event.latitude ?? 0.0)
        let rotatedLon = calculateRotatedLongitude(originalLongitude: Float(event.longitude ?? 0.0), eventDate: event.parsedDate)
        
        let speed = Float(event.speed)
        let halfAngle = Float(event.halfAngle)
        
        // Use the new skewed math but map it to your loopCount and pointsPerLoop
        let skeleton = generateFluxRopeSkeleton(lat: lat, lon: rotatedLon, radius: solarRadius, speed: speed, halfAngle: halfAngle, lineCount: loopCount)
        
        var vertices: [simd_float3] = []
        var indices: [Int32] = []
        var texcoords: [simd_float2] = [] // u = t, v = phase
        
        var currentIndex: Int32 = 0
        
        for line in skeleton {
            let phase = Float.random(in: 0.0...1.0)
            
            for i in 0...pointsPerLoop {
                let t = Float(i) / Float(pointsPerLoop)
                vertices.append(line.position(at: t))
                texcoords.append(simd_float2(t, phase))
                
                if i > 0 {
                    indices.append(currentIndex - 1)
                    indices.append(currentIndex)
                }
                currentIndex += 1
            }
        }
        
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<simd_float3>.size)
        let source = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size
        )
        
        let uvData = Data(bytes: texcoords, count: texcoords.count * MemoryLayout<simd_float2>.size)
        let uvSource = SCNGeometrySource(
            data: uvData, semantic: .texcoord, vectorCount: texcoords.count,
            usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float2>.size
        )
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .line, primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        return SCNGeometry(sources: [source, uvSource], elements: [element])
    }
    
    /// Builds the helical CME point cloud spiraling around the magnetic lines.
    public func buildBoundaryShellAccelerated(for event: AveragedCMEData, pointCount: Int = 10000, solarRadius: Float = 1.0) -> SCNGeometry {
        let lat = Float(event.latitude ?? 0.0)
        let rotatedLon = calculateRotatedLongitude(originalLongitude: Float(event.longitude ?? 0.0), eventDate: event.parsedDate)
        
        let speed = Float(event.speed)
        let halfAngle = Float(event.halfAngle)
        
        // We use fewer skeleton lines for the particles to form distinct "strands" in the tornado
        let skeleton = generateFluxRopeSkeleton(lat: lat, lon: rotatedLon, radius: solarRadius, speed: speed, halfAngle: halfAngle, lineCount: 8)
        
        var vertices: [simd_float3] = []
        var texcoords: [simd_float2] = []
        var colors: [simd_float4] = []
        
        for _ in 0..<pointCount {
            // Pick a random magnetic field line from the skeleton
            let line = skeleton.randomElement()!
            
            // Pick a random progression along the line (weighted towards the top)
            let t = pow(Float.random(in: 0.1...1.0), 0.7)
            
            let centerPos = line.position(at: t)
            let tangent = line.tangent(at: t)
            
            // Create a Frenet frame (perpendicular axes) around the tangent to create the twist
            let arbitrary = simd_float3(0, 1, 0)
            var binormal = simd_cross(tangent, arbitrary)
            if simd_length(binormal) < 0.001 { binormal = simd_cross(tangent, simd_float3(1, 0, 0)) }
            binormal = simd_normalize(binormal)
            let normal = simd_normalize(simd_cross(tangent, binormal))
            
            // THE HELIX MATH: Twist the particle around the line based on how far out it is (t)
            let twistAngle = t * .pi * 6.0
            
            // The expansion: The tornado gets wider the further it gets from the surface
            let expansionRadius = (solarRadius * 0.05) + (t * solarRadius * 0.4 * (halfAngle / 30.0))
            
            // Add some noise so it's a gas cloud, not a solid cylinder
            let noiseX = Float.random(in: -0.5...0.5) * expansionRadius
            let noiseY = Float.random(in: -0.5...0.5) * expansionRadius
            
            let xOffset = binormal * (cos(twistAngle) * expansionRadius + noiseX)
            let yOffset = normal * (sin(twistAngle) * expansionRadius + noiseY)
            
            let finalPos = centerPos + xOffset + yOffset
            vertices.append(finalPos)
            
            // Map the UVs for the shader (u = distance from sun, v = random flicker phase)
            texcoords.append(simd_float2(t, Float.random(in: 0.0...1.0)))
            
            // Assign static velocity color based on 't'
            let coreColor = simd_float4(1.0, 1.0, 1.0, 1.0) // White Hot
            let midColor  = simd_float4(1.0, 0.8, 0.2, 1.0) // Yellow/Orange
            let edgeColor = simd_float4(0.8, 0.1, 0.0, 1.0) // Deep Red
            
            let color: simd_float4
            if t < 0.3 {
                color = mixColor(coreColor, midColor, factor: t / 0.3)
            } else {
                color = mixColor(midColor, edgeColor, factor: (t - 0.3) / 0.7)
            }
            colors.append(color)
        }
        
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<simd_float3>.size)
        let source = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float3>.size
        )
        
        let uvData = Data(bytes: texcoords, count: texcoords.count * MemoryLayout<simd_float2>.size)
        let uvSource = SCNGeometrySource(
            data: uvData, semantic: .texcoord, vectorCount: texcoords.count,
            usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float2>.size
        )
        
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<simd_float4>.size)
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float4>.size
        )
        
        let indices = Array(0..<Int32(pointCount))
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .point, primitiveCount: pointCount,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        element.pointSize = 3.0 // Ensures points are large enough to show the soft alpha mask
        
        return SCNGeometry(sources: [source, uvSource, colorSource], elements: [element])
    }
}

// MARK: - Helper Math Functions
fileprivate func mixColor(_ a: simd_float4, _ b: simd_float4, factor: Float) -> simd_float4 {
    let f = max(0.0, min(1.0, factor))
    // simd types naturally support algebraic operations without extensions!
    return a + (b - a) * f
}
