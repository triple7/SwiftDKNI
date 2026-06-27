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
    
    // MARK: - 3. The Flux Rope Mathematics
    
    /// A single Bezier curve representing a stretched magnetic field line
    private struct MagneticFieldLine {
        let p0: SCNVector3 // Root 1
        let p1: SCNVector3 // Apex (Stretched by solar wind/ejection)
        let p2: SCNVector3 // Root 2
        
        // Evaluates position along the curve (t = 0.0 to 1.0)
        func position(at t: Float) -> SCNVector3 {
            let u = 1.0 - t
            let tt = t * t
            let uu = u * u
            
            let term1 = p0 * uu
            let term2 = p1 * (2.0 * u * t)
            let term3 = p2 * tt
            
            return term1 + term2 + term3
        }
        
        // Evaluates the forward direction (tangent) along the curve
        func tangent(at t: Float) -> SCNVector3 {
            let u = 1.0 - t
            let dP1 = (p1 - p0) * (2.0 * u)
            let dP2 = (p2 - p1) * (2.0 * t)
            return (dP1 + dP2).normalized()
        }
    }
    
    /// Generates the mathematical skeleton for both the loops and the particles to share
    private func generateFluxRopeSkeleton(lat: Float, lon: Float, radius: Float, speed: Float, halfAngle: Float, lineCount: Int) -> [MagneticFieldLine] {
        var lines: [MagneticFieldLine] = []
        
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        
        // Center point of the eruption on the surface
        let centerDir = SCNVector3(
            cos(latRad) * sin(lonRad),
            sin(latRad),
            cos(latRad) * cos(lonRad)
        )
        
        // Establish a local coordinate system to spread the roots
        let up = SCNVector3(0, 1, 0)
        var right = centerDir.cross(up)
        if right.length() < 0.001 { right = SCNVector3(1, 0, 0) }
        right = right.normalized()
        let localUp = right.cross(centerDir).normalized()
        
        // The force of the CME stretches the loops massively outward
        let heightMultiplier = 1.2 + (speed / 1000.0) // Faster CMEs stretch loops higher
        let spreadRad = (halfAngle > 0 ? halfAngle : 20.0) * .pi / 180.0
        
        for _ in 0..<lineCount {
            // Randomize root spread on the surface
            let r1 = Float.random(in: -1.0...1.0) * spreadRad
            let r2 = Float.random(in: -1.0...1.0) * spreadRad
            let rootOffset1 = (right * r1) + (localUp * r2)
            let rootOffset2 = (right * -r1) + (localUp * -r2) // Opposite side of the active region
            
            let p0 = (centerDir + rootOffset1).normalized() * radius
            let p2 = (centerDir + rootOffset2).normalized() * radius
            
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
        
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        var texcoords: [CGPoint] = [] // u = t, v = phase
        
        var currentIndex: Int32 = 0
        
        for line in skeleton {
            let phase = Float.random(in: 0.0...1.0)
            
            for i in 0...pointsPerLoop {
                let t = Float(i) / Float(pointsPerLoop)
                vertices.append(line.position(at: t))
                texcoords.append(CGPoint(x: CGFloat(t), y: CGFloat(phase)))
                
                if i > 0 {
                    indices.append(currentIndex - 1)
                    indices.append(currentIndex)
                }
                currentIndex += 1
            }
        }
        
        let source = SCNGeometrySource(vertices: vertices)
        let uvSource = SCNGeometrySource(textureCoordinates: texcoords)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        
        return SCNGeometry(sources: [source, uvSource], elements: [element])
    }
    
    /// Builds the helical CME point cloud spiraling around the magnetic lines.
    /// Retains the original function name so renderer calls don't break.
    public func buildBoundaryShellAccelerated(for event: AveragedCMEData, pointCount: Int = 10000, solarRadius: Float = 1.0) -> SCNGeometry {
        let lat = Float(event.latitude ?? 0.0)
        let rotatedLon = calculateRotatedLongitude(originalLongitude: Float(event.longitude ?? 0.0), eventDate: event.parsedDate)
        
        let speed = Float(event.speed)
        let halfAngle = Float(event.halfAngle)
        
        // We use fewer skeleton lines for the particles to form distinct "strands" in the tornado
        let skeleton = generateFluxRopeSkeleton(lat: lat, lon: rotatedLon, radius: solarRadius, speed: speed, halfAngle: halfAngle, lineCount: 8)
        
        var vertices: [SCNVector3] = []
        var texcoords: [CGPoint] = [] // u = progression (t), v = random phase
        var colors: [SCNVector4] = [] // Velocity color gradient
        
        for _ in 0..<pointCount {
            // Pick a random magnetic field line from the skeleton
            let line = skeleton.randomElement()!
            
            // Pick a random progression along the line (weighted towards the top)
            let t = pow(Float.random(in: 0.1...1.0), 0.7)
            
            let centerPos = line.position(at: t)
            let tangent = line.tangent(at: t)
            
            // Create a Frenet frame (perpendicular axes) around the tangent to create the twist
            let arbitrary = SCNVector3(0, 1, 0)
            var binormal = tangent.cross(arbitrary)
            if binormal.length() < 0.001 { binormal = tangent.cross(SCNVector3(1, 0, 0)) }
            binormal = binormal.normalized()
            let normal = tangent.cross(binormal).normalized()
            
            // THE HELIX MATH: Twist the particle around the line based on how far out it is (t)
            // It completes ~3 full rotations (3 * 2pi) as it travels outward
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
            texcoords.append(CGPoint(x: CGFloat(t), y: CGFloat(Float.random(in: 0.0...1.0))))
            
            // Assign static velocity color based on 't'
            let coreColor = SCNVector4(1.0, 1.0, 1.0, 1.0) // White Hot
            let midColor = SCNVector4(1.0, 0.8, 0.2, 1.0)  // Yellow/Orange
            let edgeColor = SCNVector4(0.8, 0.1, 0.0, 1.0) // Deep Red
            
            let color: SCNVector4
            if t < 0.3 {
                color = mix(coreColor, midColor, factor: t / 0.3)
            } else {
                color = mix(midColor, edgeColor, factor: (t - 0.3) / 0.7)
            }
            colors.append(color)
        }
        
        let source = SCNGeometrySource(vertices: vertices)
        let uvSource = SCNGeometrySource(textureCoordinates: texcoords)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector4>.size)
        let colorSource = SCNGeometrySource(data: colorData,
                                            semantic: .color,
                                            vectorCount: colors.count,
                                            usesFloatComponents: true,
                                            componentsPerVector: 4,
                                            bytesPerComponent: MemoryLayout<Float>.size,
                                            dataOffset: 0,
                                            dataStride: MemoryLayout<SCNVector4>.size)
        
        let element = SCNGeometryElement(indices: Array(0..<Int32(pointCount)), primitiveType: .point)
        element.pointSize = 3.0 // Ensures points are large enough to show the soft alpha mask
        
        return SCNGeometry(sources: [source, uvSource, colorSource], elements: [element])
    }
}

