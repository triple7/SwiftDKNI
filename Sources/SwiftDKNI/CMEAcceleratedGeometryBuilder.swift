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
        
        // Pipe the vertex color (stored in diffuse) directly into emission so it glows deeply,
        // and force the alpha to respect the soft mask, the pulse, AND the fading out to black space.
        _surface.emission.rgb = _surface.diffuse.rgb * pulse * 1.5;
        _surface.transparent.a = _surface.diffuse.a * pulse;
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
        
        let solarRotationRatePerDay: Float = 13.2
        let timeInterval = currentDate.timeIntervalSince(eventDate)
        let daysPassed = Float(timeInterval / (60 * 60 * 24))
        let offsetDegrees = daysPassed * solarRotationRatePerDay
        var newLongitude = originalLongitude + offsetDegrees
        
        newLongitude = newLongitude.truncatingRemainder(dividingBy: 360.0)
        
        if newLongitude > 180.0 {
            newLongitude -= 360.0
        } else if newLongitude < -180.0 {
            newLongitude += 360.0
        }
        
        return newLongitude
    }
    
    // MARK: - 3. The Flux Rope Mathematics (SIMD)
    
    private struct MagneticFieldLine {
        let p0: simd_float3 // Root 1
        let p1: simd_float3 // Apex (Stretched by solar wind/ejection)
        let p2: simd_float3 // Root 2
        
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
    
    private func generateFluxRopeSkeleton(lat: Float, lon: Float, radius: Float, speed: Float, halfAngle: Float, lineCount: Int) -> [MagneticFieldLine] {
        var lines: [MagneticFieldLine] = []
        
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        
        let centerDir = simd_float3(
            cos(latRad) * sin(lonRad),
            sin(latRad),
            cos(latRad) * cos(lonRad)
        )
        
        let up = simd_float3(0, 1, 0)
        var right = simd_cross(centerDir, up)
        if simd_length(right) < 0.001 { right = simd_float3(1, 0, 0) }
        right = simd_normalize(right)
        let localUp = simd_normalize(simd_cross(right, centerDir))
        
        // INCREASE THE SCALE: Push the tip further out to allow room for the greyish fade
        let heightMultiplier = 1.0 + (speed / 1500.0)
        let spreadRad = (halfAngle > 0 ? halfAngle : 15.0) * .pi / 180.0 * 0.75
        
        for _ in 0..<lineCount {
            let r1 = Float.random(in: -1.0...1.0) * spreadRad
            let r2 = Float.random(in: -1.0...1.0) * spreadRad
            let rootOffset1 = (right * r1) + (localUp * r2)
            let rootOffset2 = (right * -r1) + (localUp * -r2)
            
            let p0 = simd_normalize(centerDir + rootOffset1) * radius
            let p2 = simd_normalize(centerDir + rootOffset2) * radius
            
            let outwardSkew = centerDir * (radius * heightMultiplier)
            let noiseOffset = (right * Float.random(in: -0.15...0.15)) + (localUp * Float.random(in: -0.15...0.15))
            
            let p1 = (centerDir * radius) + outwardSkew + (noiseOffset * radius)
            
            lines.append(MagneticFieldLine(p0: p0, p1: p1, p2: p2))
        }
        
        return lines
    }
    
    // MARK: - 4. Geometry Generators
    
    public func buildMagneticLoops(for event: AveragedCMEData, loopCount: Int = 40, pointsPerLoop: Int = 50, solarRadius: Float = 1.0) -> SCNGeometry {
        let lat = Float(event.latitude ?? 0.0)
        let rotatedLon = calculateRotatedLongitude(originalLongitude: Float(event.longitude ?? 0.0), eventDate: event.parsedDate)
        
        let speed = Float(event.speed)
        let halfAngle = Float(event.halfAngle)
        
        let skeleton = generateFluxRopeSkeleton(lat: lat, lon: rotatedLon, radius: solarRadius, speed: speed, halfAngle: halfAngle, lineCount: loopCount)
        
        var vertices: [simd_float3] = []
        var indices: [Int32] = []
        var texcoords: [simd_float2] = []
        var colors: [simd_float4] = []
        
        var currentIndex: Int32 = 0
        
        for line in skeleton {
            let phase = Float.random(in: 0.0...1.0)
            
            for i in 0...pointsPerLoop {
                let t = Float(i) / Float(pointsPerLoop)
                vertices.append(line.position(at: t))
                texcoords.append(simd_float2(t, phase))
                
                // Calculates how far out into space we are (0.0 = surface roots, 1.0 = deep space apex)
                let outwardness = 1.0 - (abs(t - 0.5) * 2.0)
                
                // 3-Stage Dissipation: White -> Red -> Grey/Black
                let coreColor = simd_float4(1.0, 1.0, 1.0, 0.9)
                let midColor  = simd_float4(1.0, 0.7, 0.1, 0.6)
                let redColor  = simd_float4(0.8, 0.1, 0.0, 0.3)
                let tipColor  = simd_float4(0.05, 0.05, 0.05, 0.0) // Faded greyish black tip
                
                let color: simd_float4
                if outwardness < 0.25 {
                    color = mixColor(coreColor, midColor, factor: outwardness / 0.25)
                } else if outwardness < 0.6 {
                    color = mixColor(midColor, redColor, factor: (outwardness - 0.25) / 0.35)
                } else {
                    color = mixColor(redColor, tipColor, factor: (outwardness - 0.6) / 0.4)
                }
                colors.append(color)
                
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
        
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<simd_float4>.size)
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
        
        return SCNGeometry(sources: [source, uvSource, colorSource], elements: [element])
    }
    
    public func buildBoundaryShellAccelerated(for event: AveragedCMEData, pointCount: Int = 10000, solarRadius: Float = 1.0) -> SCNGeometry {
        let lat = Float(event.latitude ?? 0.0)
        let rotatedLon = calculateRotatedLongitude(originalLongitude: Float(event.longitude ?? 0.0), eventDate: event.parsedDate)
        
        let speed = Float(event.speed)
        let halfAngle = Float(event.halfAngle)
        
        let skeleton = generateFluxRopeSkeleton(lat: lat, lon: rotatedLon, radius: solarRadius, speed: speed, halfAngle: halfAngle, lineCount: 8)
        
        var vertices: [simd_float3] = []
        var texcoords: [simd_float2] = []
        var colors: [simd_float4] = []
        
        for _ in 0..<pointCount {
            let line = skeleton.randomElement()!
            let t = Float.random(in: 0.0...1.0)
            
            let centerPos = line.position(at: t)
            let tangent = line.tangent(at: t)
            
            let arbitrary = simd_float3(0, 1, 0)
            var binormal = simd_cross(tangent, arbitrary)
            if simd_length(binormal) < 0.001 { binormal = simd_cross(tangent, simd_float3(1, 0, 0)) }
            binormal = simd_normalize(binormal)
            let normal = simd_normalize(simd_cross(tangent, binormal))
            
            // Evaluates how far out into space we are
            let outwardness = 1.0 - (abs(t - 0.5) * 2.0)
            
            let twistAngle = outwardness * .pi * 8.0
            let expansionRadius = (solarRadius * 0.02) + (outwardness * solarRadius * 0.35 * (halfAngle / 30.0))
            
            let noiseX = Float.random(in: -0.5...0.5) * expansionRadius
            let noiseY = Float.random(in: -0.5...0.5) * expansionRadius
            
            let xOffset = binormal * (cos(twistAngle) * expansionRadius + noiseX)
            let yOffset = normal * (sin(twistAngle) * expansionRadius + noiseY)
            
            vertices.append(centerPos + xOffset + yOffset)
            texcoords.append(simd_float2(t, Float.random(in: 0.0...1.0)))
            
            // 3-Stage Dissipation: White -> Red -> Grey/Black
            let coreColor = simd_float4(1.0, 1.0, 1.0, 1.0)
            let midColor  = simd_float4(1.0, 0.6, 0.1, 0.7)
            let redColor  = simd_float4(0.7, 0.05, 0.0, 0.4)
            let tipColor  = simd_float4(0.05, 0.05, 0.05, 0.0) // Faded greyish black tip
            
            let color: simd_float4
            if outwardness < 0.25 {
                color = mixColor(coreColor, midColor, factor: outwardness / 0.25)
            } else if outwardness < 0.6 {
                color = mixColor(midColor, redColor, factor: (outwardness - 0.25) / 0.35)
            } else {
                color = mixColor(redColor, tipColor, factor: (outwardness - 0.6) / 0.4)
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
        
        // BOOST VOLUMETRIC SOFTNESS: Double the point size to blend the soft radial textures heavily
        element.pointSize = 6.0
        
        return SCNGeometry(sources: [source, uvSource, colorSource], elements: [element])
    }
}

// MARK: - Helper Math Functions
fileprivate func mixColor(_ a: simd_float4, _ b: simd_float4, factor: Float) -> simd_float4 {
    let f = max(0.0, min(1.0, factor))
    return a + (b - a) * f
}
