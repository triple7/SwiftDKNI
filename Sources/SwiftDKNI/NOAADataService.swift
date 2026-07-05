//
//  NOAADataService.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 27/6/2026.
//

import Foundation

public class NOAADataService {
    // NOAA's live JSON endpoint for current active solar regions
    private let endpoint = "https://services.swpc.noaa.gov/json/solar_regions.json"
    
    public init() {}
    
    public func fetchActiveRegions(cachedIfExists: Bool = true) async throws -> [SWPCRegion] {
            guard let url = URL(string: endpoint) else {
                throw URLError(.badURL)
            }
            
            let fileManager = FileManager.default
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let starsDirectoryURL = documentsURL.appendingPathComponent("stars")
            let cacheURL = starsDirectoryURL.appendingPathComponent("NOAAActiveRegions.json")
            
            var rawData: Data? = nil
            
            // 1. Check the local cache if requested
            if cachedIfExists && fileManager.fileExists(atPath: cacheURL.path) {
                do {
                    rawData = try Data(contentsOf: cacheURL)
                    print("NOAADataService: Loaded active regions from cache at \(cacheURL.lastPathComponent)")
                } catch {
                    print("NOAADataService: Failed to load cached data: \(error), falling back to network.")
                }
            }
            
            // 2. Perform the Network Request if we don't have cached data
            if rawData == nil {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                // Validate the response to ensure we don't cache a 503 error page
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                     print("NOAADataService: Bad response \(httpResponse.statusCode)")
                     throw URLError(.badServerResponse)
                }
                
                rawData = data
                
                // Save the newly fetched data to the cache
                do {
                    // Ensure the 'stars' directory exists before writing
                    if !fileManager.fileExists(atPath: starsDirectoryURL.path) {
                        try fileManager.createDirectory(at: starsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                    }
                    try data.write(to: cacheURL)
                    print("NOAADataService: Saved newly fetched active regions to cache.")
                } catch {
                    print("NOAADataService: Failed to cache active regions: \(error)")
                }
            }
            
            guard let validData = rawData else {
                throw URLError(.cannotParseResponse)
            }
            
            // 3. Decode the Data
            // NOAA data is relatively flat, straightforward decoding
            let decoder = JSONDecoder()
            let regions = try decoder.decode([SWPCRegion].self, from: validData)
            
            return regions
        }
    
}
