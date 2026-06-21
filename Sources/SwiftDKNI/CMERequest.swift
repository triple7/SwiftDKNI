//
//  CMERequest.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//


import Foundation

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
}
