//
//  Untitled.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 7/7/2026.
//

import Metal
import simd
import Accelerate

public func generateMagneticVolumeTexture(
    device: MTLDevice,
    lines: [MagneticLoopLine],
    solarRadius: Float,
    resolution: Int = 64
) -> MTLTexture? {
    
    let voxelCount = resolution * resolution * resolution
    let gridBounds: Float = solarRadius * 3.0
    
    // --- 1. ACCELERATE: GENERATE FLAT COORDINATE ARRAYS ---
    let start = -gridBounds
    let step = (2.0 * gridBounds) / Float(resolution - 1)
    
    // Generate the base 1D physical ramp
    let baseCoords = vDSP.ramp(withInitialValue: start, increment: step, count: resolution)
    
    // Scatter the 1D ramp into flat, contiguous 3D grids
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
    // Start completely empty so we can safely accumulate multiple intersecting fields
    var volumeData = [simd_float4](repeating: simd_float4(0, 0, 0, 0), count: voxelCount)
    
    // --- 3. RASTERIZE WITH INVERSE-CUBE FALLOFF BRUSH ---
    let samplesPerLine = 100
    let brushRadius = 2 // How many voxels outward the magnetic field bleeds
    let voxelPhysicalSize = (gridBounds * 2.0) / Float(resolution)
    
    for line in lines {
        // Base strength of the specific magnetic spline
        let lineBaseGauss: Float = 1.0
        
        for i in 0..<samplesPerLine {
            let t = Float(i) / Float(samplesPerLine - 1)
            let currentPos = line.position(at: t) * solarRadius
            
            let nextPos = line.position(at: min(1.0, t + 0.01)) * solarRadius
            let direction = simd_normalize(nextPos - currentPos)
            
            // Map physical world position to exact float grid coordinates
            let normXPos = (currentPos.x + gridBounds) / (gridBounds * 2.0)
            let normYPos = (currentPos.y + gridBounds) / (gridBounds * 2.0)
            let normZPos = (currentPos.z + gridBounds) / (gridBounds * 2.0)
            
            let exactGridX = normXPos * Float(resolution - 1)
            let exactGridY = normYPos * Float(resolution - 1)
            let exactGridZ = normZPos * Float(resolution - 1)
            
            let centerGridX = Int(exactGridX)
            let centerGridY = Int(exactGridY)
            let centerGridZ = Int(exactGridZ)
            
            // Paint a localized 3D sphere around the spline point
            for bZ in -brushRadius...brushRadius {
                for bY in -brushRadius...brushRadius {
                    for bX in -brushRadius...brushRadius {
                        
                        let gX = centerGridX + bX
                        let gY = centerGridY + bY
                        let gZ = centerGridZ + bZ
                        
                        // Boundary safety check
                        guard gX >= 0, gX < resolution,
                              gY >= 0, gY < resolution,
                              gZ >= 0, gZ < resolution else { continue }
                        
                        // Calculate physical distance from the spline center to this neighboring voxel
                        let physicalDistX = (Float(gX) - exactGridX) * voxelPhysicalSize
                        let physicalDistY = (Float(gY) - exactGridY) * voxelPhysicalSize
                        let physicalDistZ = (Float(gZ) - exactGridZ) * voxelPhysicalSize
                        
                        // Distance squared
                        let distSq = (physicalDistX * physicalDistX) +
                                     (physicalDistY * physicalDistY) +
                                     (physicalDistZ * physicalDistZ)
                        
                        // Avoid division by zero at the exact center
                        let safeDistSq = max(distSq, 0.0001)
                        let physicalDistance = sqrt(safeDistSq)
                        
                        // The Inverse-Cube Law Decay
                        let decay = 1.0 / (physicalDistance * physicalDistance * physicalDistance)
                        
                        // Cap the maximum influence
                        let influence = min(lineBaseGauss, lineBaseGauss * decay)
                        
                        // Ignore anything that decays below a meaningful threshold
                        guard influence > 0.05 else { continue }
                        
                        let index = (gZ * resolution * resolution) + (gY * resolution) + gX
                        
                        // Accumulate the vector, weighted by its decay influence
                        let existing = volumeData[index]
                        volumeData[index] = simd_float4(
                            existing.x + (direction.x * influence),
                            existing.y + (direction.y * influence),
                            existing.z + (direction.z * influence),
                            existing.w + influence // W accumulates the total weight
                        )
                    }
                }
            }
        }
    }
    
    // --- 4. RESOLVE COEFFICIENTS & APPLY SOLAR WIND ---
    // Fast contiguous memory loop to finalize the vectors
    volumeData.withUnsafeMutableBufferPointer { buffer in
        for i in 0..<voxelCount {
            let data = buffer[i]
            
            if data.w > 0.0 {
                // Magnetic Field Hit: Average the accumulated directions and re-normalize
                let averagedDir = simd_normalize(simd_float3(data.x, data.y, data.z) / data.w)
                
                // Set final vector, lock magnitude (W) to 1.0 for high magnetic capture
                buffer[i] = simd_float4(averagedDir.x, averagedDir.y, averagedDir.z, 1.0)
            } else {
                // The Void: Voxel is empty. Apply the baseline radial Solar Wind.
                let x = xs[i]
                let y = ys[i]
                let z = zs[i]
                
                let outwardDir = simd_normalize(simd_float3(x, y, z))
                
                // Set final vector, set magnitude (W) to 0.1 for weak solar wind push
                buffer[i] = simd_float4(outwardDir.x, outwardDir.y, outwardDir.z, 0.1)
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
        print("Failed to allocate 3D texture memory.")
        return nil
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
    
    return texture
}

// Simple saturate helper
private func saturate(_ value: Float) -> Float {
    return max(0.0, min(1.0, value))
}
