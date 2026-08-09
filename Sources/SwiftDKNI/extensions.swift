//
//  extensions.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 10/8/2026.
//

import SceneKit
import MetalKit

public enum TextureLoaderUtility {
    public static func loadTexture(from image: Any, device: MTLDevice) -> MTLTexture? {
        #if os(macOS)
        guard let nsImage = image as? NSImage,
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let uiImage = image as? UIImage,
              let cgImage = uiImage.cgImage else { return nil }
        #endif
        
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .generateMipmaps: true,
            .SRGB: false
        ]
        return try? loader.newTexture(cgImage: cgImage, options: options)
    }
}
