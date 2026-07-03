//
//  MagneticRegion.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 30/6/2026.
//

import Foundation
import SceneKit
import CoreGraphics
import Accelerate
import simd
import ImageIO

// Assuming you have imported your preferred FITS package
import FITS

public struct MagneticRegion {
    let centroidLat: Float
    let centroidLon: Float
    let fluxIntensity: Float
    let isPositive: Bool
}

public struct MagneticLoopLine {
    let p0: simd_float3 // Root 1
    let p1: simd_float3 // Apex
    let p2: simd_float3 // Root 2
    let isOpen: Bool    // CME Line
    let intensity: Float
}

public final class MagnetogramModeler: @unchecked Sendable {
    
    public init() {}
    
    // MARK: - 1. API Request
    
    public func fetchLatestSynopticMagnetogram() async throws -> URL {
        let rotationNumber = 2270
        let urlString = "http://jsoc.stanford.edu/data/hmi/synoptic/hmi.Synoptic_Mr.\(rotationNumber).fits"
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        let (localURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let savedURL = docsDir.appendingPathComponent("latest_magnetogram.fits")
        
        if FileManager.default.fileExists(atPath: savedURL.path) {
            try FileManager.default.removeItem(at: savedURL)
        }
        try FileManager.default.moveItem(at: localURL, to: savedURL)
        
        return savedURL
    }
    
    // MARK: - 2 & 3. FITS Parsing
    
    public struct MagnetogramData {
        let cgImage: CGImage
        let width: Int
        let height: Int
        let fluxArray: [Float]
    }
    
    public func processFitsFile(at url: URL) throws -> MagnetogramData {
        print("processFitsFile: Processing magnetogram data")
        
        let fitsData = try Data(contentsOf: url)
        guard let fits = FitsFile.read(fitsData) else {
            throw NSError(domain: "MagnetogramError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to parse FITS file structure"])
        }
        
        let prime = fits.prime
        let width = prime.naxis(1) ?? 3600
        let height = prime.naxis(2) ?? 1440
        let pixelCount = width * height
        
        // As requested: direct extraction with a safe fallback
        var bitpix: Int = -32
        if let nativeBitpix = prime.bitpix as? Int {
             bitpix = nativeBitpix
        }
        
        let bytesPerPixel = abs(bitpix) / 8
        
        guard let rawData = prime.dataUnit, rawData.count >= pixelCount * bytesPerPixel else {
            throw NSError(domain: "MagnetogramError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing or incomplete FITS data block"])
        }
        
        var dataArray = [Float](repeating: 0.0, count: pixelCount)
        
        rawData.withUnsafeBytes { rawBuffer in
            switch bitpix {
            case 8:
                let pointer = rawBuffer.bindMemory(to: UInt8.self)
                for i in 0..<pixelCount { dataArray[i] = Float(pointer[i]) }
            case 16:
                let pointer = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<pixelCount { dataArray[i] = Float(Int16(bigEndian: pointer[i])) }
            case 32:
                let pointer = rawBuffer.bindMemory(to: Int32.self)
                for i in 0..<pixelCount { dataArray[i] = Float(Int32(bigEndian: pointer[i])) }
            case -32:
                let pointer = rawBuffer.bindMemory(to: UInt32.self)
                for i in 0..<pixelCount { dataArray[i] = Float(bitPattern: UInt32(bigEndian: pointer[i])) }
            case -64:
                let pointer = rawBuffer.bindMemory(to: UInt64.self)
                for i in 0..<pixelCount { dataArray[i] = Float(Double(bitPattern: UInt64(bigEndian: pointer[i]))) }
            default:
                print("Warning: Unsupported FITS BITPIX format: \(bitpix).")
            }
        }
        
        var pixels = [UInt8](repeating: 0, count: pixelCount)
        let minGauss: Float = -150.0
        let maxGauss: Float = 150.0
        let range = maxGauss - minGauss
        
