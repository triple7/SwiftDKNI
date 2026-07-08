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

extension SwiftDKNI {
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
        startPoint: simd_float3,
        apexPoint: simd_float3,
        endPoint: simd_float3,
        isOpen: Bool,
        pfssVolume: [simd_float4],
        solarRadius: Float
    ) -> (simd_float3, simd_float3, simd_float3) {
        
        var newApex = apexPoint
        
        // 1. Sample the ambient magnetic field at the apex
        let ambientField = sampleMagneticVolume(
            at: apexPoint,
            pfssVolume: pfssVolume,
            solarRadius: solarRadius
        )
        
        let flowVector = simd_make_float3(ambientField.x, ambientField.y, ambientField.z)
        let influence = ambientField.w // 1.0 for magnetic capture, 0.1 for void/wind
        
        if isOpen {
            // OPEN SPLINES: The escape trajectory is dominated by the flow vector
            // Shift the apex aggressively along the PFSS current
            let escapePush = flowVector * (solarRadius * 0.5 * influence)
            newApex += escapePush
            
        } else {
            // CLOSED SPLINES: Flux rope braiding
            // The apex twists perpendicularly to the ambient field to simulate magnetic tension
            let splineDirection = normalize(endPoint - startPoint)
            
            // Cross product generates a perpendicular twisting force
            let twistAxis = simd_cross(splineDirection, flowVector)
            
            if simd_length(twistAxis) > 0.001 {
                let twistMagnitude = solarRadius * 0.15 * influence
                newApex += normalize(twistAxis) * twistMagnitude
            }
        }
        
        return (startPoint, newApex, endPoint)
    }
    
    public func generateMagneticVolumeTexture(
            device: MTLDevice,
            lines: [MagneticLoopLine],
            solarRadius: Float,
            resolution: Int = 64
        ) -> (volumeData: [simd_float4], texture: MTLTexture?) {
            
            // Fallback if threading the device is a pain
            
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
            
            // --- 2. INITIALIZE EMPTY GRID ---
            var volumeData = [simd_float4](repeating: simd_float4(0, 0, 0, 0), count: voxelCount)
            
            // --- 3. RASTERIZE WITH INVERSE-CUBE FALLOFF BRUSH ---
            let samplesPerLine = 100
            let brushRadius = 2
            let voxelPhysicalSize = (gridBounds * 2.0) / Float(resolution)
            
            var outOfBoundsCount = 0 // Debug tracker
            
            for line in lines {
                let lineBaseGauss: Float = 1.0
                
                for i in 0..<samplesPerLine {
                    let t = Float(i) / Float(samplesPerLine - 1)
                    let currentPos = line.position(at: t) * solarRadius
                    
                    // 🚨 ANTI-NAN SAFEGUARD 1: Prevent sampling the exact same point at the end of the line
                    var direction = simd_float3(0, 1.0, 0)
                    if t < 0.99 {
                        let nextPos = line.position(at: t + 0.01) * solarRadius
                        direction = simd_normalize(nextPos - currentPos)
                    } else {
                        // If we are at the very end of the line, look backward to maintain trajectory
                        let prevPos = line.position(at: t - 0.01) * solarRadius
                        direction = simd_normalize(currentPos - prevPos)
                    }
                    
                    let normXPos = (currentPos.x + gridBounds) / (gridBounds * 2.0)
                    let normYPos = (currentPos.y + gridBounds) / (gridBounds * 2.0)
                    let normZPos = (currentPos.z + gridBounds) / (gridBounds * 2.0)
                    
                    let exactGridX = normXPos * Float(resolution - 1)
                    let exactGridY = normYPos * Float(resolution - 1)
                    let exactGridZ = normZPos * Float(resolution - 1)
                    
                    let centerGridX = Int(exactGridX)
                    let centerGridY = Int(exactGridY)
                    let centerGridZ = Int(exactGridZ)
                    
                    for bZ in -brushRadius...brushRadius {
                        for bY in -brushRadius...brushRadius {
                            for bX in -brushRadius...brushRadius {
                                
                                let gX = centerGridX + bX
                                let gY = centerGridY + bY
                                let gZ = centerGridZ + bZ
                                
                                guard gX >= 0, gX < resolution,
                                      gY >= 0, gY < resolution,
                                      gZ >= 0, gZ < resolution else {
                                    outOfBoundsCount += 1
                                    continue
                                }
                                
                                let physicalDistX = (Float(gX) - exactGridX) * voxelPhysicalSize
                                let physicalDistY = (Float(gY) - exactGridY) * voxelPhysicalSize
                                let physicalDistZ = (Float(gZ) - exactGridZ) * voxelPhysicalSize
                                
                                let distSq = (physicalDistX * physicalDistX) +
                                (physicalDistY * physicalDistY) +
                                (physicalDistZ * physicalDistZ)
                                
                                let safeDistSq = max(distSq, 0.0001)
                                let physicalDistance = sqrt(safeDistSq)
                                let decay = 1.0 / (physicalDistance * physicalDistance * physicalDistance)
                                let influence = min(lineBaseGauss, lineBaseGauss * decay)
                                
                                guard influence > 0.05 else { continue }
                                
                                let index = (gZ * resolution * resolution) + (gY * resolution) + gX
                                let existing = volumeData[index]
                                
                                volumeData[index] = simd_float4(
                                    existing.x + (direction.x * influence),
                                    existing.y + (direction.y * influence),
                                    existing.z + (direction.z * influence),
                                    existing.w + influence
                                )
                            }
                        }
                    }
                }
            }
            
            // --- 4. RESOLVE COEFFICIENTS & DEBUG TELEMETRY ---
            var magneticVoxelCount = 0
            var emptyVoxelCount = 0
            var peakWeight: Float = 0.0
            
            volumeData.withUnsafeMutableBufferPointer { buffer in
                for i in 0..<voxelCount {
                    let data = buffer[i]
                    
                    if data.w > 0.0 {
                        magneticVoxelCount += 1
                        peakWeight = max(peakWeight, data.w)
                        
                        let sumVector = simd_float3(data.x, data.y, data.z)
                        
                        // 🚨 ANTI-NAN SAFEGUARD 2: Protect against perfectly canceled-out opposing forces
                        let averagedDir = simd_length(sumVector) > 0.0001 ? simd_normalize(sumVector) : simd_float3(0, 1.0, 0)
                        
                        buffer[i] = simd_float4(averagedDir.x, averagedDir.y, averagedDir.z, 1.0)
                    } else {
                        emptyVoxelCount += 1
                        let x = xs[i]
                        let y = ys[i]
                        let z = zs[i]
                        let outwardDir = simd_normalize(simd_float3(x, y, z))
                        buffer[i] = simd_float4(outwardDir.x, outwardDir.y, outwardDir.z, 0.1)
                    }
                }
            }
            
            // 🚨 FIRE THE DEBUGGER TO THE CONSOLE
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
        // (Moved outside the loop to prevent aggressive garbage collection thrashing)
        var dx = [Float](repeating: 0.0, count: voxelCount)
        var dy = [Float](repeating: 0.0, count: voxelCount)
        var dz = [Float](repeating: 0.0, count: voxelCount)
        var distSq = [Float](repeating: 0.0, count: voxelCount)
        var decay = [Float](repeating: 0.0, count: voxelCount)
        
        var tempSq = [Float](repeating: 0.0, count: voxelCount)
        let minSqArr = [Float](repeating: 0.01, count: voxelCount)
        
        var invR = [Float](repeating: 0.0, count: voxelCount)
        var invRSq = [Float](repeating: 0.0, count: voxelCount)
        
        // Master accumulators for the final accumulated force
        var masterX = [Float](repeating: 0.0, count: voxelCount)
        var masterY = [Float](repeating: 0.0, count: voxelCount)
        var masterZ = [Float](repeating: 0.0, count: voxelCount)
        
        // Core C-API length requirements
        let vCount = vDSP_Length(voxelCount)
        var count32 = Int32(voxelCount)
        
        // --- 3. THE MATRIX EXPANSION (PFSS Extrapolation) ---
        for bucket in buckets {
            var negBx = -(bucket.position.x * solarRadius)
            var negBy = -(bucket.position.y * solarRadius)
            var negBz = -(bucket.position.z * solarRadius)
            var gauss = bucket.gauss
            
            // Calculate Distance Vectors (C-API Vector-Scalar Add)
            vDSP_vsadd(xs, 1, &negBx, &dx, 1, vCount)
            vDSP_vsadd(ys, 1, &negBy, &dy, 1, vCount)
            vDSP_vsadd(zs, 1, &negBz, &dz, 1, vCount)
            
            // r^2 = dx^2 + dy^2 + dz^2
            vDSP.square(dx, result: &distSq)
            vDSP.square(dy, result: &tempSq)
            vDSP.add(distSq, tempSq, result: &distSq)
            vDSP.square(dz, result: &tempSq)
            vDSP.add(distSq, tempSq, result: &distSq)
            
            // Safety clamp to prevent division by zero near the exact pole centers
            vDSP.maximum(distSq, minSqArr, result: &distSq)
            
            // Inverse Cube Falloff (1.0 / (r^2 * sqrt(r^2)))
            // C-API Vector Math (100% Zero-Allocation)
            vvrsqrtf(&invR, distSq, &count32)       // 1 / r
            vvrecf(&invRSq, distSq, &count32)       // 1 / r^2
            vDSP.multiply(invR, invRSq, result: &decay) // 1 / r^3
            
            // Apply the Gauss magnitude: (Gauss / r^3)
            // C-API Vector-Scalar Multiply
            vDSP_vsmul(decay, 1, &gauss, &decay, 1, vCount)
            
            // Calculate final force vector and accumulate into the master array
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
                    // High magnetic influence overrides the void
                    let invMag = 1.0 / sqrt(magSq)
                    // W = 1.0 flags this voxel for complete magnetic capture in the shader
                    buffer[i] = simd_float4(mx * invMag, my * invMag, mz * invMag, 1.0)
                } else {
                    // The Void (Solar Wind Fallback)
                    let sx = xs[i], sy = ys[i], sz = zs[i]
                    let sMagSq = (sx*sx) + (sy*sy) + (sz*sz)
                    let invSMag = 1.0 / sqrt(max(sMagSq, 0.001))
                    // W = 0.1 flags this voxel as weak drifting wind
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
