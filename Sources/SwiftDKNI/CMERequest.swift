//
//  CMERequest.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//


import Foundation

// MARK: - DONKI Errors
enum DONKIError: Error, LocalizedError {
    case invalidURL
    case serverError(statusCode: Int)
    case maxRetriesExceeded(lastError: Error?)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The constructed URL is invalid."
        case .serverError(let code): return "NASA Server returned an HTTP \(code) error."
        case .maxRetriesExceeded(let err): return "Max retries exceeded. Last error: \(err?.localizedDescription ?? "Unknown")"
        }
    }
}

// MARK: - DONKI Request Configuration
/// DONKI uses a GET request, so parameters are passed as URL queries rather than a JSON body.
struct CMERequest {
    /// Format: yyyy-MM-dd
    let startDate: String
    /// Format: yyyy-MM-dd
    let endDate: String
    let apiKey: String
    
    var queryItems: [URLQueryItem] {
        return [
            URLQueryItem(name: "startDate", value: startDate),
            URLQueryItem(name: "endDate", value: endDate),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
    }
    
    // Helper to automatically construct the URL using the query items
    var url: URL? {
        var components = URLComponents(string: "https://api.nasa.gov/DONKI/CME")
        components?.queryItems = queryItems
        return components?.url
    }
}

// MARK: - Resilient DONKI Client
class CMEFetcher {
    
    /// Fetches CME data with an exponential backoff retry mechanism to bypass transient 503 errors.
    /// - Parameters:
    ///   - request: The configured CMERequest payload.
    ///   - maxRetries: Maximum number of retry attempts (default is 3).
    ///   - baseDelay: The initial delay in seconds before the first retry.
    func fetchWithBackoff(request: CMERequest, maxRetries: Int = 3, baseDelay: Double = 1.0) async throws -> Data {
        guard let url = request.url else {
            throw DONKIError.invalidURL
        }
        
        var lastError: Error?
        
        // Loop from 0 up to maxRetries
        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw DONKIError.serverError(statusCode: 0)
                }
                
                // If successful, return the raw JSON data immediately
                if httpResponse.statusCode == 200 {
                    return data
                }
                
                // If it's a 4xx error (like 403 Invalid API Key), fail completely.
                // Retrying won't fix a bad credential or a malformed request (except 429 Too Many Requests).
                if (400...499).contains(httpResponse.statusCode) && httpResponse.statusCode != 429 {
                    throw DONKIError.serverError(statusCode: httpResponse.statusCode)
                }
                
                // For 5xx errors (NASA server down) or 429 (Rate Limit), throw to trigger the catch block & retry
                throw DONKIError.serverError(statusCode: httpResponse.statusCode)
                
            } catch {
                lastError = error
                
                // If we've hit our maximum allowed attempts, break the loop and throw the final error
                if attempt == maxRetries {
                    break
                }
                
                // Calculate exponential backoff: baseDelay * (2 ^ attempt)
                // Attempt 0: waits 1.0s
                // Attempt 1: waits 2.0s
                // Attempt 2: waits 4.0s
                let delay = baseDelay * pow(2.0, Double(attempt))
                
                #if DEBUG
                print("⚠️ DONKI fetch failed. Retrying in \(delay) seconds... (Attempt \(attempt + 1)/\(maxRetries))")
                #endif
                
                // Suspend the current task for the calculated duration (Task.sleep expects nanoseconds)
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        }
        
        throw DONKIError.maxRetriesExceeded(lastError: lastError)
    }
}
