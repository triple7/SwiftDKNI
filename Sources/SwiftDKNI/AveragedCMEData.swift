//
//  AveragedCMEData.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//


import Foundation

/// The finalized, averaged data ready to be passed to the SceneKit/Metal rendering pipeline.
public struct AveragedCMEData {
    let activityID: String
    let startTime: String
    
    // Core parameters averaged across accurate instrument readings
    let latitude: Double?
    let longitude: Double?
    let halfAngle: Double
    let speed: Double
}

public enum CMEFetcherError: Error {
    case invalidURL
    case noData
    case decodingFailed(Error)
}
