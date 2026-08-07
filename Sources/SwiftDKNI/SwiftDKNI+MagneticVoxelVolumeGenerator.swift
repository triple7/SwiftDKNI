//
//  Untitled.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 7/7/2026.
//

import Foundation
import SceneKit
import Metal
import simd
import Accelerate

struct BrushOffset {
    let dx: Int
    let dy: Int
    let dz: Int
    let weight: Float
}

extension SwiftDKNI {

    public func extractMacroRegionalFlows(from lines: [MagneticLoopLine]) -> [RegionalFlow] {
        var spatialBuckets: [String: (originSum: simd_float3, dirSum: simd_float3, totalIntensity: Float, count: Float)] = [:]
        
        for line in lines {
            let p0 = line.p0
            
            // Chunk the surface coordinates into large, distinct regions
            let bx = Int(floor(p0.x * 2.5))
            let by = Int(floor(p0.y * 2.5))
            let bz = Int(floor(p0.z * 2.5))
            let key = "\(bx)_\(by)_\(bz)"
            
            // The overarching direction of this specific loop
            let direction = simd_normalize(line.p4 - line.p0)
            let intensity = abs(line.intensity)
            
            if let existing = spatialBuckets[key] {
                spatialBuckets[key] = (
                    existing.originSum + p0,
                    existing.dirSum + (direction * intensity),
                    existing.totalIntensity + intensity,
                    existing.count + 1.0
                )
            } else {
                spatialBuckets[key] = (p0, direction * intensity, intensity, 1.0)
            }
        }
        
        var flows: [RegionalFlow] = []
        
        print("\n--- 🌍 GLOBAL TOPOLOGY EXTRACTION ---")
        for (key, data) in spatialBuckets {
            // Broadcast regions that have enough cumulative intensity to act as a macro-influencer
            if data.totalIntensity > 250.0 {
                let center = simd_normalize(data.originSum / data.count)
                let flowDir = simd_normalize(data.dirSum)
                flows.append(RegionalFlow(center: center, direction: flowDir, magnitude: data.totalIntensity))
                
                print("Sector [\(key)] | Loops: \(Int(data.count)) | Wind Mag: \(String(format: "%.1f", data.totalIntensity)) | Dir: [\(String(format: "%.2f", flowDir.x)), \(String(format: "%.2f", flowDir.y)), \(String(format: "%.2f", flowDir.z))]")
            }
        }
        print("Extracted \(flows.count) macro-regional flow vectors.")
        print("---------------------------------------\n")
        
        return flows
    }
    
    /// Helper to sample the CPU-side PFSS volume
    public func sampleMagneticVolume(
        at position: simd_float3,
        pfssVolume: [simd_float4],
        solarRadius: Float,
        resolution: Int = 64
    ) -> simd_float4 {
        let gridBounds = solarRadius * 3.0
        
        // Normalize position to 0.0 -> 1.0 UVW space using native min/max combinations
        let u = max(0.0, min(1.0, (position.x + gridBounds) / (gridBounds * 2.0)))
        let v = max(0.0, min(1.0, (position.y + gridBounds) / (gridBounds * 2.0)))
        let w = max(0.0, min(1.0, (position.z + gridBounds) / (gridBounds * 2.0)))
        
        // Map to grid coordinates
        let x = min(Int(u * Float(resolution)), resolution - 1)
        let y = min(Int(v * Float(resolution)), resolution - 1)
        let z = min(Int(w * Float(resolution)), resolution - 1)
        
        // Flat array index calculation
        let index = (z * resolution * resolution) + (y * resolution) + x
        
        return pfssVolume[index]
    }
    
    public func applySolarRotationShift(
        point: simd_float3,
        solarRadius: Float,
        rotationRate: Float = 0.05, // Adjust for visual intensity
        solarWindSpeed: Float = 1.0
    ) -> simd_float3 {
        
        let distance = simd_length(point)
        
        // If the point is inside or exactly on the surface, no spatial rotation is applied
        if distance <= solarRadius { return point }
        
        // Calculate the Parker Spiral rotation angle based on distance
        let timeOfFlight = (distance - solarRadius) / max(solarWindSpeed, 0.001)
        let theta = rotationRate * timeOfFlight
        
        // Construct a Y-axis rotation matrix
        let cosTheta = cos(theta)
        let sinTheta = sin(theta)
        
        let rotationMatrix = simd_float3x3(
            simd_float3(cosTheta,  0, sinTheta),
            simd_float3(0,         1, 0),
            simd_float3(-sinTheta, 0, cosTheta)
        )
        
        // Apply the rotation
        return rotationMatrix * point
    }
    
