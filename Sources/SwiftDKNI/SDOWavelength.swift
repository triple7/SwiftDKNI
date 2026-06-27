//
//  SDOWavelength.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 27/6/2026.
//


import Foundation

// NASA SDO observes the sun in multiple extreme ultraviolet wavelengths.
// Each wavelength highlights a different physical layer and temperature of the plasma.
public enum SDOWavelength: String {
    case aia171 = "0171"        // Gold/Yellow: Classic coronal loops and magnetic arches
    case aia193 = "0193"        // Bronze: Highlights massive, dark Coronal Holes
    case aia304 = "0304"        // Neon Red: The Chromosphere, great for violent surface flares
    case hmiContinuum = "HMIIF" // White/Orange: The visible photosphere (shows sunspots perfectly)
}

public class NASASDOService {
    public init() {}
    
    public func fetchLatestImage(wavelength: SDOWavelength, resolution: Int = 2048) async throws -> XImage? {
        print("fetchLatestImage: getting NASA surface image - wavelength \(wavelength) resolution \(resolution)")
        // NASA's live image endpoint. Available resolutions: 512, 1024, 2048, 4096
        let urlString = "https://sdo.gsfc.nasa.gov/assets/img/latest/latest_\(resolution)_\(wavelength.rawValue).jpg"
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        return XImage(data: data)
    }
}
