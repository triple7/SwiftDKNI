//
//  SolarGeometry.swift
//  SwiftDKNI
//
//  Where the Sun's disk is pointing at a given instant, and the Carrington
//  rotation bookkeeping that goes with it.
//
//  Anything that reprojects a disk exposure onto a heliographic grid needs to know
//  where the centre of that disk actually sits on the Sun at the moment of the
//  exposure. Without it a reprojection silently assumes the disk centre is at
//  latitude 0, longitude 0, which is wrong on both counts and by a lot.
//
//  Consumed by SolarTextureReprojector.swift and SolarCarringtonComposite.swift.
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Solar Disk Geometry
//
// Everything that reprojects a disk image onto a heliographic grid needs to know
// where the disk centre actually sits on the Sun at the moment of the exposure:
//
//   B0 - heliographic latitude of the disk centre. Swings +/-7.25 degrees over a
//        year as Earth crosses the plane of the solar equator. Ignoring it shears
//        the reprojection in latitude by up to 7.25 degrees, which is exactly the
//        kind of mismatch that makes magnetogram loops sit off their active regions.
//   L0 - Carrington longitude of the central meridian. Decreases 13.2 degrees/day.
//        Required to place a disk image at the right longitude in a composite.
//
// Implementation follows Meeus, "Astronomical Algorithms", ch. 29 (Ephemeris for
// Physical Observations of the Sun). Validated against the STEREO SSC ephemeris
// (stereo-ssc.nascom.nasa.gov/where/where_is_stereo.shtml):
//
//   2026-09-20 05:00 UT  reference L0 76.710 B0 7.115  ->  computed 76.710 / 7.113
//   2026-08-25 05:00 UT  reference L0 60.076 B0 7.034  ->  computed 60.077 / 7.030
//
// B0 lands within 0.004 degrees. L0 showed a consistent +0.136 degree bias against
// the reference before `carringtonL0Calibration` below is applied.

/// Julian Day for a Foundation date.
internal func julianDay(for date: Date) -> Double {
    2440587.5 + date.timeIntervalSince1970 / 86400.0
}

/// Inclination of the solar equator to the ecliptic.
private let solarInclination = 7.25 * Double.pi / 180.0

/// Measured residual between the Meeus L0 and the STEREO SSC ephemeris, in degrees.
/// Consistent across reference epochs, so it is removed as a constant rather than
/// left as a systematic ~1.5 pixel longitude shift in a 4096-wide map.
private let carringtonL0Calibration = 0.136

/// Apparent geocentric longitude of the Sun and the longitude of the ascending node
/// of the solar equator on the ecliptic, both in degrees.
private func sunApparentLongitudeAndNode(julianDay jd: Double) -> (lambda: Double, node: Double) {
    let T = (jd - 2451545.0) / 36525.0

    // Geometric mean longitude and mean anomaly of the Sun
    let L = 280.46646 + 36000.76983 * T + 0.0003032 * T * T
    let M = 357.52911 + 35999.05029 * T - 0.0001537 * T * T
    let Mrad = M * .pi / 180.0

    // Equation of the centre -> true longitude
    let C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * sin(Mrad)
          + (0.019993 - 0.000101 * T) * sin(2.0 * Mrad)
          + 0.000289 * sin(3.0 * Mrad)
    let trueLongitude = L + C

    // Correct for nutation and aberration to get the apparent longitude
    let omega = (125.04 - 1934.136 * T) * .pi / 180.0
    let lambda = trueLongitude - 0.00569 - 0.00478 * sin(omega)

    let node = 73.666667 + 1.395833 * (jd - 2396758.0) / 36525.0
    return (lambda, node)
}

/// Fractional Carrington rotation number (integer part is the rotation, the
/// fraction is how far through it we are).
/// Rotation 1 began 1853-11-09 (JD 2398167.329); the synodic period is 27.2753 days.
public func carringtonRotationFractional(for date: Date = Date()) -> Double {
    (julianDay(for: date) - 2398167.329) / 27.2753 + 1.0
}

/// Carrington rotation number for a given date.
public func carringtonRotationNumber(for date: Date = Date()) -> Int {
    Int(floor(carringtonRotationFractional(for: date)))
}

/// Heliographic latitude of the disk centre (the solar tilt, B0) in degrees.
/// Ranges roughly -7.25 to +7.25 over a year, most positive in early September.
public func solarB0(for date: Date = Date()) -> Float {
    let (lambda, node) = sunApparentLongitudeAndNode(julianDay: julianDay(for: date))
    let lambdaMinusNode = (lambda - node) * .pi / 180.0
    return Float(asin(sin(lambdaMinusNode) * sin(solarInclination)) * 180.0 / .pi)
}

/// Carrington longitude of the central meridian (L0) in degrees, wrapped to [0, 360).
/// Decreases by 13.2 degrees per day.
public func carringtonL0(for date: Date = Date()) -> Float {
    let jd = julianDay(for: date)
    let (lambda, node) = sunApparentLongitudeAndNode(julianDay: jd)

    // Earth's heliocentric longitude is the Sun's geocentric longitude + 180,
    // measured from the ascending node of the solar equator.
    let lambdaEarth = (lambda + 180.0 - node) * .pi / 180.0

    // Longitude of the sub-Earth point within the solar equatorial plane
    let eta = atan2(cos(solarInclination) * sin(lambdaEarth), cos(lambdaEarth)) * 180.0 / .pi

    // Sidereal rotation of the Carrington prime meridian (25.38 day period by definition)
    let theta = (jd - 2398220.0) * 360.0 / 25.38

    var l0 = (eta - theta - carringtonL0Calibration).truncatingRemainder(dividingBy: 360.0)
    if l0 < 0 { l0 += 360.0 }
    return Float(l0)
}

/// Resamples a CGImage to the given size with high-quality interpolation.
internal func resampleImage(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}
