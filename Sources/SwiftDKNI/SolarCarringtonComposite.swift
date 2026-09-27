//
//  SolarCarringtonComposite.swift
//  SwiftDKNI
//
//  Builds a genuine full-surface heliographic map of the Sun by mosaicking a
//  series of SDO disk exposures taken across the trailing solar rotation.
//
//  WHY THIS EXISTS
//
//  There is no maintained near-real-time AIA Carrington map to download. The
//  SECCHI archive (stereo-ssc.nascom.nasa.gov/data/ins_data/secchi/carrmaps/aia/)
//  stops around CR2297, the copy linked from SDO's synoptic page stops around
//  CR2311, and JSOC publishes no AIA Carrington series at all - in AIA parlance
//  "synoptic" means a reduced-resolution full disk, not a heliographic map. The
//  JHUAPL SDO+STEREO synchronic product that would have solved this outright
//  died with STEREO-B in 2016.
//
//  So we run the standard synoptic construction ourselves. SDO's dated browse
//  archive is fully listable at 144 frames/day/wavelength, which is all the raw
//  material needed.
//
//  HOW IT WORKS
//
//  Each exposure sees one hemisphere, foreshortened by cos(angle from disk
//  centre). Rather than hard-cutting each exposure into a longitude strip - which
//  produces visible sharpness pulses and hard temporal joins - every sample
//  contributes everywhere it is visible, weighted by cos^k of that angle. Samples
//  overlap heavily, so seams dissolve into gradients. A coverage mask tracks how
//  well each point was ever seen; the polar caps are never seen face-on from the
//  ecliptic, so they are extrapolated from the coverage boundary rather than
//  invented or left black.
//
//  Because Carrington longitude is an absolute coordinate, the cache is
//  effectively a ring buffer in longitude: each new exposure displaces the one
//  that has aged past a full rotation. Steady-state cost is two downloads a day.
//

import Foundation
import Metal
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Sample Bookkeeping

/// One cached disk exposure: where it lives on disk and where it was pointing.
private struct CompositeSample {
    let date: Date
    let fileName: String
    var url: URL { compositeCacheDirectory().appendingPathComponent(fileName) }
}

/// Subdirectory holding the cached disk exposures that feed the mosaic.
private func compositeCacheDirectory() -> URL {
    let directory = starsDirectoryURL().appendingPathComponent("composite_cache")
    if !FileManager.default.fileExists(atPath: directory.path) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return directory
}

private let compositeFileDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private let compositeDirectoryDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

// MARK: - Public Entry Point

extension SwiftDKNI {