    public func applyMagneticInfluenceToSpline(
            p0: simd_float3,
            p1: simd_float3,
            p2: simd_float3,
            p3: simd_float3,
            p4: simd_float3,
            isOpen: Bool,
            pfssVolume: [simd_float4],
            regionalFlows: [RegionalFlow],
            solarRadius: Float
        ) -> (simd_float3, simd_float3, simd_float3, simd_float3, simd_float3) {
            
            // 1. 🧬 GENERATE STABLE CHIRALITY (Handedness) FOR THIS LOOP
            // We use the root position (p0) to deterministically decide if this loop twists left or right
            let hashDot = p0.x * 12.9898 + p0.y * 78.233 + p0.z * 37.719
            let hashSin = sin(hashDot) * 43758.5453
            let loopHash = hashSin - floor(hashSin)
            let chirality: Float = loopHash > 0.5 ? 1.0 : -1.0
            let loopNoise = (Float(loopHash) - 0.5) * 2.0 // Range -1.0 to 1.0
            
            // 2. ADD TORSION PHASE PARAMETER
            func applyInfluence(to point: simd_float3, localStart: simd_float3, localEnd: simd_float3, weight: Float, torsionPhase: Float) -> simd_float3 {
                let ambientField = sampleMagneticVolume(
                    at: point,
                    pfssVolume: pfssVolume,
                    solarRadius: solarRadius
                )
                
                var flowVector = simd_make_float3(ambientField.x, ambientField.y, ambientField.z)
                let rawInfluence = ambientField.w
                
                // --- 🌍 GLOBAL TOPOLOGY: Add the macro-winds from other regions ---
                var macroWind = simd_float3(0, 0, 0)
                for flow in regionalFlows {
                    let rVec = flow.center - point
                    let distSq = simd_length_squared(rVec)
                    
                    if distSq > 0.15 && distSq < 4.0 {
                        let falloff = 1.0 / (distSq * sqrt(distSq) + 0.001)
                        macroWind += flow.direction * (flow.magnitude * 0.0005 * falloff)
                    }
                }
                
                if simd_length(macroWind) > 0.001 {
                    flowVector = normalize(flowVector + macroWind)
                } else if simd_length(flowVector) > 0.001 {
                    flowVector = normalize(flowVector)
                } else {
                    flowVector = simd_float3(0, 1, 0)
                }
                
                let boostedInfluence = min(1.5, max(0.15, pow(rawInfluence, 0.4)))
                let surfaceNormal = normalize(point)
                
                if isOpen {
                    let heightFromCenter = simd_length(point)
                    let heightLeverage = max(1.0, heightFromCenter / solarRadius)
                    let escapePush = flowVector * (solarRadius * 0.6 * boostedInfluence * weight * heightLeverage)
                    return point + escapePush
                    
                } else {
                    // CLOSED SPLINES: Tangential Conformation + Radial Bulge + True Torsion
                    
                    let radialComponent = dot(flowVector, surfaceNormal)
                    let tangentialFlow = flowVector - (radialComponent * surfaceNormal)
                    
                    var sweepDirection = simd_float3(0, 1, 0)
                    if simd_length(tangentialFlow) > 0.001 {
                        sweepDirection = normalize(tangentialFlow)
                    } else {
                        sweepDirection = normalize(simd_cross(surfaceNormal, simd_float3(0, 1, 0)))
                    }
                    
                    // Add a fraction of loopNoise to the sweep so neighboring parallel loops fan out naturally
                    let fannedSweep = normalize(sweepDirection + (simd_float3(loopNoise) * 0.15))
                    let tangentialPush = fannedSweep * (solarRadius * 0.35 * boostedInfluence * weight)
                    
                    let activityThreshold: Float = 15.0
                    let radialBulgeFactor = max(0.0, rawInfluence - activityThreshold)
                    let clampedBulge = min(radialBulgeFactor * 0.015, 0.4)
                    
                    let outwardLift = max(0.0, radialComponent)
                    let radialPush = surfaceNormal * (outwardLift * clampedBulge * solarRadius * weight)
                    
                    let regionalPush = tangentialPush + radialPush
                    
                    // 🚨 TRUE 3D TORSION
                    let splineDirection = normalize(localEnd - localStart)
                    var twistAxis = simd_cross(splineDirection, flowVector)
                    
                    if simd_length(twistAxis) < 0.001 {
                        let chaoticNormal = normalize(surfaceNormal + simd_float3(loopNoise * 0.6))
                        twistAxis = simd_cross(splineDirection, chaoticNormal)
                    }
                    
                    var twistPush = simd_float3(0, 0, 0)
                    if simd_length(twistAxis) > 0.001 {
                        // Multiply by chirality (left/right twist) and the spatial torsion phase
                        // This forces p1 to bend sideways differently than p3, creating an S-curve
                        let twistMagnitude = solarRadius * 0.20 * boostedInfluence * weight
                        twistPush = normalize(twistAxis) * twistMagnitude * torsionPhase * chirality
                    }
                    
                    return point + regionalPush + twistPush
                }
            }
            
            // Ascending Point: Twists hard in the chiral direction (+1.0)
            let newP1 = applyInfluence(to: p1, localStart: p0, localEnd: p2, weight: 0.7, torsionPhase: 1.0)
            
            // Apex Point: Remains mostly central, with a tiny randomized wobble to break symmetry
            let newP2 = applyInfluence(to: p2, localStart: p0, localEnd: p4, weight: 1.0, torsionPhase: loopNoise * 0.3)
            
            // Descending Point: Twists hard in the opposite chiral direction (-1.0)
            let newP3 = applyInfluence(to: p3, localStart: p2, localEnd: p4, weight: 0.7, torsionPhase: -1.0)
            
            return (p0, newP1, newP2, newP3, p4)
        }
    
