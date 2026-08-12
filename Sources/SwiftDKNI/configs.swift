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
    public var thermalConfig:StarThermalConfig
    
    public init(
        energyTunnelConfig: EnergyTunnelConfig = EnergyTunnelConfig(),
        cmeConfig: CMEConfig = CMEConfig(),
        thermalConfig:StarThermalConfig = StarThermalConfig()
    ) {
        self.energyTunnelConfig = energyTunnelConfig
        self.cmeConfig = cmeConfig
        self.thermalConfig = thermalConfig
    }
    
    // MARK: - Mutating Setters
    
    public mutating func setEnergyTunnelConfig(_ value: EnergyTunnelConfig) {
        self.energyTunnelConfig = value
    }
    
    public mutating func setCMEConfig(_ value: CMEConfig) {
        self.cmeConfig = value
    }

    public mutating func setThermalConfig(_ value: StarThermalConfig) {
        self.thermalConfig = value
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
    public var dyingColor: SCNVector3 = SCNVector3(0.5, 0.02, 0.0) // NEW: Cooling tail color
    
    public var hdrMultiplier: Float = 0.8
    
    // MARK: - Apex Turbulence Uniforms
    public var turbulenceFrequency: Float = 10.0
    public var turbulenceAmplitude: Float = 1.5
    public var apexWarpMultiplier: Float = 4.0
    public var apexSoftness: Float = 0.9
    
    public init() {}
    
    // MARK: - Mutating Setters
    
    public mutating func setParticlesPerUnitLength(_ value: Float) { self.particlesPerUnitLength = value }
    public mutating func setTunnelRadiusBase(_ value: Float) { self.tunnelRadiusBase = value }
    public mutating func setParticleBaseSize(_ value: Float) { self.particleBaseSize = value }
    public mutating func setParticleVariance(_ value: Float) { self.particleVariance = value }
    
    public mutating func setWarpIntensity(_ value: Float) { self.warpIntensity = value }
    public mutating func setBoilSpeed(_ value: Float) { self.boilSpeed = value }
    public mutating func setTwinkleSpeed(_ value: Float) { self.twinkleSpeed = value }
    
    public mutating func setCoreColor(_ value: SCNVector3) { self.coreColor = value }
    public mutating func setMidColor(_ value: SCNVector3) { self.midColor = value }
    public mutating func setEdgeColor(_ value: SCNVector3) { self.edgeColor = value }
    public mutating func setDyingColor(_ value: SCNVector3) { self.dyingColor = value }
    
    public mutating func setHdrMultiplier(_ value: Float) { self.hdrMultiplier = value }
    
    public mutating func setTurbulenceFrequency(_ value: Float) { self.turbulenceFrequency = value }
    public mutating func setTurbulenceAmplitude(_ value: Float) { self.turbulenceAmplitude = value }
    public mutating func setApexWarpMultiplier(_ value: Float) { self.apexWarpMultiplier = value }
    public mutating func setApexSoftness(_ value: Float) { self.apexSoftness = value }
    
    // MARK: - Codable Conformance
    
    enum CodingKeys: String, CodingKey {
        case particlesPerUnitLength, tunnelRadiusBase, particleBaseSize, particleVariance
        case warpIntensity, boilSpeed, twinkleSpeed
        case coreColor, midColor, edgeColor, dyingColor
        case hdrMultiplier
        case turbulenceFrequency, turbulenceAmplitude, apexWarpMultiplier, apexSoftness
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
        
        // Decode dyingColor with decodeIfPresent for backwards compatibility
        if let dyingArray = try container.decodeIfPresent([Float].self, forKey: .dyingColor) {
            dyingColor = SCNVector3(dyingArray[0], dyingArray[1], dyingArray[2])
        }
        
        // New variables with decodeIfPresent for backwards compatibility
        turbulenceFrequency = try container.decodeIfPresent(Float.self, forKey: .turbulenceFrequency) ?? 10.0
        turbulenceAmplitude = try container.decodeIfPresent(Float.self, forKey: .turbulenceAmplitude) ?? 1.5
        apexWarpMultiplier = try container.decodeIfPresent(Float.self, forKey: .apexWarpMultiplier) ?? 4.0
        apexSoftness = try container.decodeIfPresent(Float.self, forKey: .apexSoftness) ?? 0.9
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
        try container.encode([Float(dyingColor.x), Float(dyingColor.y), Float(dyingColor.z)], forKey: .dyingColor)
        
        // Encode new variables
        try container.encode(turbulenceFrequency, forKey: .turbulenceFrequency)
        try container.encode(turbulenceAmplitude, forKey: .turbulenceAmplitude)
        try container.encode(apexWarpMultiplier, forKey: .apexWarpMultiplier)
        try container.encode(apexSoftness, forKey: .apexSoftness)
    }
}

