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
    
    public func fetchLatestImage(wavelength: SDOWavelength, resolution: Int = 2048, cachedIfExists: Bool = true) async throws -> XImage? {
            print("NASASDOService-fetchLatestImage: getting NASA surface image - wavelength \(wavelength) resolution \(resolution)")
            
            let fileName = "latest_\(resolution)_\(wavelength.rawValue).jpg"
            let urlString = "https://sdo.gsfc.nasa.gov/assets/img/latest/\(fileName)"
            
            guard let url = URL(string: urlString) else {
                throw URLError(.badURL)
            }
            
            let fileManager = FileManager.default
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let starsDirectoryURL = documentsURL.appendingPathComponent("stars")
            let cacheURL = starsDirectoryURL.appendingPathComponent(fileName)
            
            var rawData: Data? = nil
            
            // 1. Check the local cache if requested
            if cachedIfExists && fileManager.fileExists(atPath: cacheURL.path) {
                do {
                    rawData = try Data(contentsOf: cacheURL)
                    print("NASASDOService: Loaded image from cache at \(fileName)")
                } catch {
                    print("NASASDOService: Failed to load cached image: \(error), falling back to network.")
                }
            }
            
            // 2. Perform the Network Request if we don't have cached data
            if rawData == nil {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                // Validate the response
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                     print("NASASDOService: Bad response \(httpResponse.statusCode)")
                     throw URLError(.badServerResponse)
                }
                
                rawData = data
                
                // Save the newly fetched image to the cache
                do {
                    // Ensure the 'stars' directory exists before writing
                    if !fileManager.fileExists(atPath: starsDirectoryURL.path) {
                        try fileManager.createDirectory(at: starsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                    }
                    try data.write(to: cacheURL)
                    print("NASASDOService: Saved newly fetched image to cache (\(fileName)).")
                } catch {
                    print("NASASDOService: Failed to cache image: \(error)")
                }
            }
            
            guard let validData = rawData else {
                return nil
            }
            
            return XImage(data: validData)
        }
}