    public func generateMagneticVectorFieldFromVolumeData(
        volumeData: [simd_float4],
        solarRadius: Float,
        resolution: Int
    ) -> SCNNode {
        
        let gridBounds = solarRadius * 3.0
        let step = (2.0 * gridBounds) / Float(resolution - 1)
        
        var vertices: [SCNVector3] = []
        var colorFloats: [Float] = [] // Flat array for raw RGB memory
        var indices: [Int32] = []
        var vertexCount: Int32 = 0
        
        for z in 0..<resolution {
            for y in 0..<resolution {
                for x in 0..<resolution {
                    let index = (z * resolution * resolution) + (y * resolution) + x
                    let data = volumeData[index]
                    
                    // Empty voxels were set to 0.1, real data is higher
                    if data.w > 0.11 {
                        let posX = -gridBounds + Float(x) * step
                        let posY = -gridBounds + Float(y) * step
                        let posZ = -gridBounds + Float(z) * step
                        
                        let startPos = SCNVector3(posX, posY, posZ)
                        
                        // Map length to weight.
                        // Note: You may need to tweak the 0.5 multiplier depending on your peakWeight
                        let weightMultiplier: Float = 0.5
                        let lineLength = step * data.w * weightMultiplier
                        let endPos = SCNVector3(posX + data.x * lineLength,
                                                posY + data.y * lineLength,
                                                posZ + data.z * lineLength)
                        
                        vertices.append(startPos)
                        vertices.append(endPos)
                        
                        // 1. Find the outward direction from the origin (0,0,0) to this voxel
                        let voxelPos = simd_float3(posX, posY, posZ)
                        let outwardDir = simd_length(voxelPos) > 0.0001 ? simd_normalize(voxelPos) : simd_float3(0, 1, 0)
                        
                        // 2. The magnetic vector direction
                        let magDir = simd_float3(data.x, data.y, data.z)
                        
                        // 3. Dot product tells us alignment (-1.0 to 1.0)
                        let alignment = simd_dot(outwardDir, magDir)
                        
                        // 4. Map alignment to a 0.0 to 1.0 range
                        // 0.0 = pointing toward sun, 1.0 = pointing away from sun
                        let t = (alignment + 1.0) * 0.5
                        
                        // 5. Build the gradient
                        // When t=1 (away), color is Red (1, 0, 0)
                        // When t=0 (toward), color is White (1, 1, 1)
                        let r: Float = 1.0
                        let g: Float = 1.0 - t
                        let b: Float = 1.0 - t
                        
                        // Add the color twice (once for start vertex, once for end vertex)
                        colorFloats.append(contentsOf: [r, g, b, r, g, b])
                        // Connect start and end vertices
                        indices.append(vertexCount)
                        indices.append(vertexCount + 1)
                        vertexCount += 2
                    }
                }
            }
        }
        
        if !vertices.isEmpty {
            let vertexSource = SCNGeometrySource(vertices: vertices)
            
            // Build a high-performance color source from raw memory to avoid UIColor overhead
            let colorData = Data(bytes: colorFloats, count: colorFloats.count * MemoryLayout<Float>.stride)
            let colorSource = SCNGeometrySource(data: colorData,
                                                semantic: .color,
                                                vectorCount: colorFloats.count / 3,
                                                usesFloatComponents: true,
                                                componentsPerVector: 3,
                                                bytesPerComponent: MemoryLayout<Float>.stride,
                                                dataOffset: 0,
                                                dataStride: MemoryLayout<Float>.stride * 3)
            
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let vectorGeometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            
            let vectorMaterial = SCNMaterial()
            vectorMaterial.lightingModel = .constant // Skip lighting math
            // SceneKit needs a white diffuse base to multiply the vertex colors against
            vectorMaterial.blendMode = .alpha
            // 2. Prevent transparent lines from occluding (blocking) lines behind them
            vectorMaterial.writesToDepthBuffer = false
            
#if os(macOS)
            vectorMaterial.diffuse.contents = NSColor.white
#else
            vectorMaterial.diffuse.contents = UIColor.white
#endif
            vectorGeometry.materials = [vectorMaterial]
            
            let vectorNode = SCNNode(geometry: vectorGeometry)
            return vectorNode
        }
        return SCNNode()
    }

