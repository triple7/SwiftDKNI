//
//  DONKIService.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//

import Foundation

final public class DONKIService: Sendable {
    
    /// Fetches CME events and returns a list of averaged geometries.
    func fetchAndAverageCMEData(request: CMERequest) async throws -> [AveragedCMEData] {
        
        // 1. Construct the URL
        let baseURLString = "https://api.nasa.gov/DONKI/CME"
        guard var components = URLComponents(string: baseURLString) else {
            throw CMEFetcherError.invalidURL
        }
        
        // Grab the base date query items from your struct
        var items = request.queryItems
        
        // THE FIX: Explicitly append the API key using NASA's exact parameter name ("api_key")
        items.append(URLQueryItem(name: "api_key", value: request.apiKey))
        
        // Assign the complete array back to the components
        components.queryItems = items
        
        guard let url = components.url else {
            throw CMEFetcherError.invalidURL
        }
        
        // 2. Perform the Network Request
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let badResponse = response as? HTTPURLResponse
            print("HTTP Error: \(badResponse?.statusCode ?? -1)")
            // If you hit a 429 again, print the URL to verify the key is attached
            print("Failed URL was: \(url.absoluteString)")
            throw CMEFetcherError.noData
        }
        
        // 3. Decode the Payload
        if let jsonString = String(data: data, encoding: .utf8) {
//            print("--- RAW JSON RESPONSE ---")
//            print(jsonString)
//            print("-------------------------")
        } else {
            print("DEBUG: Could not convert data to UTF-8 string.")
        }

        let decoder = JSONDecoder()
        let events: [CMEEvent]
        do {
            events = try decoder.decode([CMEEvent].self, from: data)
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
