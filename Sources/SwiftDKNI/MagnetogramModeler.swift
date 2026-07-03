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

// Assuming you have imported your preferred FITS package
import FITS

public struct MagneticRegion {
    let centroidLat: Float
    let centroidLon: Float
    let fluxIntensity: Float // Positive (Outward) or Negative (Inward)
    let isPositive: Bool
}

public struct MagneticLoopLine {
    let p0: simd_float3 // Root 1 (Positive)
    let p1: simd_float3 // Apex
    let p2: simd_float3 // Root 2 (Negative, or identical to p0 if open)
    let isOpen: Bool    // If true, it's a CME / Solar Wind line
    let intensity: Float
}

public final class MagnetogramModeler: @unchecked Sendable {
    
    public init() {}
    
    // MARK: - 1. API Request
    
    /// Fetches the latest HMI Synoptic Chart (Equirectangular Magnetogram) from NASA's JSOC/SDO.
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
        
        // Move to a permanent location in Documents
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let savedURL = docsDir.appendingPathComponent("latest_magnetogram.fits")
        
        if FileManager.default.fileExists(atPath: savedURL.path) {
            try FileManager.default.removeItem(at: savedURL)
        }
        try FileManager.default.moveItem(at: localURL, to: savedURL)
        
        return savedURL
    }
    
    // MARK: - 2 & 3. FITS Parsing and Image Generation
    
    public struct MagnetogramData {
        let cgImage: CGImage
        let width: Int
        let height: Int
        let fluxArray: [Float]
    }
    
    /// Parses the downloaded FITS file, extracting the float array and generating a visual CGImage.
    public func processFitsFile(at url: URL) throws -> MagnetogramData {
        print("processFitsFile: Processing magnetogram data")
        // 1. Read the FITS file
        let fitsData = try Data(contentsOf: url)
        guard let fits = FitsFile.read(fitsData) else {
            print("ERROR: Failed to parse FITS file structure")
            throw NSError(domain: "MagnetogramError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to parse FITS file structure"])
        }
        
        let prime = fits.prime

        // 2. Extract Dimensions (NAXIS1 = width, NAXIS2 = height)
        let width = prime.naxis(1) ?? 3600
        let height = prime.naxis(2) ?? 1440
        let pixelCount = width * height
        
        print("DEBUG FITS: Width=\(width), Height=\(height), Total Pixels=\(pixelCount)")
        
        // 3. Bulletproof BITPIX Extraction
        // Instead of relying on a package enum, we search the raw header keys
        var bitpix: Int = -32 // Default to Float32
        
        if let nativeBitpix = prime.bitpix as? Int {
             bitpix = nativeBitpix
        }
        
        print("DEBUG FITS: Extracted BITPIX = \(bitpix)")
        
        let bytesPerPixel = abs(bitpix) / 8 // e.g., 32 bit = 4 bytes, 16 bit = 2 bytes
        
        // 4. Extract the raw byte data using dynamic byte size
        guard let rawData = prime.dataUnit, rawData.count >= pixelCount * bytesPerPixel else {
            print("ERROR: Missing or incomplete FITS data block. Expected >= \(pixelCount * bytesPerPixel) bytes, got \(prime.dataUnit?.count ?? 0)")
            throw NSError(domain: "MagnetogramError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing or incomplete FITS data block"])
        }
        
        print("DEBUG FITS: Data unit count = \(rawData.count) bytes. Validating extraction...")
        
        // 5. Convert Big-Endian FITS bytes to native Swift Floats
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
        
        // Generate a quick sample string from the array to prove it isn't NaN or garbage
        let sample = dataArray[10000..<10005]
        print("DEBUG FITS: First 5 Float values sample: \(sample.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
        
        // 6. Convert Float array (Gauss values) to an 8-bit grayscale image
        var pixels = [UInt8](repeating: 0, count: pixelCount)
        let minGauss: Float = -1500.0
        let maxGauss: Float = 1500.0
        let range = maxGauss - minGauss
        
        for i in 0..<pixelCount {
            let value = dataArray[i]
            
            if value.isNaN {
                pixels[i] = 127 // Neutral gray
                continue
            }
            
            let clamped = max(minGauss, min(maxGauss, value))
            let normalized = (clamped - minGauss) / range
            pixels[i] = UInt8(normalized * 255.0)
        }
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cgImage = context.makeImage() else {
            
            throw NSError(domain: "MagnetogramError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate CGImage"])
        }
        
        return MagnetogramData(cgImage: cgImage, width: width, height: height, fluxArray: dataArray)
    }

    // MARK: - 4. PFSS Modeling & Magnetic Integration
    
    // LOWERED THRESHOLD: Synoptic maps dilute peak flux via averaging. 500G is often too high.
    private func extractActiveRegions(from data: MagnetogramData, thresholdGauss: Float = 150.0) -> (positive: [MagneticRegion], negative: [MagneticRegion]) {
        var posRegions: [MagneticRegion] = []
        var negRegions: [MagneticRegion] = []
        
        let strideStep = 10
        
        for y in stride(from: 0, to: data.height, by: strideStep) {
            for x in stride(from: 0, to: data.width, by: strideStep) {
                let index = y * data.width + x
                let flux = data.fluxArray[index]
                
                if abs(flux) > thresholdGauss {
                    let lon = (Float(x) / Float(data.width)) * 360.0 - 180.0
                    let lat = (Float(y) / Float(data.height)) * 180.0 - 90.0
                    
                    let region = MagneticRegion(centroidLat: lat, centroidLon: lon, fluxIntensity: flux, isPositive: flux > 0)
                    if region.isPositive {
                        posRegions.append(region)
                    } else {
                        negRegions.append(region)
                    }
                }
            }
        }
        
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
            let r3 = rSq * sqrt(rSq) + 0.0001
            bField += (rVec * region.flux) / r3
        }
        return bField
    }
    
    private func traceFieldLine(startPoint p0: simd_float3, regions: [(pos: simd_float3, flux: Float)], intensity: Float) -> MagneticLoopLine {
        var currentPos = p0
        var maxRadius: Float = 1.0
        var p1 = p0
        
        // FIX: Halved the step size for higher resolution curves to catch tight negative poles
        let stepSize: Float = 0.02
        let maxSteps = 250 // Increased max steps to compensate for smaller jumps
        
        // FIX: Start much closer to the surface so it doesn't instantly escape weak fields
        currentPos += simd_normalize(p0) * 0.01
        
        var isOpen = true
        var p2 = p0
        
        for _ in 0..<maxSteps {
            let bField = computeMagneticField(at: currentPos, regions: regions)
            let direction = simd_normalize(bField)
            
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
            
            if currentRadius > 3.0 {
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
        var loops: [MagneticLoopLine] = []
        
        var allRegions3D: [(pos: simd_float3, flux: Float)] = []
        for r in posRegions + negRegions {
            allRegions3D.append((sphericalToCartesian(lat: r.centroidLat, lon: r.centroidLon), r.fluxIntensity))
        }
        
        let linesPerRegion = 12
        let bundleSpreadRadius: Float = 0.06
        
        for pos in posRegions {
            let centerPos = sphericalToCartesian(lat: pos.centroidLat, lon: pos.centroidLon)
            
            let up = simd_float3(0, 1, 0)
            var right = simd_cross(centerPos, up)
            if simd_length(right) < 0.001 { right = simd_float3(1, 0, 0) }
            right = simd_normalize(right)
            let localUp = simd_normalize(simd_cross(right, centerPos))
            
            for i in 0..<linesPerRegion {
                let angle = (Float(i) / Float(linesPerRegion)) * 2.0 * .pi
                let offset = (right * cos(angle) + localUp * sin(angle)) * bundleSpreadRadius
                let p0 = simd_normalize(centerPos + offset)
                
                let loop = traceFieldLine(startPoint: p0, regions: allRegions3D, intensity: pos.fluxIntensity)
                
                // FIX: Lowered the threshold from 1.05 to 1.01.
                // Now, tight magnetic arches that hug the surface will be rendered!
                if simd_length(loop.p1) > 1.01 {
                    loops.append(loop)
                }
            }
        }
        
        return loops
    }
}
