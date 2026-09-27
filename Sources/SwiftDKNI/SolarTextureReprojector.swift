//
//  SolarTextureReprojector.swift
//  SwiftDKNI
//
//  Reprojection machinery shared by the solar surface texture pipeline: the MSL
//  compute kernels that turn SDO disk exposures into an equirectangular
//  heliographic map, solar limb detection, and the image helpers both the mosaic
//  and the baked surface composite rely on.
//
//  The pipeline that drives these lives in SolarCarringtonComposite.swift.
//
//  A disk exposure is an orthographic view of the near hemisphere from Earth, so
//  no single exposure can cover the sphere. Rather than inventing the far side,
//  the mosaic accumulates many exposures taken across a solar rotation, each
//  weighted by how face-on it saw a given point. These kernels are the two halves
//  of that: accumulate, then normalize.
//
//  Kernels are MSL compiled from source at runtime. Outputs are cached and dumped
//  to the stars/ folder as JPGs for eyeball debugging.
//

import Foundation
import Metal
import CoreGraphics
import ImageIO

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - MSL Compute Kernel (Metal, not OpenGL)

internal let diskToEquirectKernelSource = """
#include <metal_stdlib>
using namespace metal;

constexpr sampler diskSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// Orthographic projection of a heliographic surface point onto a solar disk image.
//
//   lonRel : longitude relative to the disk's central meridian (radians)
//   lat    : heliographic latitude (radians)
//   b0     : heliographic latitude of the disk centre, the solar tilt (radians)
//
// Returns the disk UV in .xy and the cosine of the angle from disk centre in .z.
// That cosine is doing double duty: z > 0 means the point is on the near side at
// all, and z itself is the foreshortening factor (1 = face-on, 0 = exactly on
// the limb), which makes it the natural blend weight for a mosaic.
static inline float3 diskProject(float lonRel, float lat, float b0,
                                 float2 diskCenter, float2 diskRadius)
{
    float cosLat = cos(lat);
    float sinLat = sin(lat);
    float cosLonRel = cos(lonRel);
    float sinLonRel = sin(lonRel);
    float cosB0 = cos(b0);
    float sinB0 = sin(b0);

    float x = cosLat * sinLonRel;
    float y = sinLat * cosB0 - cosLat * cosLonRel * sinB0;
    float z = sinLat * sinB0 + cosLat * cosLonRel * cosB0;

    return float3(diskCenter.x + diskRadius.x * x,
                  diskCenter.y - diskRadius.y * y,
                  z);
}

// Wrap an angle into [-pi, pi] without branching.
static inline float wrapPi(float a) { return atan2(sin(a), cos(a)); }

// Equirectangular pixel centre -> (Carrington longitude, latitude) in radians.
//
// Longitude runs 0 -> 360 across the map, matching how MagnetogramModeler indexes
// the HMI synoptic FITS: its header (CTYPE1 'CRLN-CEA', CDELT1 -0.1, spanning
// Carrington time 360*CAR_ROT down to 360*(CAR_ROT-1)) puts Carrington longitude 0
// at the first column and 360 at the last, and the modeler turns column fraction u
// into a scene longitude of u*360 - 180. Encoding the same u -> longitude relation
// here is what keeps active regions sitting under their magnetic loops; centring
// the map on longitude 0 instead would offset the texture from the loops by 180.
//
// Latitude keeps row 0 at the north pole, which is what SceneKit expects of an
// equirectangular sphere texture. The magnetogram's own rows are sine-latitude and
// run south-first, but the modeler resolves those to true latitudes via asin before
// anything is placed, so both paths meet in true heliographic latitude.
static inline float2 pixelToLonLat(uint2 gid, uint w, uint h)
{
    float lon = ((float(gid.x) + 0.5f) / float(w)) * 2.0f * M_PI_F;
    float lat = M_PI_F * 0.5f - ((float(gid.y) + 0.5f) / float(h)) * M_PI_F;
    return float2(lon, lat);
}

// ---------------------------------------------------------------------------
// Step 1: accumulate one disk image's cosine-weighted contribution.
//
// Dispatched once per sample image. Each thread owns a distinct output pixel and
// the dispatches are serialized by the command buffer, so the read-modify-write
// needs no atomics.
// ---------------------------------------------------------------------------
kernel void diskToEquirectAccumulate(
    texture2d<float, access::sample> diskTex [[texture(0)]],
    device float4 *accum               [[buffer(0)]],
    device float  *bestCosine          [[buffer(1)]], // best viewing angle any sample achieved
    constant uint2  &outSize           [[buffer(2)]],
    constant float2 &diskCenter        [[buffer(3)]],
    constant float2 &diskRadius        [[buffer(4)]],
    constant float  &b0                [[buffer(5)]],
    constant float  &l0                [[buffer(6)]],
    constant float  &weightExponent    [[buffer(7)]], // higher = trust face-on data more
    constant float  &minCosine         [[buffer(8)]], // reject data closer to the limb than this
    uint2 gid [[thread_position_in_grid]])
{
    uint w = outSize.x;
    uint h = outSize.y;
    if (gid.x >= w || gid.y >= h) { return; }

    float2 lonLat = pixelToLonLat(gid, w, h);
    float lonRel = wrapPi(lonLat.x - l0);

    float3 p = diskProject(lonRel, lonLat.y, b0, diskCenter, diskRadius);

    // Off the near side, or too close to the limb to carry usable detail
    if (p.z <= minCosine) { return; }

    float weight = pow(p.z, weightExponent);
    float3 color = diskTex.sample(diskSampler, p.xy).rgb;

    uint index = gid.y * w + gid.x;
    float4 previous = accum[index];
    accum[index] = float4(previous.rgb + color * weight, previous.a + weight);
    bestCosine[index] = max(bestCosine[index], p.z);
}

// ---------------------------------------------------------------------------
// Step 2: normalize the mosaic and emit the coverage mask alongside it.
//
// Coverage is judged on the BEST viewing angle any single exposure achieved, not
// on the accumulated weight. Accumulated weight is intrinsically latitude-
// dependent - a point at 70 degrees latitude is never seen face-on from the
// ecliptic, so its cos^k weights are always small - and thresholding it against a
// constant threw away every well-observed mid-latitude pixel along with the
// genuinely unobserved polar caps. Best-cosine asks the question we actually care
// about: did any exposure ever get a decent look at this point?
//
// Pixels below `minCosine` come out black here; `fillPolarCaps` on the CPU
// resolves them afterwards, since that needs a per-column search for the coverage
// boundary that does not map well onto a kernel.
// ---------------------------------------------------------------------------
kernel void normalizeMosaic(
    device const float4 *accum          [[buffer(0)]],
    device const float  *bestCosine     [[buffer(1)]],
    texture2d<float, access::write>  outTex      [[texture(0)]],
    texture2d<float, access::write>  coverageTex [[texture(1)]],
    constant float &minCosine            [[buffer(2)]], // below this, no usable data at all
    constant float &goodCosine           [[buffer(3)]], // at or above this, trust the mosaic fully
    uint2 gid [[thread_position_in_grid]])
{
    uint w = outTex.get_width();
    uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    uint index = gid.y * w + gid.x;
    float4 a = accum[index];

    float3 mosaic = a.rgb / max(a.a, 1e-6f);
    float t = smoothstep(minCosine, goodCosine, bestCosine[index]);

    outTex.write(float4(mosaic, 1.0f), gid);
    coverageTex.write(float4(t, t, t, 1.0f), gid);
}
"""