public struct CMEConfig: Codable {
    // Timeline constraints
    public var visualLoopDuration: Double = 180.0
    public var globalTime: Float = -1.0
    public var scnFrameTimeSnapshot: Float = 0.0
    
    // Physics and Deformation
    public var pointCount: Int = 200
    public var warpIntensity: Float = 0.025
    public var thickness: Float = 0.3
    public var ejectionMultiplier: Float = 1000.0
    
    // Fallbacks for missing API event data
    public var defaultSpeed: Float = 400.0
    public var defaultHalfAngle: Float = 20.0
    
    // MARK: - Thermal Color Uniforms
    public var coreColor: SCNVector3 = SCNVector3(1.0, 0.9, 0.7)  // White-hot
    public var midColor: SCNVector3 = SCNVector3(1.0, 0.4, 0.0)   // Vibrant Orange-Red
    public var edgeColor: SCNVector3 = SCNVector3(0.2, 0.0, 0.15) // Dark Magenta / Plasma edge
    
    public init() {}
    
    // MARK: - Mutating Setters
    
    public mutating func setVisualLoopDuration(_ value: Double) { self.visualLoopDuration = value }
    public mutating func setGlobalTime(_ value: Float) { self.globalTime = value }
    public mutating func setScnFrameTimeSnapshot(_ value: Float) { self.scnFrameTimeSnapshot = value }
    
    public mutating func setPointCount(_ value: Int) { self.pointCount = value }
    public mutating func setWarpIntensity(_ value: Float) { self.warpIntensity = value }
    public mutating func setThickness(_ value: Float) { self.thickness = value }
    public mutating func setEjectionMultiplier(_ value: Float) { self.ejectionMultiplier = value }
    
    public mutating func setDefaultSpeed(_ value: Float) { self.defaultSpeed = value }
    public mutating func setDefaultHalfAngle(_ value: Float) { self.defaultHalfAngle = value }
    
    public mutating func setCoreColor(_ value: SCNVector3) { self.coreColor = value }
    public mutating func setMidColor(_ value: SCNVector3) { self.midColor = value }
    public mutating func setEdgeColor(_ value: SCNVector3) { self.edgeColor = value }
    
    // MARK: - Codable Conformance
    
    enum CodingKeys: String, CodingKey {
        case visualLoopDuration, globalTime, scnFrameTimeSnapshot
        case pointCount, warpIntensity, thickness, ejectionMultiplier
        case defaultSpeed, defaultHalfAngle
        case coreColor, midColor, edgeColor
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        visualLoopDuration = try container.decodeIfPresent(Double.self, forKey: .visualLoopDuration) ?? 180.0
        globalTime = try container.decodeIfPresent(Float.self, forKey: .globalTime) ?? -1.0
        scnFrameTimeSnapshot = try container.decodeIfPresent(Float.self, forKey: .scnFrameTimeSnapshot) ?? 0.0
        
