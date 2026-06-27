//
//  SWPCRegion.swift
//  SwiftDKNI
//
//  Created by Yuma decaux on 27/6/2026.
//


// MARK: - NOAA SWPC Models
public struct SWPCRegion: Codable {
    let region: Int?
    let latitude: Int?
    let longitude: Int?
    let area: Int?
    let magType: String?
    
    enum CodingKeys: String, CodingKey {
        case region = "region"
        case latitude = "latitude"
        case longitude = "longitude"
        case area = "area"
        case magType = "mag_type"
    }
}