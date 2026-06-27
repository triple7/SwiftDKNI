//
//  Untitled.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 27/6/2026.
//

import CoreGraphics

#if os(macOS)
import AppKit
public typealias XImage = NSImage
public typealias XColor = NSColor
#else
import UIKit
public typealias XImage = UIImage
public typealias XColor = UIColor
#endif

func generateSunspotTexture(from regions: [SWPCRegion], textureSize: CGSize = CGSize(width: 2048, height: 1024)) -> XImage? {
    
    // 1. Setup the shared Core Graphics drawing logic in a closure
    let drawingBlock: (CGContext) -> Void = { cgContext in
        // Fill the background with pure white (transparent to the multiply blend)
        cgContext.setFillColor(XColor.white.cgColor)
        cgContext.fill(CGRect(origin: .zero, size: textureSize))
        
        // Loop through the active regions
        for region in regions {
            guard let lat = region.latitude,
                  let lon = region.longitude,
                  let area = region.area else { continue }
            
            // --- Equirectangular Projection Math ---
            let normalizedX = CGFloat(lon + 180) / 360.0
            let xPos = textureSize.width - (normalizedX * textureSize.width)
            
            let normalizedY = CGFloat(lat + 90) / 180.0
            let yPos = textureSize.height - (normalizedY * textureSize.height)
            
            let radius = CGFloat(area) * 0.05
            
            // Draw a soft radial gradient for the sunspot (dark core, fading edges)
            let colors = [XColor.black.cgColor, XColor.black.withAlphaComponent(0.0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) else { continue }
            
            let center = CGPoint(x: xPos, y: yPos)
            
            cgContext.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: radius * 0.2,
                endCenter: center, endRadius: radius,
                options: .drawsBeforeStartLocation
            )
        }
    }
    
    // 2. Branch context allocation and image creation based on the Target OS
    #if os(macOS)
    // macOS Implementation using NSImage and lockFocus
    let newImage = NSImage(size: textureSize)
    newImage.lockFocus()
    if let nsContext = NSGraphicsContext.current {
        drawingBlock(nsContext.cgContext)
    }
    newImage.unlockFocus()
    return newImage
    
    #else
    // iOS/watchOS/tvOS Implementation using UIGraphicsImageRenderer
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: textureSize, format: format)
    
    return renderer.image { context in
        drawingBlock(context.cgContext)
    }
    #endif
}
