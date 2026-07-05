//
//  DONKIService.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//

import Foundation

final public class DONKIService: Sendable {
    
    /// Fetches CME events and returns a list of averaged geometries.
    func fetchAndAverageCMEData(request: CMERequest, cachedIfExists: Bool = true) async throws -> [AveragedCMEData] {
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let starsDirectoryURL = documentsURL.appendingPathComponent("stars")
        let cacheURL = starsDirectoryURL.appendingPathComponent("CMEEvents.json")
        
        var rawData: Data? = nil
        
        // 1. Check the local cache if requested
        if cachedIfExists && fileManager.fileExists(atPath: cacheURL.path) {
            do {
                rawData = try Data(contentsOf: cacheURL)
                print("SwiftDNKI: Loaded CME data from cache at \(cacheURL.lastPathComponent)")
            } catch {
                print("SwiftDNKI: Failed to load cached data: \(error), falling back to network.")
            }
        }
        
        // 2. Perform the Network Request if we don't have cached data
        if rawData == nil {
            let baseURLString = "https://api.nasa.gov/DONKI/CME"
            guard var components = URLComponents(string: baseURLString) else {
                throw CMEFetcherError.invalidURL
            }
            
            // Use the queryItems mapped directly from the struct
            components.queryItems = request.queryItems
            
            guard let url = components.url else {
                throw CMEFetcherError.invalidURL
            }
            
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let badResponse = response as? HTTPURLResponse
                print("No data: \(badResponse?.statusCode ?? 0)")
                throw CMEFetcherError.noData
            }
            
            rawData = data
            
            // Save the newly fetched data to the cache
            do {
                // Ensure the 'stars' directory exists before writing
                if !fileManager.fileExists(atPath: starsDirectoryURL.path) {
                    try fileManager.createDirectory(at: starsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                }
                try data.write(to: cacheURL)
                print("SwiftDNKI: Saved newly fetched CME data to cache.")
            } catch {
                print("SwiftDNKI: Failed to cache CME data: \(error)")
            }
        }
        
        guard let validData = rawData else {
            throw CMEFetcherError.noData
        }
        
        // 3. Decode the Data
        let decoder = JSONDecoder()
        let events: [CMEEvent]
        do {
            events = try decoder.decode([CMEEvent].self, from: validData)
        } catch {
            throw CMEFetcherError.decodingFailed(error)
        }
        
        // 4. Process and Average the Data
        print("SwiftDNKI: found \(events.count) events")
        var processedEvents: [AveragedCMEData] = []
        
        for event in events {
            guard let analyses = event.cmeAnalyses, !analyses.isEmpty else {
                continue // Skip events with no geometric data
            }
            
            // Filter strictly for analyses marked as most accurate
            let accurateAnalyses = analyses.filter { $0.isMostAccurate == true }
            
            // Fallback: If none are explicitly marked true, average all available analyses
            let targetAnalyses = accurateAnalyses.isEmpty ? analyses : accurateAnalyses
            
            var totalLat = 0.0
            var totalLon = 0.0
            var totalHalfAngle = 0.0
            var totalSpeed = 0.0
            var validDataPoints = 0.0
            
            for analysis in targetAnalyses {
                // Ensure all parameters exist before adding to the sum
                if let lat = analysis.latitude,
                   let lon = analysis.longitude,
                   let halfAngle = analysis.halfAngle,
                   let speed = analysis.speed {
                    
                    totalLat += lat
                    totalLon += lon
                    totalHalfAngle += halfAngle
                    totalSpeed += speed
                    validDataPoints += 1.0
                }
            }
            
            // If we have valid floating-point data, compute the mean average
            if validDataPoints > 0 {
                let averagedEvent = AveragedCMEData(
                    activityID: event.activityID,
                    startTime: event.startTime,
                    latitude: totalLat / validDataPoints,
                    longitude: totalLon / validDataPoints,
                    halfAngle: totalHalfAngle / validDataPoints,
                    speed: totalSpeed / validDataPoints
                )
                processedEvents.append(averagedEvent)
            }
        }
        
        return processedEvents
    }
}