    /// Builds (or refreshes) the full-surface rotation composite for 171 and 193.
    ///
    /// - Returns: base plasma map (171), coronal hole map (193), plus the grayscale
    ///   topological activity map derived from the 193 composite.
    public func carringtonCompositeSurfaceTextures(
        device: MTLDevice,
        cachedIfExists: Bool = true
    ) async throws -> (basePlasma: XImage, coronalHoles: XImage, topologicalMap: [UInt8], mapWidth: Int, mapHeight: Int) {

        let basePlasma = try await carringtonCompositeMap(
            wavelength: .aia171, device: device, cachedIfExists: cachedIfExists)
        let coronalHoles = try await carringtonCompositeMap(
            wavelength: .aia193, device: device, cachedIfExists: cachedIfExists)

        guard let holesCG = extractCGImage(coronalHoles) else {
            throw NSError(domain: "SolarCarringtonComposite", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to extract CGImage from composite 193 map"])
        }

        let (topoMap, topoW, topoH) = grayscaleActivityMap(from: holesCG)
        dumpGrayscaleDebugJPEG(topoMap, width: topoW, height: topoH, fileName: "topological_map_debug.jpg")

        return (basePlasma, coronalHoles, topoMap, topoW, topoH)
    }

    /// Builds one wavelength's composite, reusing cached exposures where possible.
    private func carringtonCompositeMap(
        wavelength: SDOWavelength,
        device: MTLDevice,
        cachedIfExists: Bool
    ) async throws -> XImage {

        let compositeName = "composite_\(wavelength.rawValue).jpg"
        let compositeURL = starsDirectoryURL().appendingPathComponent(compositeName)
        let fileManager = FileManager.default

        // 1. Gather the exposures we want, reusing the cache and fetching the rest
        let samples = await refreshedSampleSet(wavelength: wavelength, cachedIfExists: cachedIfExists)

        guard !samples.isEmpty else {
            throw NSError(domain: "SolarCarringtonComposite", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No disk exposures available for \(wavelength) composite"])
        }

        // 2. If the composite on disk is already newer than every cached exposure,
        // there is nothing to rebuild.
        if cachedIfExists,
           let compositeDate = (try? fileManager.attributesOfItem(atPath: compositeURL.path)[.modificationDate]) as? Date,
           let newestSample = samples.map(\.date).max(),
           compositeDate > newestSample,
           let data = try? Data(contentsOf: compositeURL),
           let cached = XImage(data: data) {
            print("SolarCarringtonComposite: \(compositeName) is current (\(samples.count) exposures), reusing")
            return cached
        }

        // 3. Mosaic on the GPU
        guard let result = buildMosaic(device: device, samples: samples, wavelength: wavelength) else {
            throw NSError(domain: "SolarCarringtonComposite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "GPU mosaic failed for \(wavelength)"])
        }

        writeJPEG(result.map, to: compositeURL)
        print("SolarCarringtonComposite: wrote \(compositeName) from \(samples.count) exposures")

        // Coverage dump makes gaps and overlap structure visible at a glance
        writeJPEG(result.coverage,
                  to: starsDirectoryURL().appendingPathComponent("composite_\(wavelength.rawValue)_coverage_debug.jpg"))

        return xImage(from: result.map)
    }

    // MARK: - Sample Acquisition

    /// Returns the set of cached exposures spanning the trailing rotation, fetching
    /// any that are missing and evicting any that have aged out.
    private func refreshedSampleSet(
        wavelength: SDOWavelength,
        cachedIfExists: Bool
    ) async -> [CompositeSample] {

        let now = Date()
        let periodDays = SolarCompositeSettings.rotationPeriodDays
        let sampleCount = SolarCompositeSettings.sampleCount
        let spacingDays = periodDays / Double(sampleCount)

        evictExpiredSamples(olderThan: now.addingTimeInterval(-periodDays * 86400.0 * 1.1))

        let cached = cachedSamples(wavelength: wavelength)
        var samples: [CompositeSample] = []

        for index in 0..<sampleCount {
            let targetDate = now.addingTimeInterval(-Double(index) * spacingDays * 86400.0)

            // Reuse a cached exposure if one already sits close to this slot. Half
            // the slot spacing is the tolerance, so slots never share an exposure.
            let toleranceSeconds = spacingDays * 86400.0 * 0.5
            if let existing = cached.min(by: {
                abs($0.date.timeIntervalSince(targetDate)) < abs($1.date.timeIntervalSince(targetDate))
            }), abs(existing.date.timeIntervalSince(targetDate)) < toleranceSeconds {
                samples.append(existing)
                continue
            }

            if let fetched = await fetchSample(wavelength: wavelength, near: targetDate) {
                samples.append(fetched)
            } else {
                print("SolarCarringtonComposite: no exposure available near \(targetDate) for \(wavelength), leaving a wider gap")
            }
        }

        // Deduplicate in case two slots resolved to the same file
        var seen = Set<String>()
        return samples.filter { seen.insert($0.fileName).inserted }
    }

    /// Exposures already sitting in the cache directory for this wavelength.
    private func cachedSamples(wavelength: SDOWavelength) -> [CompositeSample] {
        let directory = compositeCacheDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }

        return names.compactMap { name in
            // Format: 20260919_185500_0193.jpg
            guard name.hasSuffix("_\(wavelength.rawValue).jpg") else { return nil }
            let stamp = String(name.dropLast("_\(wavelength.rawValue).jpg".count))
            guard let date = compositeFileDateFormatter.date(from: stamp) else { return nil }
            return CompositeSample(date: date, fileName: name)
        }
    }

    /// Removes cached exposures that have aged past a full rotation.
    private func evictExpiredSamples(olderThan cutoff: Date) {
        let directory = compositeCacheDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }

        for name in names {
            let stamp = String(name.prefix(15)) // yyyyMMdd_HHmmss
            guard let date = compositeFileDateFormatter.date(from: stamp) else { continue }
            if date < cutoff {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                print("SolarCarringtonComposite: evicted aged exposure \(name)")
            }
        }
    }

    /// Downloads the browse-archive exposure closest to the given instant.
    private func fetchSample(wavelength: SDOWavelength, near targetDate: Date) async -> CompositeSample? {
        let resolution = SolarCompositeSettings.sampleResolution
        let suffix = "_\(resolution)_\(wavelength.rawValue).jpg"

        // The archive is organized by UTC day; check the target day, then its
        // neighbours, in case of an outage around the requested time.
        for dayOffset in [0.0, -1.0, 1.0, -2.0] {
            let day = targetDate.addingTimeInterval(dayOffset * 86400.0)
            let datePath = compositeDirectoryDateFormatter.string(from: day)
            guard let indexURL = URL(string: "https://sdo.gsfc.nasa.gov/assets/img/browse/\(datePath)/") else { continue }

            guard let html = try? await fetchString(from: indexURL) else { continue }

            // Entries look like 20260919_185500_2048_0193.jpg
            let candidates = matchingFileNames(in: html, suffix: suffix)
            guard !candidates.isEmpty else { continue }

            let best = candidates.compactMap { name -> (String, Date)? in
                let stamp = String(name.prefix(15))
                guard let date = compositeFileDateFormatter.date(from: stamp) else { return nil }
                return (name, date)
            }.min {
                abs($0.1.timeIntervalSince(targetDate)) < abs($1.1.timeIntervalSince(targetDate))
            }

            guard let (remoteName, exposureDate) = best,
                  let fileURL = URL(string: "https://sdo.gsfc.nasa.gov/assets/img/browse/\(datePath)/\(remoteName)") else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: fileURL)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }

                // Cache under the exposure's own timestamp so L0/B0 stay exact
                let localName = compositeFileDateFormatter.string(from: exposureDate) + "_\(wavelength.rawValue).jpg"
                let sample = CompositeSample(date: exposureDate, fileName: localName)
                try data.write(to: sample.url)
                print("SolarCarringtonComposite: fetched \(remoteName) (\(data.count / 1024) KB)")
                return sample
            } catch {
                print("SolarCarringtonComposite: fetch failed for \(remoteName): \(error.localizedDescription)")
            }
        }
        return nil
    }

    // MARK: - GPU Mosaic

    /// Accumulates every sample's cosine-weighted contribution, then normalizes.
    private func buildMosaic(
        device: MTLDevice,
        samples: [CompositeSample],
        wavelength: SDOWavelength
    ) -> (map: CGImage, coverage: CGImage)? {

        let width = SolarCompositeSettings.mapWidth
        let height = SolarCompositeSettings.mapHeight

        guard let library = makeReprojectionLibrary(device: device),
              let accumulateFunction = library.makeFunction(name: "diskToEquirectAccumulate"),
              let normalizeFunction = library.makeFunction(name: "normalizeMosaic"),
              let accumulatePipeline = try? device.makeComputePipelineState(function: accumulateFunction),
              let normalizePipeline = try? device.makeComputePipelineState(function: normalizeFunction),
              let queue = device.makeCommandQueue() else {
            print("SolarCarringtonComposite: Metal setup failed")
            return nil
        }

        // Weighted accumulator: rgb = sum(color * weight), a = sum(weight)
        let accumulatorLength = width * height * MemoryLayout<SIMD4<Float>>.stride
        // Best viewing angle any sample achieved per pixel, which is what decides coverage
        let cosineLength = width * height * MemoryLayout<Float>.stride
        guard let accumulator = device.makeBuffer(length: accumulatorLength, options: .storageModeShared),
              let bestCosine = device.makeBuffer(length: cosineLength, options: .storageModeShared) else {
            print("SolarCarringtonComposite: could not allocate \((accumulatorLength + cosineLength) / 1_048_576) MB of mosaic buffers")
            return nil
        }
        memset(accumulator.contents(), 0, accumulatorLength)
        memset(bestCosine.contents(), 0, cosineLength)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)

        let startTime = CFAbsoluteTimeGetCurrent()
        var contributed = 0

        for sample in samples.sorted(by: { $0.date < $1.date }) {
            guard let data = try? Data(contentsOf: sample.url),
                  let image = XImage(data: data),
                  let cgImage = extractCGImage(image) else {
                print("SolarCarringtonComposite: could not decode \(sample.fileName)")
                continue
            }

            let (rgba, srcWidth, srcHeight) = rgbaBytes(from: cgImage)
            let geometry = detectDiskGeometry(rgba: rgba, width: srcWidth, height: srcHeight)

            guard let diskTexture = makeDiskTexture(device: device, rgba: rgba,
                                                    width: srcWidth, height: srcHeight),
                  let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }

            var outSize = SIMD2<UInt32>(UInt32(width), UInt32(height))
            var diskCenter = SIMD2<Float>(geometry.centerX, geometry.centerY)
            var diskRadius = SIMD2<Float>(geometry.radiusX, geometry.radiusY)
            var b0 = solarB0(for: sample.date) * .pi / 180.0
            var l0 = carringtonL0(for: sample.date) * .pi / 180.0
            var weightExponent = SolarCompositeSettings.weightExponent
            var minCosine = SolarCompositeSettings.minCosine

            encoder.setComputePipelineState(accumulatePipeline)
            encoder.setTexture(diskTexture, index: 0)
            encoder.setBuffer(accumulator, offset: 0, index: 0)
            encoder.setBuffer(bestCosine, offset: 0, index: 1)
            encoder.setBytes(&outSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
            encoder.setBytes(&diskCenter, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            encoder.setBytes(&diskRadius, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
            encoder.setBytes(&b0, length: MemoryLayout<Float>.stride, index: 5)
            encoder.setBytes(&l0, length: MemoryLayout<Float>.stride, index: 6)
            encoder.setBytes(&weightExponent, length: MemoryLayout<Float>.stride, index: 7)
            encoder.setBytes(&minCosine, length: MemoryLayout<Float>.stride, index: 8)
            encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if commandBuffer.status == .completed {
                contributed += 1
            } else {
                print("SolarCarringtonComposite: accumulate dispatch failed for \(sample.fileName)")
            }
        }

        guard contributed > 0 else {
            print("SolarCarringtonComposite: no exposures contributed to the \(wavelength) mosaic")
            return nil
        }

        let mapDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        mapDescriptor.usage = [.shaderWrite, .shaderRead]
        guard let mapTexture = device.makeTexture(descriptor: mapDescriptor),
              let coverageTexture = device.makeTexture(descriptor: mapDescriptor),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        var minCoverageCosine = SolarCompositeSettings.minCosine
        var goodCoverageCosine = SolarCompositeSettings.goodCosine
        encoder.setComputePipelineState(normalizePipeline)
        encoder.setBuffer(accumulator, offset: 0, index: 0)
        encoder.setBuffer(bestCosine, offset: 0, index: 1)
        encoder.setTexture(mapTexture, index: 0)
        encoder.setTexture(coverageTexture, index: 1)
        encoder.setBytes(&minCoverageCosine, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&goodCoverageCosine, length: MemoryLayout<Float>.stride, index: 3)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            print("SolarCarringtonComposite: normalize dispatch failed")
            return nil
        }

        print("SolarCarringtonComposite: mosaicked \(contributed) exposures for \(wavelength) in \(CFAbsoluteTimeGetCurrent() - startTime)s")

        var mapBytes = readBackRGBA(texture: mapTexture, width: width, height: height)
        var coverageBytes = readBackRGBA(texture: coverageTexture, width: width, height: height)

        fillPolarCaps(map: &mapBytes, coverage: coverageBytes, width: width, height: height)

        guard let mapCG = makeRGBACGImage(bytes: &mapBytes, width: width, height: height),
              let coverageCG = makeRGBACGImage(bytes: &coverageBytes, width: width, height: height) else {
            return nil
        }

        reportCoverage(coverageBytes: coverageBytes, width: width, height: height, wavelength: wavelength)

        return (mapCG, coverageCG)
    }

    /// Resolves the polar caps, which no exposure ever sees face-on from the
    /// ecliptic and which the mosaic therefore leaves black.
    ///
    /// For each column, the colour at the last well-observed row is carried up into
    /// the cap and faded toward that row's zonal (all-longitude) mean as it
    /// approaches the pole. The fade matters: on a sphere every column converges to
    /// a single point at the pole, so extending columns verbatim would pinch a
    /// starburst of conflicting colours together there. Blending toward the zonal
    /// mean lands them all on the same colour instead.
    ///
    /// This is an extrapolation and it is drawn as one - smooth and featureless -
    /// rather than inventing structure. Real synoptic products have the same hole;
    /// it is why polar magnetic field measurements are famously hard.
    private func fillPolarCaps(map: inout [UInt8], coverage: [UInt8], width: Int, height: Int) {
        let observedThreshold: UInt8 = 250

        // Last fully observed row at each end, per column
        var topEdge = [Int](repeating: 0, count: width)
        var bottomEdge = [Int](repeating: height - 1, count: width)
        for x in 0..<width {
            var y = 0
            while y < height && coverage[(y * width + x) * 4] < observedThreshold { y += 1 }
            topEdge[x] = min(y, height - 1)

            var z = height - 1
            while z >= 0 && coverage[(z * width + x) * 4] < observedThreshold { z -= 1 }
            bottomEdge[x] = max(z, 0)
        }

        // Zonal mean colour along each cap's boundary
        func zonalMean(rows: [Int]) -> (Double, Double, Double) {
            var r = 0.0, g = 0.0, b = 0.0
            for x in 0..<width {
                let i = (rows[x] * width + x) * 4
                r += Double(map[i]); g += Double(map[i + 1]); b += Double(map[i + 2])
            }
            let n = Double(width)
            return (r / n, g / n, b / n)
        }
        let northMean = zonalMean(rows: topEdge)
        let southMean = zonalMean(rows: bottomEdge)

        map.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: width) { x in
                let north = topEdge[x]
                let south = bottomEdge[x]

                for y in 0..<height {
                    guard y < north || y > south else { continue }

                    let isNorth = y < north
                    let edgeRow = isNorth ? north : south
                    let mean = isNorth ? northMean : southMean

                    // 0 at the coverage boundary, 1 at the pole
                    let distance = isNorth ? Double(north - y) : Double(y - south)
                    let extent = isNorth ? Double(max(north, 1)) : Double(max(height - 1 - south, 1))
                    let towardPole = min(1.0, distance / extent)

                    let edgeIndex = (edgeRow * width + x) * 4
                    let index = (y * width + x) * 4
                    let observed = Double(coverage[index]) / 255.0

                    for channel in 0..<3 {
                        let edge = Double(buffer[edgeIndex + channel])
                        let meanValue = channel == 0 ? mean.0 : (channel == 1 ? mean.1 : mean.2)
                        let capValue = edge + (meanValue - edge) * towardPole
                        // Thin-coverage rows still hold real data; keep it in proportion
                        let blended = capValue + (Double(buffer[index + channel]) - capValue) * observed
                        buffer[index + channel] = UInt8(max(0.0, min(255.0, blended)))
                    }
                    buffer[index + 3] = 255
                }
            }
        }
    }

    /// Logs how much of the surface the mosaic actually observed, so a silently
    /// degraded composite is obvious in the console.
    private func reportCoverage(coverageBytes: [UInt8], width: Int, height: Int, wavelength: SDOWavelength) {
        var covered = 0
        var total = 0
        // Sample every 8th pixel; this is a diagnostic, not a measurement
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                total += 1
                if coverageBytes[(y * width + x) * 4] > 200 { covered += 1 }
            }
        }
        let percent = total > 0 ? Int(Double(covered) / Double(total) * 100.0) : 0
        print("SolarCarringtonComposite: \(wavelength) surface coverage ~\(percent)% (polar caps beyond that are extrapolated)")
    }
}

// MARK: - Small Networking / Readback Helpers

/// Reads a texture back into a flat RGBA8 array.
internal func readBackRGBA(texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { ptr in
        texture.getBytes(ptr.baseAddress!, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    return bytes
}

/// Fetches a URL as a UTF-8 string (used for directory index scraping).
internal func fetchString(from url: URL) async throws -> String {
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw URLError(.badServerResponse)
    }
    return String(decoding: data, as: UTF8.self)
}

/// Extracts href/HREF file names ending in the given suffix from a directory index.
/// The SDO archive emits uppercase HREF with no quoting surprises, but this stays
/// tolerant of either case.
internal func matchingFileNames(in html: String, suffix: String) -> [String] {
    var results: [String] = []
    // Split on quotes and keep any token that looks like the file we want
    for token in html.split(whereSeparator: { $0 == "\"" || $0 == "'" || $0 == ">" || $0 == "<" }) {
        let candidate = String(token)
        if candidate.hasSuffix(suffix), !candidate.contains("/") {
            results.append(candidate)
        }
    }
    var seen = Set<String>()
    return results.filter { seen.insert($0).inserted }
}
