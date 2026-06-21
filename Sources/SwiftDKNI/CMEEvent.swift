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
