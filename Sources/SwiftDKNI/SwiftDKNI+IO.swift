//
//  SwiftDKNI+IO.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 6/9/2026.
//

import Foundation
import SceneKit
import Metal
import simd
import Accelerate

extension SwiftDKNI {
    
    public func saveVoxelCubeToDisc(texture: MTLTexture, fileDir: String = "stars", fileName: String = "magnetic_volume_full.bin") -> URL? {
        let fileManager = FileManager.default
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let folderURL = documentsDir.appendingPathComponent("gaia", isDirectory: true)
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent(fileName)
        
        let width = texture.width
        let height = texture.height
        let depth = texture.depth
        
        // Calculate bytes per pixel based on pixel format (e.g., RGBA32Float = 16 bytes per pixel)
        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .rgba32Float: bytesPerPixel = 16
        case .rgba16Float: bytesPerPixel = 8
        case .rgba8Unorm:  bytesPerPixel = 4
        default:           bytesPerPixel = 16 // fallback assumption
        }
        
        let bytesPerRow = width * bytesPerPixel
        let imageSize = bytesPerRow * height
        let totalBytes = imageSize * depth
        
        var rawData = Data(count: totalBytes)
        
        rawData.withUnsafeMutableBytes { ptr in
            texture.getBytes(
                ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                bytesPerImage: imageSize,
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: depth)),
                mipmapLevel: 0,
                slice: 0
            )
        }
        
        do {
            try rawData.write(to: fileURL)
            print("✅ Successfully saved entire 3D voxel volume (\(width)x\(height)x\(depth)) to disk at: \(fileURL.path)")
            return fileURL
        } catch {
            print("❌ Failed to write full 3D texture binary: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func load3DVoxelFromDisc(device: MTLDevice, width: Int, height: Int, depth: Int, pixelFormat: MTLPixelFormat = .rgba32Float, fileName: String = "magnetic_volume_full.bin") -> MTLTexture? {
        let fileManager = FileManager.default
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let fileURL = documentsDir.appendingPathComponent("gaia", isDirectory: true).appendingPathComponent(fileName)
        
        guard fileManager.fileExists(atPath: fileURL.path),
              let rawData = try? Data(contentsOf: fileURL) else {
            print("❌ Failed to find or read 3D texture binary at: \(fileURL.path)")
            return nil
        }
        
        // 1. Create the 3D texture descriptor matching your saved dimensions and format
        let textureDesc = MTLTextureDescriptor()
        textureDesc.textureType = .type3D
        textureDesc.pixelFormat = pixelFormat
        textureDesc.width = width
        textureDesc.height = height
        textureDesc.depth = depth
        textureDesc.mipmapLevelCount = 1
        textureDesc.usage = [.shaderRead]
        
        guard let texture = device.makeTexture(descriptor: textureDesc) else {
            print("❌ Failed to create MTLTexture from descriptor.")
            return nil
        }
        
        // 2. Determine bytes per pixel and copy the raw bytes back into the texture
        let bytesPerPixel: Int
        switch pixelFormat {
        case .rgba32Float: bytesPerPixel = 16
        case .rgba16Float: bytesPerPixel = 8
        case .rgba8Unorm:  bytesPerPixel = 4
        default:           bytesPerPixel = 16
        }
        
        let bytesPerRow = width * bytesPerPixel
        let bytesPerImage = bytesPerRow * height
        
        rawData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: depth)),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }
        
        print("✅ Successfully loaded entire 3D voxel volume (\(width)x\(height)x\(depth)) from disk.")
        return texture
    }
    
}