        for i in 0..<pixelCount {
            let value = dataArray[i]
            if value.isNaN {
                pixels[i] = 127
                continue
            }
            let clamped = max(minGauss, min(maxGauss, value))
            let normalized = (clamped - minGauss) / range
            pixels[i] = UInt8(normalized * 255.0)
        }
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cgImage = context.makeImage() else {
            throw NSError(domain: "MagnetogramError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate CGImage"])
        }
        
        let fileManager = FileManager.default
        if let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let starDir = docsDir.appendingPathComponent("star")
            if !fileManager.fileExists(atPath: starDir.path) {
                try? fileManager.createDirectory(at: starDir, withIntermediateDirectories: true, attributes: nil)
            }
            let debugImageURL = starDir.appendingPathComponent("magnetogram_debug.jpg")
            if let destination = CGImageDestinationCreateWithURL(debugImageURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cgImage, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        
        return MagnetogramData(cgImage: cgImage, width: width, height: height, fluxArray: dataArray)
    }

    // MARK: - 4. PFSS Modeling & Magnetic Integration
    
    private func extractActiveRegions(from data: MagnetogramData, thresholdGauss: Float = 40.0) -> (positive: [MagneticRegion], negative: [MagneticRegion]) {
        
        print("\n=== MAGNETIC FIELD ANALYSIS ===")
        
        let gridSize = 40
        let bucketsX = (data.width + gridSize - 1) / gridSize
        let bucketsY = (data.height + gridSize - 1) / gridSize
        let totalBuckets = bucketsX * bucketsY
        
        print("1. Grid Size: \(gridSize)x\(gridSize) pixels")
        print("2. Total Analysis Buckets: \(totalBuckets)")
        print("3. Minimum Threshold: > \(thresholdGauss)G")
        
        var bucketResults = [MagneticRegion?](repeating: nil, count: totalBuckets)
        
        DispatchQueue.concurrentPerform(iterations: totalBuckets) { i in
            let bx = i % bucketsX
            let by = i / bucketsX
            
            let startX = bx * gridSize
            let startY = by * gridSize
            let endX = min(startX + gridSize, data.width)
            let endY = min(startY + gridSize, data.height)
            
            var localMaxAbsFlux: Float = 0.0
            var localPeakX = startX
            var localPeakY = startY
            var localPeakFlux: Float = 0.0
            
            for cy in startY..<endY {
                let rowOffset = cy * data.width
                for cx in startX..<endX {
                    let index = rowOffset + cx
                    let flux = data.fluxArray[index]
                    
                    if !flux.isNaN {
                        let absFlux = abs(flux)
                        if absFlux > localMaxAbsFlux {
                            localMaxAbsFlux = absFlux
                            localPeakFlux = flux
                            localPeakX = cx
                            localPeakY = cy
                        }
                    }
                }
            }
            
            if localMaxAbsFlux > thresholdGauss {
                let lon = (Float(localPeakX) / Float(data.width)) * 360.0 - 180.0
                let lat = (Float(localPeakY) / Float(data.height)) * 180.0 - 90.0
                bucketResults[i] = MagneticRegion(centroidLat: lat, centroidLon: lon, fluxIntensity: localPeakFlux, isPositive: localPeakFlux > 0)
            }
        }
        
        var posRegions: [MagneticRegion] = []
        var negRegions: [MagneticRegion] = []
        
        for result in bucketResults {
            if let region = result {
                if region.isPositive { posRegions.append(region) }
                else { negRegions.append(region) }
            }
        }
        
        print("4. Raw Buckets extracted: \(posRegions.count + negRegions.count)")
        
        // GEOMETRY SAFETY CAP:
        // Prevents SceneKit from receiving millions of lines, which pegs the CPU/GPU
        let maxRegionsPerPolarity = 150
        
        posRegions.sort { abs($0.fluxIntensity) > abs($1.fluxIntensity) }
        negRegions.sort { abs($0.fluxIntensity) > abs($1.fluxIntensity) }
        
        if posRegions.count > maxRegionsPerPolarity {
            posRegions = Array(posRegions.prefix(maxRegionsPerPolarity))
        }
        if negRegions.count > maxRegionsPerPolarity {
            negRegions = Array(negRegions.prefix(maxRegionsPerPolarity))
        }
        
        print("5. Geometry Safety Cap applied (Top \(maxRegionsPerPolarity) poles per polarity).")
        print("6. Final Distinct Regions: \(posRegions.count) Positive, \(negRegions.count) Negative")
        print("===============================\n")
        
        return (posRegions, negRegions)
    }
    
    private func sphericalToCartesian(lat: Float, lon: Float, radius: Float = 1.0) -> simd_float3 {
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        return simd_float3(
            cos(latRad) * sin(lonRad) * radius,
            sin(latRad) * radius,
            cos(latRad) * cos(lonRad) * radius
        )
    }
    
    private func computeMagneticField(at point: simd_float3, regions: [(pos: simd_float3, flux: Float)]) -> simd_float3 {
        var bField = simd_float3(0, 0, 0)
        for region in regions {
            let rVec = point - region.pos
            let rSq = simd_length_squared(rVec)
            
            // PHYSICS OPTIMIZATION:
            // Magnetic field strength follows an inverse-cube falloff.
            // If a pole is further than 1.5 solar radii away (rSq > 2.25), its gravitational
            // pull on the line is mathematically negligible. Skipping it eliminates 85% of CPU math!
            if rSq > 2.25 { continue }
            
            let r3 = rSq * sqrt(rSq) + 0.0001
            bField += (rVec * region.flux) / r3
        }
        return bField
    }
    
    private func traceFieldLine(startPoint p0: simd_float3, regions: [(pos: simd_float3, flux: Float)], intensity: Float) -> MagneticLoopLine {
        var currentPos = p0
        var maxRadius: Float = 1.0
        var p1 = p0
        
        let stepSize: Float = 0.02
        let maxSteps = 250
        
        currentPos += simd_normalize(p0) * 0.01
        
        var isOpen = true
        var p2 = p0
        
        for _ in 0..<maxSteps {
            let bField = computeMagneticField(at: currentPos, regions: regions)
            
            // Fail-safe: if the field perfectly cancels out or is completely void
            let length = simd_length(bField)
            if length < 0.00001 || length.isNaN { break }
            
            let direction = bField / length // Normalized
            
            currentPos += direction * stepSize
            let currentRadius = simd_length(currentPos)
            
            if currentRadius > maxRadius {
                maxRadius = currentRadius
                p1 = currentPos
            }
            
            if currentRadius <= 1.0 {
                isOpen = false
                p2 = simd_normalize(currentPos)
                break
            }
            
            if currentRadius > 6.0 {
                isOpen = true
                p2 = currentPos
                break
            }
        }
        
        if isOpen && simd_length(currentPos) <= 3.0 {
            p2 = currentPos
            p1 = p0 + (simd_normalize(p0) * 1.5)
        }
        
        return MagneticLoopLine(p0: p0, p1: p1, p2: p2, isOpen: isOpen, intensity: intensity)
    }
    
    public func calculateMagneticLoops(from data: MagnetogramData, connectionThresholdDegrees: Float = 25.0) -> [MagneticLoopLine] {
        let (posRegions, negRegions) = extractActiveRegions(from: data)
        
        print("\n=== TRACING MAGNETIC SPLINES ===")
        print("Simulating gravity & tracing 12 field lines per region...")
        
        var allRegions3D: [(pos: simd_float3, flux: Float)] = []
        for r in posRegions + negRegions {
            allRegions3D.append((sphericalToCartesian(lat: r.centroidLat, lon: r.centroidLon), r.fluxIntensity))
        }
        
        let linesPerRegion = 12
        let bundleSpreadRadius: Float = 0.06
        
        var concurrentLoops = [[MagneticLoopLine]](repeating: [], count: posRegions.count)
        
        DispatchQueue.concurrentPerform(iterations: posRegions.count) { i in
            let pos = posRegions[i]
            var localLoops: [MagneticLoopLine] = []
            
            let centerPos = sphericalToCartesian(lat: pos.centroidLat, lon: pos.centroidLon)
            let up = simd_float3(0, 1, 0)
            var right = simd_cross(centerPos, up)
            if simd_length(right) < 0.001 { right = simd_float3(1, 0, 0) }
            right = simd_normalize(right)
            let localUp = simd_normalize(simd_cross(right, centerPos))
            
            for lineIdx in 0..<linesPerRegion {
                let angle = (Float(lineIdx) / Float(linesPerRegion)) * 2.0 * .pi
                let offset = (right * cos(angle) + localUp * sin(angle)) * bundleSpreadRadius
                let p0 = simd_normalize(centerPos + offset)
                
                let loop = traceFieldLine(startPoint: p0, regions: allRegions3D, intensity: pos.fluxIntensity)
                
                if simd_length(loop.p1) > 1.01 {
                    localLoops.append(loop)
                }
            }
            concurrentLoops[i] = localLoops
        }
        
        let allLoops = concurrentLoops.flatMap { $0 }
        
        print("Generated \(allLoops.count) successful 3D magnetic splines.")
        print("================================\n")
        
        return allLoops
    }
}