    public func generateMagneticVolumeTexture(
        device: MTLDevice,
        lines: [MagneticLoopLine],
        solarRadius: Float,
        resolution: Int = 64
    ) -> (volumeData: [simd_float4], texture: MTLTexture?) {
        
        let voxelCount = resolution * resolution * resolution
        let gridBounds: Float = solarRadius * 3.0
        print("generateMagneticVolumeTexture: Using \(lines.count) magnetic line influencors into \(voxelCount) voxels across \(gridBounds) radius.")
        
        let startVoxel = CACurrentMediaTime()
        
        // --- 1. ACCELERATE: GENERATE FLAT COORDINATE ARRAYS ---
        let start = -gridBounds
        let step = (2.0 * gridBounds) / Float(resolution - 1)
        let baseCoords = vDSP.ramp(withInitialValue: start, increment: step, count: resolution)
        
        var xs = [Float](unsafeUninitializedCapacity: voxelCount) { buffer, count in
            var index = 0
            for _ in 0..<resolution {
                for _ in 0..<resolution {
                    for x in 0..<resolution {
                        buffer[index] = baseCoords[x]
                        index += 1
                    }
                }
            }
            count = voxelCount
        }
        
        var ys = [Float](unsafeUninitializedCapacity: voxelCount) { buffer, count in
            var index = 0
            for _ in 0..<resolution {
                for y in 0..<resolution {
                    let yVal = baseCoords[y]
                    for _ in 0..<resolution {
                        buffer[index] = yVal
                        index += 1
                    }
                }
            }
            count = voxelCount
        }
        
        var zs = [Float](unsafeUninitializedCapacity: voxelCount) { buffer, count in
            var index = 0
            for z in 0..<resolution {
                let zVal = baseCoords[z]
                for _ in 0..<resolution {
                    for _ in 0..<resolution {
                        buffer[index] = zVal
                        index += 1
                    }
                }
            }
            count = voxelCount
        }
        
        // --- 2. PRECOMPUTE THE SIMD VOLUMETRIC BRUSH KERNEL ---
        let brushRadius = 3
        let maxDistance = Float(brushRadius) + 1.0
        var brushKernel: [BrushOffset] = []
        
        for dx in -brushRadius...brushRadius {
            for dy in -brushRadius...brushRadius {
                for dz in -brushRadius...brushRadius {
                    let dist = sqrt(Float(dx*dx + dy*dy + dz*dz))
                    let falloff = max(0.0, 1.0 - (dist / maxDistance))
                    
                    if falloff > 0.0 { // Optimization threshold
                        brushKernel.append(BrushOffset(dx: dx, dy: dy, dz: dz, weight: falloff))
                    }
                }
            }
        }
        
        // --- 3. RASTERIZE WITH UNROLLED MEMORY POINTERS ---
        var volumeData = [simd_float4](repeating: simd_float4(0, 0, 0, 0), count: voxelCount)
        let samplesPerLine = 200
        var outOfBoundsCount = 0
        
        volumeData.withUnsafeMutableBufferPointer { buffer in
            let resSq = resolution * resolution
            
            for line in lines {
                // if !line.isOpen {continue}  // uncomment to only look at the open lines.
                for i in 0..<samplesPerLine {
                    let t = Float(i) / Float(samplesPerLine - 1)
                    let currentPos = line.position(at: t) * solarRadius
                    
                    // 🚨 ANTI-NAN SAFEGUARD 1
                    var direction = simd_float3(0, 1.0, 0)
                    if t < 0.99 {
                        let nextPos = line.position(at: t + 0.01) * solarRadius
                        direction = simd_normalize(nextPos - currentPos)
                    } else {
                        let prevPos = line.position(at: t - 0.01) * solarRadius
                        direction = simd_normalize(currentPos - prevPos)
                    }
                    
                    let normXPos = (currentPos.x + gridBounds) / (gridBounds * 2.0)
                    let normYPos = (currentPos.y + gridBounds) / (gridBounds * 2.0)
                    let normZPos = (currentPos.z + gridBounds) / (gridBounds * 2.0)
                    
                    let centerGridX = Int(normXPos * Float(resolution - 1))
                    let centerGridY = Int(normYPos * Float(resolution - 1))
                    let centerGridZ = Int(normZPos * Float(resolution - 1))
                    
                    let baseVector = simd_float4(direction.x, direction.y, direction.z, 1.0)
                    
                    // SIMD Kernel Splatting
                    for offset in brushKernel {
                        let gX = centerGridX + offset.dx
                        let gY = centerGridY + offset.dy
                        let gZ = centerGridZ + offset.dz
                        
                        if gX >= 0 && gX < resolution &&
                           gY >= 0 && gY < resolution &&
                           gZ >= 0 && gZ < resolution {
                            
                            let index = (gZ * resSq) + (gY * resolution) + gX
                            buffer[index] += baseVector * offset.weight
                            
                        } else {
                            outOfBoundsCount += 1
                        }
                    }
                }
            }
        }
        
        // --- 4. RESOLVE COEFFICIENTS & DEBUG TELEMETRY ---
        var magneticVoxelCount = 0
        var emptyVoxelCount = 0
        var sunVoxelCount = 0 // Optional: track how many voxels are inside the sun
        var peakWeight: Float = 0.0
        
        volumeData.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<voxelCount {
                // Get the physical position of the current voxel
                let voxelPos = simd_float3(xs[i], ys[i], zs[i])
                let distFromCenter = simd_length(voxelPos)
                
                // 1. CHECK IF INSIDE THE SUN
                if distFromCenter <= solarRadius {
                    sunVoxelCount += 1
                    
                    // 🚨 ANTI-NAN SAFEGUARD (Handles the exact 0,0,0 center)
                    let outwardDir = distFromCenter > 0.0001 ? simd_normalize(voxelPos) : simd_float3(0, 1.0, 0)
                    
                    // Override with uniform outward vector, weight 1.0
                    buffer[i] = simd_float4(outwardDir.x, outwardDir.y, outwardDir.z, 1.0)
                    
                } else {
                    // 2. OUTSIDE THE SUN: USE RASTERIZED FIELD LINES
                    let data = buffer[i]
                    
                    if data.w > 0.0 {
                        magneticVoxelCount += 1
                        peakWeight = max(peakWeight, data.w)
                        
                        let sumVector = simd_float3(data.x, data.y, data.z)
                        
                        // 🚨 ANTI-NAN SAFEGUARD 2
                        let averagedDir = simd_length(sumVector) > 0.0001 ? simd_normalize(sumVector) : simd_float3(0, 1.0, 0)
                        buffer[i] = simd_float4(averagedDir.x, averagedDir.y, averagedDir.z, 1.0)
                        
                    } else {
                        // 3. EMPTY VOXELS (No field lines touched here)
                        emptyVoxelCount += 1
                        let outwardDir = distFromCenter > 0.0001 ? simd_normalize(voxelPos) : simd_float3(0, 1.0, 0)
                        buffer[i] = simd_float4(outwardDir.x, outwardDir.y, outwardDir.z, 0.1)
                    }
                }
            }
        }
        print("==================================================")
        print("🧲 VOXEL GENERATION TELEMETRY")
        print("==================================================")
        print("Total Splines Processed  : \(lines.count)")
        print("Total Grid Voxels        : \(voxelCount)")
        print("Magnetic Voxels (Hits)   : \(magneticVoxelCount) (\(String(format: "%.1f", (Float(magneticVoxelCount)/Float(voxelCount))*100))%)")
        print("Empty Voxels (Solar Wind): \(emptyVoxelCount)")
        print("Peak Accumulated Weight  : \(peakWeight)")
        print("Brush Out Of Bounds      : \(outOfBoundsCount)")
        print("==================================================")
        