// MARK: - Disk Geometry Detection

extension SwiftDKNI {

    /// Locates the solar limb so the projection adapts to whatever plate scale the
    /// source product uses. Radius is returned normalized separately by width and
    /// height so the projection survives a non-square source image.
    ///
    /// Intensity thresholding does not work here. In the EUV bands the off-disk
    /// corona is far brighter than any sane black level, so a threshold scan finds
    /// the outer edge of the corona instead of the limb - measured at 0.41-0.43 of
    /// the frame width against a true limb near 0.39, which stretched the map and
    /// smeared coronal streamers across the photosphere.
    ///
    /// Instead, average luminance over annuli about the frame centre. Coronal
    /// structure is patchy so it averages down, while the limb is a perfect circle
    /// and reinforces: the profile shows limb brightening peaking at the limb and
    /// then dropping steeply. The steepest drop is the limb. Measured across 171 and
    /// 193 exposures this is repeatable to about 0.1%.
    ///
    /// The frame centre is assumed to be the disk centre, which holds for SDO's
    /// rendered full-disk products. If it ever stopped holding, the azimuthal
    /// average would smear the limb signature and the sanity clamp below would fire.
    internal func detectDiskGeometry(rgba: [UInt8], width: Int, height: Int)
        -> (centerX: Float, centerY: Float, radiusX: Float, radiusY: Float) {

        // Pull 1.5% inside the detected limb: the gradient minimum sits a touch
        // outside the true limb (it is the midpoint of the falloff), and bilinear
        // sampling should never reach the limb-brightening ring.
        let limbInset: Float = 0.985

        // The limb sits in here for every SDO full-disk product we consume
        let span = max(2, width / 256) // slope is measured across this, to ride out JPEG noise
        let searchLow = Int(Float(width) * 0.30)
        let searchHigh = min(Int(Float(width) * 0.47), min(width, height) / 2 - 1)

        // Annuli are accumulated a span wider than the search window on each side so
        // every slope evaluation reads a fully populated bin. Without this, the bin at
        // the very edge of the accumulation range collects almost no pixels, and the
        // resulting phantom cliff from a populated bin down to ~zero outbid the real
        // limb (it put the 193 limb at 0.46 of the frame instead of 0.39).
        let binLow = max(0, searchLow - span - 1)
        let binHigh = min(searchHigh + span + 1, min(width, height) / 2 - 1)

        func fallbackGeometry() -> (Float, Float, Float, Float) {
            // SDO AIA renders the solar radius at ~0.391 of the frame width
            let radius = Float(width) * 0.391 * limbInset
            return (0.5, 0.5, radius / Float(width), radius / Float(height))
        }

        guard searchHigh > searchLow + 8, binHigh > searchHigh else { return fallbackGeometry() }

        let centreX = Float(width) * 0.5
        let centreY = Float(height) * 0.5

        var sums = [Double](repeating: 0, count: binHigh + 1)
        var counts = [Int](repeating: 0, count: binHigh + 1)

        // Only the annulus containing the limb matters, so skip the disk interior
        let lowSquared = Float(binLow * binLow)
        let highSquared = Float((binHigh + 1) * (binHigh + 1))

        for y in 0..<height {
            let dy = Float(y) + 0.5 - centreY
            let dySquared = dy * dy
            if dySquared > highSquared { continue }
            for x in 0..<width {
                let dx = Float(x) + 0.5 - centreX
                let distanceSquared = dx * dx + dySquared
                if distanceSquared < lowSquared || distanceSquared > highSquared { continue }
                let radius = Int(sqrt(distanceSquared))
                guard radius >= binLow, radius <= binHigh else { continue }
                let i = (y * width + x) * 4
                let luma = (Double(rgba[i]) * 299 + Double(rgba[i + 1]) * 587 + Double(rgba[i + 2]) * 114) / 1000.0
                sums[radius] += luma
                counts[radius] += 1
            }
        }

        var means = [Float](repeating: 0, count: binHigh + 1)
        for radius in binLow...binHigh where counts[radius] > 0 {
            means[radius] = Float(sums[radius] / Double(counts[radius]))
        }

        // Steepest negative slope wins
        var bestRadius = -1
        var bestSlope: Float = 0
        for radius in searchLow...searchHigh {
            let outer = radius + span
            let inner = radius - span
            guard counts[outer] > 0, counts[inner] > 0 else { continue }
            let slope = means[outer] - means[inner]
            if slope < bestSlope {
                bestSlope = slope
                bestRadius = radius
            }
        }

        guard bestRadius > 0 else {
            print("SolarTextureReprojector: no limb falloff found, using nominal plate scale")
            return fallbackGeometry()
        }

        let radius = Float(bestRadius) * limbInset
        let fraction = radius / Float(width)
        if fraction < 0.30 || fraction > 0.47 {
            print("SolarTextureReprojector: limb fit out of range (\(fraction)), using nominal plate scale")
            return fallbackGeometry()
        }

        return (0.5, 0.5, radius / Float(width), radius / Float(height))
    }
}

