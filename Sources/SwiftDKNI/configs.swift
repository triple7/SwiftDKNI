//
//  StellarConfig.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 9/8/2026.
//

import SceneKit
import simd

import SceneKit

public struct StellarConfig: Codable {
    public var energyTunnelConfig: EnergyTunnelConfig
    public var cmeConfig: CMEConfig
    
    public init(
        energyTunnelConfig: EnergyTunnelConfig = EnergyTunnelConfig(),
        cmeConfig: CMEConfig = CMEConfig()
    ) {
        self.energyTunnelConfig = energyTunnelConfig
        self.cmeConfig = cmeConfig
    }
}

public struct EnergyTunnelConfig: Codable {
    public var tunnelRadiusBase: Float = 0.005
    public var particleBaseSize: Float = 0.08
    public var particleVariance: Float = 0.02
    
    public var warpIntensity: Float = 0.05
    public var boilSpeed: Float = 2.0
    public var twinkleSpeed: Float = 15.0
    
    public var coreColor: SCNVector3 = SCNVector3(1.0, 0.85, 0.0)
    public var midColor: SCNVector3 = SCNVector3(1.0, 0.35, 0.0)
    public var edgeColor: SCNVector3 = SCNVector3(0.4, 0.02, 0.0)
    
    public var hdrMultiplier: Float = 0.8
    
    public init() {}
    
    // MARK: - Codable Conformance for SCNVector3
    
    enum CodingKeys: String, CodingKey {
        case tunnelRadiusBase, particleBaseSize, particleVariance
        case warpIntensity, boilSpeed, twinkleSpeed
        case coreColor, midColor, edgeColor
        case hdrMultiplier
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        tunnelRadiusBase = try container.decode(Float.self, forKey: .tunnelRadiusBase)
        particleBaseSize = try container.decode(Float.self, forKey: .particleBaseSize)
        particleVariance = try container.decode(Float.self, forKey: .particleVariance)
        
        warpIntensity = try container.decode(Float.self, forKey: .warpIntensity)
        boilSpeed = try container.decode(Float.self, forKey: .boilSpeed)
        twinkleSpeed = try container.decode(Float.self, forKey: .twinkleSpeed)
        
        hdrMultiplier = try container.decode(Float.self, forKey: .hdrMultiplier)
        
        // Decode SCNVector3 as Float arrays
        let coreArray = try container.decode([Float].self, forKey: .coreColor)
        coreColor = SCNVector3(coreArray[0], coreArray[1], coreArray[2])
        
        let midArray = try container.decode([Float].self, forKey: .midColor)
        midColor = SCNVector3(midArray[0], midArray[1], midArray[2])
        
        let edgeArray = try container.decode([Float].self, forKey: .edgeColor)
        edgeColor = SCNVector3(edgeArray[0], edgeArray[1], edgeArray[2])
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(tunnelRadiusBase, forKey: .tunnelRadiusBase)
        try container.encode(particleBaseSize, forKey: .particleBaseSize)
        try container.encode(particleVariance, forKey: .particleVariance)
        
        try container.encode(warpIntensity, forKey: .warpIntensity)
        try container.encode(boilSpeed, forKey: .boilSpeed)
        try container.encode(twinkleSpeed, forKey: .twinkleSpeed)
        
        try container.encode(hdrMultiplier, forKey: .hdrMultiplier)
        
        // Encode SCNVector3 as Float arrays for safe serialization
        try container.encode([Float(coreColor.x), Float(coreColor.y), Float(coreColor.z)], forKey: .coreColor)
        try container.encode([Float(midColor.x), Float(midColor.y), Float(midColor.z)], forKey: .midColor)
        try container.encode([Float(edgeColor.x), Float(edgeColor.y), Float(edgeColor.z)], forKey: .edgeColor)
    }
}

public struct CMEConfig: Codable {
    // Timeline constraints
    public var visualLoopDuration: Double = 10.0
    public var globalTime: Float = -1.0
    public var scnFrameTimeSnapshot: Float = 0.0
    
    // Physics and Deformation
    public var warpIntensity: Float = 0.025
    public var thickness: Float = 0.3
    public var ejectionMultiplier: Float = 1000.0
    
    // Fallbacks for missing API event data
    public var defaultSpeed: Float = 400.0
    public var defaultHalfAngle: Float = 20.0
    
    public init() {}
}