        pointCount = try container.decodeIfPresent(Int.self, forKey: .pointCount) ?? 200
        warpIntensity = try container.decodeIfPresent(Float.self, forKey: .warpIntensity) ?? 0.025
        thickness = try container.decodeIfPresent(Float.self, forKey: .thickness) ?? 0.3
        ejectionMultiplier = try container.decodeIfPresent(Float.self, forKey: .ejectionMultiplier) ?? 1000.0
        
        defaultSpeed = try container.decodeIfPresent(Float.self, forKey: .defaultSpeed) ?? 400.0
        defaultHalfAngle = try container.decodeIfPresent(Float.self, forKey: .defaultHalfAngle) ?? 20.0
        
        // Decode SCNVector3 as Float arrays with fallback defaults for backward compatibility
        if let coreArray = try container.decodeIfPresent([Float].self, forKey: .coreColor) {
            coreColor = SCNVector3(coreArray[0], coreArray[1], coreArray[2])
        }
        
        if let midArray = try container.decodeIfPresent([Float].self, forKey: .midColor) {
            midColor = SCNVector3(midArray[0], midArray[1], midArray[2])
        }
        
        if let edgeArray = try container.decodeIfPresent([Float].self, forKey: .edgeColor) {
            edgeColor = SCNVector3(edgeArray[0], edgeArray[1], edgeArray[2])
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(visualLoopDuration, forKey: .visualLoopDuration)
        try container.encode(globalTime, forKey: .globalTime)
        try container.encode(scnFrameTimeSnapshot, forKey: .scnFrameTimeSnapshot)
        
        try container.encode(pointCount, forKey: .pointCount)
        try container.encode(warpIntensity, forKey: .warpIntensity)
        try container.encode(thickness, forKey: .thickness)
        try container.encode(ejectionMultiplier, forKey: .ejectionMultiplier)
        
        try container.encode(defaultSpeed, forKey: .defaultSpeed)
        try container.encode(defaultHalfAngle, forKey: .defaultHalfAngle)
        
        // Encode SCNVector3 as Float arrays for safe serialization
        try container.encode([Float(coreColor.x), Float(coreColor.y), Float(coreColor.z)], forKey: .coreColor)
        try container.encode([Float(midColor.x), Float(midColor.y), Float(midColor.z)], forKey: .midColor)
        try container.encode([Float(edgeColor.x), Float(edgeColor.y), Float(edgeColor.z)], forKey: .edgeColor)
    }
}

public struct StarThermalConfig: Codable {
    public var warpIntensity: Float = 1.0
    public var opacity: Float = 0.05
    public var color: SCNVector3 = SCNVector3(1.0, 0.65, 0.05)
    public var directionMultiplier: Float = 1.0 // Controls the speed/influence of the voxel direction
    
    // MARK: - New Shader Uniforms
    public var haloInner: Float = 0.3
    public var haloOuter: Float = 0.9
    public var maskMin: Float = 0.05
    public var maskMax: Float = 0.6
    public var contrastPower: Float = 1.2
    public var minMultiplier: Float = 1.2
    public var maxMultiplier: Float = 3.5
    
    // MARK: - Deep Color & Blending Uniforms
    public var surfaceColorInfluence: Float = 0.75
    public var deepColor: SCNVector3 = SCNVector3(1.0, 0.05, 0.0)
    public var hotColor: SCNVector3 = SCNVector3(1.0, 0.7, 0.1)
    
    public init() {}
    
    // MARK: - Mutating Setters
    
    public mutating func setWarpIntensity(_ value: Float) { self.warpIntensity = value }
    public mutating func setOpacity(_ value: Float) { self.opacity = value }
    public mutating func setColor(_ value: SCNVector3) { self.color = value }
    public mutating func setDirectionMultiplier(_ value: Float) { self.directionMultiplier = value }
    
