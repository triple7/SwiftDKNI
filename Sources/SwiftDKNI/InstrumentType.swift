//
//  InstrumentType.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 21/6/2026.
//

import Foundation

public enum InstrumentType: String, Codable {
    case sohoLascoC2 = "SOHO: LASCO/C2"
    case sohoLascoC3 = "SOHO: LASCO/C3"
    case stereoACor1 = "STEREO A: SECCHI/COR1"
    case stereoACor2 = "STEREO A: SECCHI/COR2"
    case stereoBCor1 = "STEREO B: SECCHI/COR1"
    case stereoBCor2 = "STEREO B: SECCHI/COR2"
    case sdoAia = "SDO: AIA"
    
    /// Fallback case for when the API returns a new or unexpected instrument
    case unknown
    
public     init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawString = try container.decode(String.self)
        
        // If the string matches a case, initialize it. Otherwise, default to .unknown
        self = InstrumentType(rawValue: rawString) ?? .unknown
    }
}

