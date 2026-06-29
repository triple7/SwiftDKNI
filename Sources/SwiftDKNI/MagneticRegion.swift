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
        // In reality, you would query the JSOC DRMS API to get the current Carrington Rotation number.
        // For this example, we use a known Stanford JSOC endpoint format for HMI synoptic maps.
        // E.g., https://jsoc.stanford.edu/data/hmi/synoptic/hmi.Synoptic_Mr.2270.fits
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
            throw NSError(domain: "MagnetogramError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to parse FITS file structure"])
        }
        
        let prime = fits.prime

        // 2. Extract Dimensions (NAXIS1 = width, NAXIS2 = height)
        let width = prime.naxis(1) ?? 3600
        let height = prime.naxis(2) ?? 1440
        let pixelCount = width * height
        
        // 3. Extract the raw byte data
        guard let rawData = prime.dataUnit, rawData.count >= pixelCount * 4 else {
            throw NSError(domain: "MagnetogramError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing or incomplete FITS data block"])
        }
        
        // 4. Convert Big-Endian FITS bytes to native Swift Floats
        var dataArray = [Float](repeating: 0.0, count: pixelCount)
        
        rawData.withUnsafeBytes { rawBuffer in
            // Bind the raw bytes to 32-bit unsigned integers
            let pointer = rawBuffer.bindMemory(to: UInt32.self)
            
            for i in 0..<pixelCount {
                // FITS Floats (BITPIX = -32) are Big Endian.
                // We swap to native endianness, then get the Float bit pattern.
                let nativeUInt32 = UInt32(bigEndian: pointer[i])
                dataArray[i] = Float(bitPattern: nativeUInt32)
            }
        }
        
        // 5. Convert Float array (Gauss values) to an 8-bit grayscale image
        var pixels = [UInt8](repeating: 0, count: pixelCount)
        let minGauss: Float = -1500.0
        let maxGauss: Float = 1500.0
        let range = maxGauss - minGauss
        
        for i in 0..<pixelCount {
            let value = dataArray[i]
            
            // NASA Magnetograms often use NaN for off-limb (space) pixels
            if value.isNaN {
                pixels[i] = 127 // Neutral gray
                continue
            }
            
            let clamped = max(minGauss, min(maxGauss, value))
            let normalized = (clamped - minGauss) / range
            pixels[i] = UInt8(normalized * 255.0)
        }
        
        // 6. Generate the CGImage
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

    // MARK: - 4. Modeling & Spline Extraction
    
    /// Scans the flux array to find clusters of extreme magnetic activity
    private func extractActiveRegions(from data: MagnetogramData, thresholdGauss: Float = 500.0) -> (positive: [MagneticRegion], negative: [MagneticRegion]) {
        var posRegions: [MagneticRegion] = []
        var negRegions: [MagneticRegion] = []
        
        // To prevent UI lockup on a 5-million pixel image, we stride (downsample) the scanning
        let strideStep = 10
        
        for y in stride(from: 0, to: data.height, by: strideStep) {
            for x in stride(from: 0, to: data.width, by: strideStep) {
                let index = y * data.width + x
                let flux = data.fluxArray[index]
                
                if abs(flux) > thresholdGauss {
                    // Convert (x,y) on equirectangular map to Lat/Lon
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
        
        // In a production app, you would run a K-Means clustering algorithm here 
        // to group neighboring pixels into single massive 'Sunspot' regions.
        return (posRegions, negRegions)
    }
    
    /// Converts a Latitude/Longitude to a 3D Cartesian vector on a sphere
    private func sphericalToCartesian(lat: Float, lon: Float, radius: Float = 1.0) -> simd_float3 {
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        return simd_float3(
            cos(latRad) * sin(lonRad) * radius,
            sin(latRad) * radius,
            cos(latRad) * cos(lonRad) * radius
        )
    }
    
    /// The Holy Grail algorithm: Pairs positive and negative regions to form loops, or spawns open field lines.
    public func calculateMagneticLoops(from data: MagnetogramData, connectionThresholdDegrees: Float = 25.0) -> [MagneticLoopLine] {
        let (posRegions, negRegions) = extractActiveRegions(from: data)
        var loops: [MagneticLoopLine] = []
        
        // We need mutable copies to track which negative regions have already been paired up
        var availableNegatives = negRegions
        
        for pos in posRegions {
            let p0 = sphericalToCartesian(lat: pos.centroidLat, lon: pos.centroidLon)
            
            // Find the closest negative region
            var closestDistance: Float = .greatestFiniteMagnitude
            var closestIndex: Int? = nil
            var closestNeg: MagneticRegion? = nil
            
            for (index, neg) in availableNegatives.enumerated() {
                // Quick equirectangular distance check (Pythagorean)
                let dLat = pos.centroidLat - neg.centroidLat
                let dLon = pos.centroidLon - neg.centroidLon
                let distance = sqrt(dLat*dLat + dLon*dLon)
                
                if distance < closestDistance {
                    closestDistance = distance
                    closestIndex = index
                    closestNeg = neg
                }
            }
            
            if let closestNeg = closestNeg, let index = closestIndex, closestDistance <= connectionThresholdDegrees {
                // MATCH FOUND: Create a CLOSED LOOP between the regions
                availableNegatives.remove(at: index) // Consume the negative pole
                
                let p2 = sphericalToCartesian(lat: closestNeg.centroidLat, lon: closestNeg.centroidLon)
                
                // Apex calculation: Find midpoint, push it outward based on the distance between the roots
                let midPoint = simd_normalize(p0 + p2) 
                let apexHeight = 1.0 + (closestDistance / 50.0) // Wider roots = taller loop
                let p1 = midPoint * apexHeight
                
                loops.append(MagneticLoopLine(p0: p0, p1: p1, p2: p2, isOpen: false, intensity: pos.fluxIntensity))
                
            } else {
                // NO MATCH NEARBY: Create an OPEN FIELD LINE (CME / Solar Wind)
                // This means the magnetic pressure is too high and snaps outward into space
                
                let outwardVector = simd_normalize(p0)
                let p1 = p0 + (outwardVector * 3.0) // Shoot it out 3 solar radii
                
                loops.append(MagneticLoopLine(p0: p0, p1: p1, p2: p0, isOpen: true, intensity: pos.fluxIntensity))
            }
        }
        
        return loops
    }
}