    public mutating func setHaloInner(_ value: Float) { self.haloInner = value }
    public mutating func setHaloOuter(_ value: Float) { self.haloOuter = value }
    public mutating func setMaskMin(_ value: Float) { self.maskMin = value }
    public mutating func setMaskMax(_ value: Float) { self.maskMax = value }
    public mutating func setContrastPower(_ value: Float) { self.contrastPower = value }
    public mutating func setMinMultiplier(_ value: Float) { self.minMultiplier = value }
    public mutating func setMaxMultiplier(_ value: Float) { self.maxMultiplier = value }
    
    public mutating func setSurfaceColorInfluence(_ value: Float) { self.surfaceColorInfluence = value }
    public mutating func setDeepColor(_ value: SCNVector3) { self.deepColor = value }
    public mutating func setHotColor(_ value: SCNVector3) { self.hotColor = value }
    
    // MARK: - Codable Conformance
    
    enum CodingKeys: String, CodingKey {
        case warpIntensity, opacity, color, directionMultiplier
        case haloInner, haloOuter, maskMin, maskMax, contrastPower, minMultiplier, maxMultiplier
        case surfaceColorInfluence, deepColor, hotColor
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        warpIntensity = try container.decode(Float.self, forKey: .warpIntensity)
        opacity = try container.decode(Float.self, forKey: .opacity)
        
        // Use decodeIfPresent for backwards compatibility with existing config files
        directionMultiplier = try container.decodeIfPresent(Float.self, forKey: .directionMultiplier) ?? 1.0
        
        haloInner = try container.decodeIfPresent(Float.self, forKey: .haloInner) ?? 0.3
        haloOuter = try container.decodeIfPresent(Float.self, forKey: .haloOuter) ?? 0.9
        maskMin = try container.decodeIfPresent(Float.self, forKey: .maskMin) ?? 0.05
        maskMax = try container.decodeIfPresent(Float.self, forKey: .maskMax) ?? 0.6
        contrastPower = try container.decodeIfPresent(Float.self, forKey: .contrastPower) ?? 1.2
        minMultiplier = try container.decodeIfPresent(Float.self, forKey: .minMultiplier) ?? 1.2
        maxMultiplier = try container.decodeIfPresent(Float.self, forKey: .maxMultiplier) ?? 3.5
        
        surfaceColorInfluence = try container.decodeIfPresent(Float.self, forKey: .surfaceColorInfluence) ?? 0.75
        
        // Decode SCNVector3 as a Float array
        let colorArray = try container.decode([Float].self, forKey: .color)
        color = SCNVector3(colorArray[0], colorArray[1], colorArray[2])
        
        if let deepColorArray = try container.decodeIfPresent([Float].self, forKey: .deepColor) {
            deepColor = SCNVector3(deepColorArray[0], deepColorArray[1], deepColorArray[2])
        }
        
        if let hotColorArray = try container.decodeIfPresent([Float].self, forKey: .hotColor) {
            hotColor = SCNVector3(hotColorArray[0], hotColorArray[1], hotColorArray[2])
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(warpIntensity, forKey: .warpIntensity)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(directionMultiplier, forKey: .directionMultiplier)
        
        try container.encode(haloInner, forKey: .haloInner)
        try container.encode(haloOuter, forKey: .haloOuter)
        try container.encode(maskMin, forKey: .maskMin)
        try container.encode(maskMax, forKey: .maskMax)
        try container.encode(contrastPower, forKey: .contrastPower)
        try container.encode(minMultiplier, forKey: .minMultiplier)
        try container.encode(maxMultiplier, forKey: .maxMultiplier)
        
        try container.encode(surfaceColorInfluence, forKey: .surfaceColorInfluence)
        
        // Encode SCNVector3 as a Float array for safe serialization
        try container.encode([Float(color.x), Float(color.y), Float(color.z)], forKey: .color)
        try container.encode([Float(deepColor.x), Float(deepColor.y), Float(deepColor.z)], forKey: .deepColor)
        try container.encode([Float(hotColor.x), Float(hotColor.y), Float(hotColor.z)], forKey: .hotColor)
    }
}

