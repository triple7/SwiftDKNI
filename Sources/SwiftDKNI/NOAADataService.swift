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
    
    public func fetchActiveRegions() async throws -> [SWPCRegion] {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // NOAA data is relatively flat, straightforward decoding
        let decoder = JSONDecoder()
        let regions = try decoder.decode([SWPCRegion].self, from: data)
        
        return regions
    }
}
