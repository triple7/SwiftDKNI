//
//  StellarConfig.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 9/8/2026.
//

import SceneKit
import simd

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
    
    // MARK: - Mutating Setters
    
    public mutating func setEnergyTunnelConfig(_ value: EnergyTunnelConfig) {
        self.energyTunnelConfig = value
    }
    
    public mutating func setCMEConfig(_ value: CMEConfig) {
        self.cmeConfig = value
    }
}

public struct EnergyTunnelConfig: Codable {
    public var particlesPerUnitLength: Float = 15.0
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
    
    // MARK: - Mutating Setters
    
    public mutating func setParticlesPerUnitLength(_ value: Float) {
        self.particlesPerUnitLength = value
    }
    
    public mutating func setTunnelRadiusBase(_ value: Float) {
        self.tunnelRadiusBase = value
    }
    
    public mutating func setParticleBaseSize(_ value: Float) {
        self.particleBaseSize = value
    }
    
    public mutating func setParticleVariance(_ value: Float) {
        self.particleVariance = value
    }
    
    public mutating func setWarpIntensity(_ value: Float) {
        self.warpIntensity = value
    }
    
    public mutating func setBoilSpeed(_ value: Float) {
        self.boilSpeed = value
    }
    
    public mutating func setTwinkleSpeed(_ value: Float) {
        self.twinkleSpeed = value
    }
    
    public mutating func setCoreColor(_ value: SCNVector3) {
        self.coreColor = value
    }
    
    public mutating func setMidColor(_ value: SCNVector3) {
        self.midColor = value
    }
    
    public mutating func setEdgeColor(_ value: SCNVector3) {
        self.edgeColor = value
    }
    
    public mutating func setHdrMultiplier(_ value: Float) {
        self.hdrMultiplier = value
    }
    
    // MARK: - Codable Conformance for SCNVector3
    
    enum CodingKeys: String, CodingKey {
        case particlesPerUnitLength, tunnelRadiusBase, particleBaseSize, particleVariance
        case warpIntensity, boilSpeed, twinkleSpeed
        case coreColor, midColor, edgeColor
        case hdrMultiplier
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        particlesPerUnitLength = try container.decode(Float.self, forKey: .particlesPerUnitLength)
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
        try container.encode(particlesPerUnitLength, forKey: .particlesPerUnitLength)
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
    public var pointCount: Int = 1000
    public var warpIntensity: Float = 0.025
    public var thickness: Float = 0.3
    public var ejectionMultiplier: Float = 1000.0
    
    // Fallbacks for missing API event data
    public var defaultSpeed: Float = 400.0
    public var defaultHalfAngle: Float = 20.0
    
    public init() {}
    
    // MARK: - Mutating Setters
    
    public mutating func setVisualLoopDuration(_ value: Double) {
        self.visualLoopDuration = value
    }
    
    public mutating func setGlobalTime(_ value: Float) {
        self.globalTime = value
    }
    
    public mutating func setScnFrameTimeSnapshot(_ value: Float) {
        self.scnFrameTimeSnapshot = value
    }
    
    public mutating func setPointCount(_ value: Int) {
        self.pointCount = value
    }
    
    public mutating func setWarpIntensity(_ value: Float) {
        self.warpIntensity = value
    }
    
    public mutating func setThickness(_ value: Float) {
        self.thickness = value
    }
    
    public mutating func setEjectionMultiplier(_ value: Float) {
        self.ejectionMultiplier = value
    }
    
    public mutating func setDefaultSpeed(_ value: Float) {
        self.defaultSpeed = value
    }
    
    public mutating func setDefaultHalfAngle(_ value: Float) {
        self.defaultHalfAngle = value
    }
}
