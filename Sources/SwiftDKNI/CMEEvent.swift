//
//  CMEEvent.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//


import Foundation

// MARK: - DONKI Response Models
/// The top-level object returned in the JSON array from NASA DONKI.
public struct CMEEvent: Codable {
    let activityID: String
    let catalog: String
    let startTime: String
    let sourceLocation: String?
    let activeRegionNum: Int?
    let link: String
    let note: String
    let instruments: [Instrument]?
    
    /// This array contains the actual 3D geometry parameters needed for SceneKit
    let cmeAnalyses: [CMEAnalysis]?
    let linkedEvents: [LinkedEvent]?
}

public struct Instrument: Codable {
    let displayName: InstrumentType
}

/// The specific geometric and kinematic data of the ejection
public struct CMEAnalysis: Codable {
    let isMostAccurate: Bool?
    let time21_5: String?
    
    // Core parameters for 3D rendering
    let latitude: Double?
    let longitude: Double?
    let halfAngle: Double?
    let speed: Double?
    
    let type: String?
    let note: String?
    let levelOfData: Int?
}

public struct LinkedEvent: Codable {
    let activityID: String
}


extension AveragedCMEData {
    var parsedDate: Date? {
        let dateString = self.startTime
        
        // 1. Try the strict ISO8601 standard first
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let strictDate = isoFormatter.date(from: dateString) {
            return strictDate
        }
        
        // 2. Fallback: NASA frequently drops the seconds (e.g., "2026-06-10T14:32Z")
        let backupFormatter = DateFormatter()
        backupFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        backupFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        let finalDate = backupFormatter.date(from: dateString)
        
        // Quick console check to warn you if data is still failing
        if finalDate == nil {
            print("⚠️ WARNING: Failed to parse DONKI date: \(dateString)")
        }
        
        return finalDate
    }
}