// MARK: - Shared Metal Helpers

/// Output dimensions and mosaic tuning for the surface texture pipeline.
internal enum SolarCompositeSettings {
    /// Equirectangular output size. Matches the sunspot mask so the baked
    /// composite needs no resampling.
    static let mapWidth = 4096
    static let mapHeight = 2048

    /// Number of disk exposures sampled across the trailing rotation.
    /// Each sample must cover 360/N degrees of longitude, so fewer samples means
    /// more foreshortening blur at the joins and a bigger time jump across them:
    ///   N=3  -> +/-60 deg reach, 2.0x stretch,   9.3-day seams
    ///   N=7  -> +/-25.7 deg,     1.11x stretch,  4.0-day seams
    ///   N=10 -> +/-18 deg,       1.05x stretch,  2.7-day seams
    ///   N=28 -> +/-6.6 deg,      1.007x stretch, 1.0-day seams
    static let sampleCount = 10

    /// Source disk resolution to fetch. 2048px is ~489 KB and comfortably
    /// oversamples an 18-degree strip; 4096px is 1.9 MB for no visible gain.
    static let sampleResolution = 2048

    /// Cosine-weight exponent. Higher values trust face-on data more strongly.
    static let weightExponent: Float = 4.0

    /// Reject samples closer to the limb than this cosine (~76 degrees out).
    static let minCosine: Float = 0.24