// MARK: - Helper Math Functions

fileprivate func mix(_ a: SCNVector4, _ b: SCNVector4, factor: Float) -> SCNVector4 {
    let f = max(0.0, min(1.0, factor))
    return SCNVector4(
        a.x + (b.x - a.x) * f,
        a.y + (b.y - a.y) * f,
        a.z + (b.z - a.z) * f,
        a.w + (b.w - a.w) * f
    )
}

// MARK: - SCNVector3 Math Extensions

fileprivate extension SCNVector3 {
    static func +(l: SCNVector3, r: SCNVector3) -> SCNVector3 { return SCNVector3(l.x+r.x, l.y+r.y, l.z+r.z) }
    static func -(l: SCNVector3, r: SCNVector3) -> SCNVector3 { return SCNVector3(l.x-r.x, l.y-r.y, l.z-r.z) }
    static func *(vector: SCNVector3, scalar: Float) -> SCNVector3 { return SCNVector3(vector.x * scalar, vector.y * scalar, vector.z * scalar) }
    static func /(vector: SCNVector3, scalar: Float) -> SCNVector3 { return SCNVector3(vector.x / scalar, vector.y / scalar, vector.z / scalar) }
    
    func length() -> Float {
        return sqrt(x*x + y*y + z*z)
    }
    
    func normalized() -> SCNVector3 {
        let len = length()
        return len > 0.0001 ? self / len : SCNVector3(0, 0, 0)
    }
    
    func cross(_ vector: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            y * vector.z - z * vector.y,
            z * vector.x - x * vector.z,
            x * vector.y - y * vector.x
        )
    }
}