        // --- 5. BUILD METAL TEXTURE ---
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = resolution
        descriptor.height = resolution
        descriptor.depth = resolution
        descriptor.usage = [.shaderRead]
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("DEBUG: ❌ Failed to allocate 3D texture memory on GPU.")
            return (volumeData, nil)
        }
        
        let bytesPerPixel = MemoryLayout<simd_float4>.stride
        let bytesPerRow = bytesPerPixel * resolution
        let bytesPerImage = bytesPerRow * resolution
        
        let region = MTLRegionMake3D(0, 0, 0, resolution, resolution, resolution)
        texture.replace(region: region,
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: volumeData,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerImage)
        
        let end = CACurrentMediaTime()
        print("DEBUG: ✅ 3D Texture Successfully Generated and Bound to GPU in \(end - startVoxel) seconds.")
        return (volumeData, texture)
    }

    public func generateVolumetricFieldFromBuckets(
        device: MTLDevice,
        buckets: [MagneticBucket],
        solarRadius: Float,
        resolution: Int = 64
    ) -> (volumeData: [simd_float4], texture: MTLTexture?) {
        
        let voxelCount = resolution * resolution * resolution
        let gridBounds: Float = solarRadius * 3.0
        print("generateVolumetricFieldFromBuckets: creating \(voxelCount) voxel cube with radius \(gridBounds).")
        let startVolume = CACurrentMediaTime()
        
        // --- 1. ACCELERATE: FLAT COORDINATE ARRAYS ---
        let start = -gridBounds
        let step = (2.0 * gridBounds) / Float(resolution - 1)
        let baseCoords = vDSP.ramp(withInitialValue: start, increment: step, count: resolution)
        
        var xs = [Float](unsafeUninitializedCapacity: voxelCount) { buffer, count in
            var index = 0
            for _ in 0..<resolution {
                for _ in 0..<resolution {
                    for x in 0..<resolution {
                        buffer[index] = baseCoords[x]
                        index += 1
                    }
                }
            }
            count = voxelCount
        }
        
        var ys = [Float](unsafeUninitializedCapacity: voxelCount) { buffer, count in
            var index = 0
            for _ in 0..<resolution {
                for y in 0..<resolution {
                    let yVal = baseCoords[y]
                    for _ in 0..<resolution {
                        buffer[index] = yVal
                        index += 1
                    }
                }
            }
            count = voxelCount
        }
        
        var zs = [Float](unsafeUninitializedCapacity: voxelCount) { buffer, count in
            var index = 0
            for z in 0..<resolution {
                let zVal = baseCoords[z]
                for _ in 0..<resolution {
                    for _ in 0..<resolution {
                        buffer[index] = zVal
                        index += 1
                    }
                }
            }
            count = voxelCount
        }
        
        // --- 2. PRE-ALLOCATE REUSABLE ACCELERATE BUFFERS ---
        var dx = [Float](repeating: 0.0, count: voxelCount)
        var dy = [Float](repeating: 0.0, count: voxelCount)
        var dz = [Float](repeating: 0.0, count: voxelCount)
        var distSq = [Float](repeating: 0.0, count: voxelCount)
        var decay = [Float](repeating: 0.0, count: voxelCount)
        
        var tempSq = [Float](repeating: 0.0, count: voxelCount)
        let minSqArr = [Float](repeating: 0.01, count: voxelCount)
        
        var invR = [Float](repeating: 0.0, count: voxelCount)
        var invRSq = [Float](repeating: 0.0, count: voxelCount)
        
        var masterX = [Float](repeating: 0.0, count: voxelCount)
        var masterY = [Float](repeating: 0.0, count: voxelCount)
        var masterZ = [Float](repeating: 0.0, count: voxelCount)
        
        let vCount = vDSP_Length(voxelCount)
        var count32 = Int32(voxelCount)
        
        // --- 3. THE MATRIX EXPANSION (PFSS Extrapolation) ---
        for bucket in buckets {
            var negBx = -(bucket.position.x * solarRadius)
            var negBy = -(bucket.position.y * solarRadius)
            var negBz = -(bucket.position.z * solarRadius)
            var gauss = bucket.gauss
            
            vDSP_vsadd(xs, 1, &negBx, &dx, 1, vCount)
            vDSP_vsadd(ys, 1, &negBy, &dy, 1, vCount)
            vDSP_vsadd(zs, 1, &negBz, &dz, 1, vCount)
            
            vDSP.square(dx, result: &distSq)
            vDSP.square(dy, result: &tempSq)
            vDSP.add(distSq, tempSq, result: &distSq)
            vDSP.square(dz, result: &tempSq)
            vDSP.add(distSq, tempSq, result: &distSq)
            
            vDSP.maximum(distSq, minSqArr, result: &distSq)
            
            vvrsqrtf(&invR, distSq, &count32)
            vvrecf(&invRSq, distSq, &count32)
            vDSP.multiply(invR, invRSq, result: &decay)
            
            vDSP_vsmul(decay, 1, &gauss, &decay, 1, vCount)
            
            vDSP.multiply(dx, decay, result: &tempSq)
            vDSP.add(masterX, tempSq, result: &masterX)
            
            vDSP.multiply(dy, decay, result: &tempSq)
            vDSP.add(masterY, tempSq, result: &masterY)
            
            vDSP.multiply(dz, decay, result: &tempSq)
            vDSP.add(masterZ, tempSq, result: &masterZ)
        }
        
        // --- 4. NORMALIZE & APPLY SOLAR WIND BACKGROUND ---
        var finalData = [simd_float4](repeating: simd_float4(0,0,0,0), count: voxelCount)
        
        finalData.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<voxelCount {
                let mx = masterX[i], my = masterY[i], mz = masterZ[i]
                let magSq = (mx*mx) + (my*my) + (mz*mz)
                
                if magSq > 0.001 {
                    let invMag = 1.0 / sqrt(magSq)
                    buffer[i] = simd_float4(mx * invMag, my * invMag, mz * invMag, 1.0)
                } else {
                    let sx = xs[i], sy = ys[i], sz = zs[i]
                    let sMagSq = (sx*sx) + (sy*sy) + (sz*sz)
                    let invSMag = 1.0 / sqrt(max(sMagSq, 0.001))
                    buffer[i] = simd_float4(sx * invSMag, sy * invSMag, sz * invSMag, 0.1)
                }
            }
        }
        
        // --- 5. BUILD METAL TEXTURE ---
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = resolution
        descriptor.height = resolution
        descriptor.depth = resolution
        descriptor.usage = [.shaderRead]
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("Failed to allocate 3D PFSS texture memory on GPU.")
            return (finalData, nil)
        }
        
        let bytesPerRow = MemoryLayout<simd_float4>.stride * resolution
        let bytesPerImage = bytesPerRow * resolution
        
        texture.replace(region: MTLRegionMake3D(0, 0, 0, resolution, resolution, resolution),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: finalData,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerImage)
        
        let end = CACurrentMediaTime()
        print("generateVolumetricFieldFromBuckets: 3D boxel texture generated in \(end - startVolume) seconds.")
        return (finalData, texture)
    }
}