    /// Best viewing angle at which a pixel counts as properly observed
    /// (~63 degrees from disk centre). Between `minCosine` and this, the mosaic
    /// ramps into the extrapolated polar cap. With B0 near its +7.25 degree extreme
    /// this puts the fade-out around 75 degrees latitude on the tilted-toward pole
    /// and around 70 degrees on the tilted-away one, which is the real observability
    /// limit rather than an arbitrary cutoff.
    static let goodCosine: Float = 0.45

    /// Synodic rotation period in days.
    static let rotationPeriodDays = 27.2753
}

/// Uploads a decoded disk image as a sampleable Metal texture.
internal func makeDiskTexture(device: MTLDevice, rgba: [UInt8], width: Int, height: Int) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    rgba.withUnsafeBytes { ptr in
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: width * 4)
    }
    return texture
}

/// Compiles the shared reprojection kernel library.
internal func makeReprojectionLibrary(device: MTLDevice) -> MTLLibrary? {
    do {
        return try device.makeLibrary(source: diskToEquirectKernelSource, options: nil)
    } catch {
        print("SolarTextureReprojector: kernel compilation failed: \(error.localizedDescription)")
        return nil
    }
}

// MARK: - Shared Image Helpers

internal func extractCGImage(_ image: XImage) -> CGImage? {
#if os(macOS)
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
#else
    return image.cgImage
#endif
}

internal func xImage(from cgImage: CGImage) -> XImage {
#if os(macOS)
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
#else
    return UIImage(cgImage: cgImage)
#endif
}

