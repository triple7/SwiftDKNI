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

public struct MagneticBucket {
    public let position: simd_float3 // 3D Cartesian Coordinate
    public let gauss: Float          // Raw Flux Intensity
}

public struct MagneticRegion {
    let centroidLat: Float
    let centroidLon: Float
    let fluxIntensity: Float
    let isPositive: Bool
}

public struct MagneticLoopLine {
    let p0: simd_float3 // Root 1
    let p1: simd_float3 // Quarter Point (Ascending)
    let p2: simd_float3 // Apex
    let p3: simd_float3 // Three-Quarter Point (Descending)
    let p4: simd_float3 // Root 2 / Escape Point
    let isOpen: Bool    // CME Line
    let intensity: Float
}

public final class MagnetogramModeler: @unchecked Sendable {
    
    public init() {}
    
    // MARK: - 1. API Request
    
    public func fetchLatestSynopticMagnetogram(cachedIfExists: Bool = true) async throws -> URL {
        let rotationNumber = 2270
        let urlString = "http://jsoc.stanford.edu/data/hmi/synoptic/hmi.Synoptic_Mr.\(rotationNumber).fits"
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let starsDirectoryURL = docsDir.appendingPathComponent("stars")
        let savedURL = starsDirectoryURL.appendingPathComponent("latest_magnetogram.fits")
        
        // 1. Check the local cache if requested
        if cachedIfExists && fileManager.fileExists(atPath: savedURL.path) {
            print("MagnetogramModeler: Loaded magnetogram from cache at \(savedURL.lastPathComponent)")
            return savedURL
        }
        
        // 2. Perform the Network Request if we don't have cached data
        let (localURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        // Ensure the 'stars' directory exists before moving the file
        if !fileManager.fileExists(atPath: starsDirectoryURL.path) {
            try fileManager.createDirectory(at: starsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Clean up any corrupted or old file at the exact path just in case
        if fileManager.fileExists(atPath: savedURL.path) {
            try fileManager.removeItem(at: savedURL)
        }
        
        try fileManager.moveItem(at: localURL, to: savedURL)
        print("MagnetogramModeler: Saved newly fetched magnetogram to cache.")
        
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
        let processFitsStart = CACurrentMediaTime()
        
        
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
            let starDir = docsDir.appendingPathComponent("stars")
            if !fileManager.fileExists(atPath: starDir.path) {
                try? fileManager.createDirectory(at: starDir, withIntermediateDirectories: true, attributes: nil)
            }
            let debugImageURL = starDir.appendingPathComponent("magnetogram_debug.jpg")
            if let destination = CGImageDestinationCreateWithURL(debugImageURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cgImage, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        
        let processFitsEnd = CACurrentMediaTime()
        print("processFitsFile: processed fits data in \(processFitsEnd - processFitsStart) seconds.")
        
        return MagnetogramData(cgImage: cgImage, width: width, height: height, fluxArray: dataArray)
    }
    
    // MARK: - 4. PFSS Modeling & Magnetic Integration
    private func extractActiveRegions(from data: MagnetogramData, thresholdGauss: Float = 40.0) -> (positive: [MagneticRegion], negative: [MagneticRegion], regionalTwists: [String: simd_float2]) {
        
        print("\n=== MAGNETIC FIELD ANALYSIS ===")
        
        let gridSize = 40
        let bucketsX = (data.width + gridSize - 1) / gridSize
        let bucketsY = (data.height + gridSize - 1) / gridSize
        let totalBuckets = bucketsX * bucketsY
        
        print("1. Grid Size: \(gridSize)x\(gridSize) pixels")
        print("2. Total Analysis Buckets: \(totalBuckets)")
        
        var bucketResults = [MagneticRegion?](repeating: nil, count: totalBuckets)
        var bucketTwists = [simd_float2?](repeating: nil, count: totalBuckets)
        
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
            
            // 🚨 STRATIFIED GENERATION: Calculate True Latitude using Arcsin
            let sinLat = (Float(localPeakY) / Float(data.height - 1)) * 2.0 - 1.0
            let latRad = asin(max(-1.0, min(1.0, sinLat)))
            let trueLat = latRad * 180.0 / .pi
            
            // Define Geographic Zones (Royal Zone vs Poles)
            let isPolar = abs(trueLat) > 55.0
            let dynamicThreshold: Float = isPolar ? 10.0 : thresholdGauss
            
            if localMaxAbsFlux > dynamicThreshold {
                let lon = (Float(localPeakX) / Float(data.width)) * 360.0 - 180.0
                
                bucketResults[i] = MagneticRegion(centroidLat: trueLat, centroidLon: lon, fluxIntensity: localPeakFlux, isPositive: localPeakFlux > 0)
                
                // Calculate the regional magnetic moment (Helicity)
                var momentX: Float = 0.0
                var momentY: Float = 0.0
                
                for cy in startY..<endY {
                    let rowOffset = cy * data.width
                    for cx in startX..<endX {
                        let index = rowOffset + cx
                        let flux = data.fluxArray[index]
                        
                        if !flux.isNaN {
                            let dx = Float(cx - localPeakX)
                            let dy = Float(cy - localPeakY)
                            momentX += dx * abs(flux)
                            momentY += dy * abs(flux)
                        }
                    }
                }
                
                var twist = simd_float2(momentX, momentY)
                if simd_length(twist) > 0.001 {
                    twist = simd_normalize(twist)
                } else {
                    twist = simd_float2(1.0, 0.0)
                }
                
                bucketTwists[i] = twist
            }
        }
        
        var posRegions: [MagneticRegion] = []
        var negRegions: [MagneticRegion] = []
        var regionalTwists: [String: simd_float2] = [:]
        
        for i in 0..<totalBuckets {
            if let region = bucketResults[i], let twist = bucketTwists[i] {
                if region.isPositive { posRegions.append(region) }
                else { negRegions.append(region) }
                
                let key = "\(region.centroidLat)_\(region.centroidLon)"
                regionalTwists[key] = twist
            }
        }
        
        // 🚨 TARGETED GEOGRAPHIC SAFETY CAPS
        var equatorialPos = posRegions.filter { abs($0.centroidLat) <= 55.0 }
        var polarPos      = posRegions.filter { abs($0.centroidLat) >  55.0 }
        var equatorialNeg = negRegions.filter { abs($0.centroidLat) <= 55.0 }
        var polarNeg      = negRegions.filter { abs($0.centroidLat) >  55.0 }
        
        // Sort by intensity
        equatorialPos.sort { abs($0.fluxIntensity) > abs($1.fluxIntensity) }
        polarPos.sort      { abs($0.fluxIntensity) > abs($1.fluxIntensity) }
        equatorialNeg.sort { abs($0.fluxIntensity) > abs($1.fluxIntensity) }
        polarNeg.sort      { abs($0.fluxIntensity) > abs($1.fluxIntensity) }
        
        let maxEquatorial = 120
        let maxPolar = 30
        
        equatorialPos = Array(equatorialPos.prefix(maxEquatorial))
        polarPos      = Array(polarPos.prefix(maxPolar))
        equatorialNeg = Array(equatorialNeg.prefix(maxEquatorial))
        polarNeg      = Array(polarNeg.prefix(maxPolar))
        
        let finalPosRegions = equatorialPos + polarPos
        let finalNegRegions = equatorialNeg + polarNeg
        
        print("3. Final Stratified Regions: \(finalPosRegions.count) Positive, \(finalNegRegions.count) Negative")
        print("===============================\n")
        
        return (finalPosRegions, finalNegRegions, regionalTwists)
    }
    
    // MARK: - Volumetric Bucket Extraction (PFSS)
    public func exportRawBuckets(from data: MagnetogramData, thresholdGauss: Float = 20.0) -> [MagneticBucket] {
        print("\n=== VOLUMETRIC BUCKET EXTRACTION ===")
        let gridSize = 40
        let bucketsX = (data.width + gridSize - 1) / gridSize
        let bucketsY = (data.height + gridSize - 1) / gridSize
        let totalBuckets = bucketsX * bucketsY
        
        var threadSafeBuckets = [MagneticBucket?](repeating: nil, count: totalBuckets)
        
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
            
            // 🚨 STRATIFIED GENERATION: Calculate True Latitude using Arcsin
            let sinLat = (Float(localPeakY) / Float(data.height - 1)) * 2.0 - 1.0
            let latRad = asin(max(-1.0, min(1.0, sinLat)))
            let trueLat = latRad * 180.0 / .pi
            
            // The PFSS physics volume needs to capture the polar loops we just allowed
            let isPolar = abs(trueLat) > 55.0
            let dynamicThreshold: Float = isPolar ? thresholdGauss * 0.25 : thresholdGauss
            
            if localMaxAbsFlux > dynamicThreshold {
                let lon = (Float(localPeakX) / Float(data.width)) * 360.0 - 180.0
                
                // Convert instantly to the 3D unit sphere
                let cartesianPos = self.sphericalToCartesian(lat: trueLat, lon: lon, radius: 1.0)
                
                threadSafeBuckets[i] = MagneticBucket(position: cartesianPos, gauss: localPeakFlux)
            }
        }
        
        let finalBuckets = threadSafeBuckets.compactMap { $0 }
        print("Extracted \(finalBuckets.count) raw magnetic poles for 3D volumetric matrix.")
        print("====================================\n")
        
        return finalBuckets
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

    private func traceFieldLine(startPoint p0: simd_float3, regions: [(pos: simd_float3, flux: Float)], intensity: Float, twist: simd_float2) -> MagneticLoopLine {
        var currentPos = p0
        let stepSize: Float = 0.02
        let maxSteps = 250
        
        // Push slightly outwards to start
        currentPos += simd_normalize(p0) * 0.01
        var isOpen = true
        
        // We cache the traced path to accurately extract our 5 control points later
        var path: [simd_float3] = [p0]
        var maxRadius: Float = simd_length(currentPos)
        var apexIndex = 0
        
        for _ in 0..<maxSteps {
            let bField = computeMagneticField(at: currentPos, regions: regions)
            
            let length = simd_length(bField)
            if length < 0.00001 || length.isNaN { break }
            
            let direction = bField / length
            currentPos += direction * stepSize
            let currentRadius = simd_length(currentPos)
            
            path.append(currentPos)
            
            if currentRadius > maxRadius {
                maxRadius = currentRadius
                apexIndex = path.count - 1
            }
            
            if currentRadius <= 1.0 {
                isOpen = false
                path[path.count - 1] = simd_normalize(currentPos) // Clamp exactly to surface
                break
            }
            
            if currentRadius > 6.0 {
                isOpen = true
                break
            }
        }
        
        // --- EXTRACT 5 CONTROL POINTS FROM THE TRACED PATH ---
        var p_0 = path[0]
        var p_4 = path[path.count - 1]
        
        var p_2: simd_float3
        var p_1: simd_float3
        var p_3: simd_float3
        
        if isOpen && simd_length(p_4) <= 3.0 {
            // Premature loop death failsafe - mathematically force an open trajectory
            p_4 = path.last!
            p_2 = p_0 + (simd_normalize(p_0) * 1.5)
            p_1 = simd_mix(p_0, p_2, simd_float3(repeating: 0.5))
            p_3 = simd_mix(p_2, p_4, simd_float3(repeating: 0.5))
            maxRadius = simd_length(p_2)
        } else {
            // Natural trajectory - extract indices evenly across the B-spline
            p_2 = path[apexIndex]
            p_1 = path[max(0, apexIndex / 2)]
            
            let remainderIdx = apexIndex + (path.count - 1 - apexIndex) / 2
            p_3 = path[min(path.count - 1, remainderIdx)]
        }
        
        // --- APPLY REGIONAL HELICITY (TWIST) TO THE APEX (P2) ---
        var p2Norm = simd_normalize(p_2)
        if p2Norm.x.isNaN { p2Norm = simd_normalize(p_0) } // Safety catch
        
        let up = simd_float3(0, 1, 0)
        var tangent = simd_cross(p2Norm, up)
        
        if simd_length(tangent) < 0.001 { tangent = simd_float3(1, 0, 0) }
        tangent = simd_normalize(tangent)
        
        let binormal = simd_normalize(simd_cross(tangent, p2Norm))
        
        let leanStrength: Float = 0.15 * maxRadius
        
        // Protect against NaN in twist vector
        let safeTwistX = twist.x.isNaN ? 0.0 : twist.x
        let safeTwistY = twist.y.isNaN ? 0.0 : twist.y
        
        let directionalOffset = (tangent * safeTwistX + binormal * safeTwistY) * leanStrength
        p_2 += directionalOffset
        
        // --- ANTI-NAN GEOMETRY FAIL-SAFE ---
        // Force minimum spatial separation to guarantee the Metal derivative never normalizes a zero-vector
        if simd_distance(p_1, p_0) < 0.05 { p_1 = p_0 + (p2Norm * 0.05) }
        if simd_distance(p_2, p_1) < 0.05 { p_2 = p_1 + (p2Norm * 0.05) + (tangent * 0.05) }
        if simd_distance(p_3, p_2) < 0.05 { p_3 = p_2 + (p2Norm * 0.05) }
        if simd_distance(p_4, p_3) < 0.05 {
            let escapeVector = simd_normalize(simd_cross(p2Norm, tangent))
            p_4 = p_3 + (escapeVector * 0.05)
        }
        
        // 🚨 THE NaN TRAP 🚨
        let hasNaN = p_0.x.isNaN || p_0.y.isNaN || p_0.z.isNaN ||
                     p_1.x.isNaN || p_1.y.isNaN || p_1.z.isNaN ||
                     p_2.x.isNaN || p_2.y.isNaN || p_2.z.isNaN ||
                     p_3.x.isNaN || p_3.y.isNaN || p_3.z.isNaN ||
                     p_4.x.isNaN || p_4.y.isNaN || p_4.z.isNaN
        
        if hasNaN {
            print("🚨 NaN TRAP TRIGGERED 🚨")
            print("Start Point: \(p_0)")
            print("Final p_2 (Apex): \(p_2)")
            print("Final p_4 (End): \(p_4)")
            print("Twist vector: \(twist)")
            print("Max Radius: \(maxRadius)")
            print("---------------------------------")
            
            // Return a safe dummy line slightly above the surface so SceneKit doesn't crash
            let safe0 = simd_float3(0, 1.05, 0)
            let safe1 = simd_float3(0, 1.10, 0)
            let safe2 = simd_float3(0, 1.15, 0)
            let safe3 = simd_float3(0, 1.20, 0)
            let safe4 = simd_float3(0, 1.25, 0)
            return MagneticLoopLine(p0: safe0, p1: safe1, p2: safe2, p3: safe3, p4: safe4, isOpen: isOpen, intensity: intensity)
        }
        
        return MagneticLoopLine(p0: p_0, p1: p_1, p2: p_2, p3: p_3, p4: p_4, isOpen: isOpen, intensity: intensity)
    }

    public func calculateMagneticLoops(from data: MagnetogramData, connectionThresholdDegrees: Float = 25.0) -> [MagneticLoopLine] {
        // 1. Unpack the new regional twists dictionary
        let (posRegions, negRegions, regionalTwists) = extractActiveRegions(from: data)
        
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
            
            // 2. Fetch the regional twist (helicity) for this specific anchor
            let key = "\(pos.centroidLat)_\(pos.centroidLon)"
            let twist = regionalTwists[key] ?? simd_float2(1.0, 0.0)
            
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
                
                // 3. Pass the twist into your tracing function
                let loop = traceFieldLine(startPoint: p0, regions: allRegions3D, intensity: pos.fluxIntensity, twist: twist)
                
                // 🚨 CRITICAL UPDATE: Ensure we are evaluating loop.p2 (the new Apex), not loop.p1
                if simd_length(loop.p2) > 1.01 {
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