/// Decodes any CGImage into a flat RGBA8 byte array.
internal func rgbaBytes(from cgImage: CGImage) -> ([UInt8], Int, Int) {
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    bytes.withUnsafeMutableBytes { ptr in
        if let context = CGContext(data: ptr.baseAddress, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: colorSpace, bitmapInfo: bitmapInfo) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    return (bytes, width, height)
}

/// Builds a CGImage from a flat RGBA8 byte array.
internal func makeRGBACGImage(bytes: inout [UInt8], width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    return bytes.withUnsafeMutableBytes { ptr -> CGImage? in
        guard let context = CGContext(data: ptr.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        return context.makeImage()
    }
}

/// Extracts a grayscale [UInt8] activity map from an equirectangular image.
/// This is the buffer consumed by the CPU topological warp and the geometry shader map.
internal func grayscaleActivityMap(from cgImage: CGImage) -> ([UInt8], Int, Int) {
    let width = cgImage.width
    let height = cgImage.height
    var rawData = [UInt8](repeating: 0, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    rawData.withUnsafeMutableBytes { ptr in
        if let context = CGContext(data: ptr.baseAddress, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width,
                                   space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    return (rawData, width, height)
}

/// Documents-level stars/ directory shared by all pipeline caches and debug dumps.
internal func starsDirectoryURL() -> URL {
    let fileManager = FileManager.default
    let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let starsURL = docsDir.appendingPathComponent("stars")
    if !fileManager.fileExists(atPath: starsURL.path) {
        try? fileManager.createDirectory(at: starsURL, withIntermediateDirectories: true, attributes: nil)
    }
    return starsURL
}

/// Writes a CGImage to disk as JPEG (debug dump / cache pattern shared with magnetogram_debug.jpg).
internal func writeJPEG(_ cgImage: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        print("SolarTextureReprojector: Failed to create JPEG destination at \(url.lastPathComponent)")
        return
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
}

/// Bakes the 171/193 multi-band solar composite once on the CPU so the surface
/// shader doesn't recompute it per fragment every frame.
///
/// Stored value = (color193 + color171 * smoothstep(0.4, 0.8, luma171)) / 2
/// The /2 keeps the additive 0..2 range inside 8 bits; the shader rescales by 2.
/// The sunspot multiply intentionally stays in the shader (ambient channel).
internal func bakeSolarSurfaceComposite(basePlasma: XImage, coronalHoles: XImage) -> XImage? {
    guard let baseCG = extractCGImage(basePlasma),
          let holesCGRaw = extractCGImage(coronalHoles) else { return nil }

    let width = baseCG.width
    let height = baseCG.height

    // The two sources can differ in resolution (reprojected 4096x2048 vs synoptic 2048x1024);
    // normalize the 193 layer onto the 171 grid before compositing.
    let holesCG: CGImage
    if holesCGRaw.width == width && holesCGRaw.height == height {
        holesCG = holesCGRaw
    } else if let resampled = resampleImage(holesCGRaw, width: width, height: height) {
        holesCG = resampled
    } else {
        holesCG = holesCGRaw
    }
    guard holesCG.width == width, holesCG.height == height else { return nil }

    let startTime = CFAbsoluteTimeGetCurrent()
    let (base, _, _) = rgbaBytes(from: baseCG)
    let (holes, _, _) = rgbaBytes(from: holesCG)

    var output = [UInt8](repeating: 255, count: width * height * 4)
    output.withUnsafeMutableBufferPointer { outBuf in
        base.withUnsafeBufferPointer { baseBuf in
            holes.withUnsafeBufferPointer { holesBuf in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let rowStart = y * width * 4
                    for x in 0..<width {
                        let i = rowStart + x * 4

                        let r171 = Float(baseBuf[i]) / 255.0
                        let g171 = Float(baseBuf[i + 1]) / 255.0
                        let b171 = Float(baseBuf[i + 2]) / 255.0

                        let r193 = Float(holesBuf[i]) / 255.0
                        let g193 = Float(holesBuf[i + 1]) / 255.0
                        let b193 = Float(holesBuf[i + 2]) / 255.0

                        // Mask 171: only add where it is intensely bright (the active loops),
                        // preserving the dark coronal holes of the 193 base.
                        let luma171 = r171 * 0.299 + g171 * 0.587 + b171 * 0.114
                        var t = (luma171 - 0.4) / 0.4
                        t = max(0.0, min(1.0, t))
                        let mask = t * t * (3.0 - 2.0 * t) // smoothstep(0.4, 0.8, luma171)

                        // Composite at half scale to fit the 0..2 additive range into 8 bits
                        let r = (r193 + r171 * mask) * 0.5
                        let g = (g193 + g171 * mask) * 0.5
                        let b = (b193 + b171 * mask) * 0.5

                        outBuf[i]     = UInt8(max(0.0, min(1.0, r)) * 255.0)
                        outBuf[i + 1] = UInt8(max(0.0, min(1.0, g)) * 255.0)
                        outBuf[i + 2] = UInt8(max(0.0, min(1.0, b)) * 255.0)
                        outBuf[i + 3] = 255
                    }
                }
            }
        }
    }

    guard let outCG = makeRGBACGImage(bytes: &output, width: width, height: height) else { return nil }
    print("bakeSolarSurfaceComposite: baked \(width)x\(height) composite in \(CFAbsoluteTimeGetCurrent() - startTime)s")

    // Debug dump for eyeball inspection of the final emission source
    writeJPEG(outCG, to: starsDirectoryURL().appendingPathComponent("baked_composite_debug.jpg"))

    return xImage(from: outCG)
}

/// Dumps a grayscale byte buffer as a JPG into stars/ for visual inspection.
internal func dumpGrayscaleDebugJPEG(_ bytes: [UInt8], width: Int, height: Int, fileName: String) {
    var mutableBytes = bytes
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let cgImage: CGImage? = mutableBytes.withUnsafeMutableBytes { ptr -> CGImage? in
        guard let context = CGContext(data: ptr.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        return context.makeImage()
    }
    if let image = cgImage {
        writeJPEG(image, to: starsDirectoryURL().appendingPathComponent(fileName))
        print("SolarTextureReprojector: Dumped debug map to stars/\(fileName)")
    }
}
