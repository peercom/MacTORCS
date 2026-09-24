// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 grcam.cpp zoom commands and factory limits.
// Copyright (C) 2000 Eric Espie; upstream GPL-2.0-or-later.
import Foundation
import TORCSAssets
import TORCSCore

public enum CameraZoomCommand: Int, CaseIterable, Sendable {
    case zoomIn = 0, zoomOut, maximum, minimum, reset
}
extension DrivingCameraPreset {
    /// Original camera-list and camera ID; stable independently of UI labels/order.
    public var referenceID: (head: Int, camera: Int) {
        switch self {
        case .chase: (0,0); case .near: (0,1); case .bonnet: (0,2); case .driver: (0,3); case .road: (0,4)
        case .far: (1,0); case .trackAligned: (1,1); case .low: (1,2); case .reverse: (1,3)
        case .side1: (2,0); case .side2: (2,1); case .side3: (2,2); case .side4: (2,3)
        case .side5: (2,4); case .side6: (2,5); case .side7: (2,6); case .side8: (2,7)
        case .overhead1: (3,0); case .overhead2: (3,1); case .overhead3: (3,2); case .overhead4: (3,3)
        case .circuit: (4,0)
        case .panorama1: (5,0); case .panorama2: (5,1); case .panorama3: (5,2); case .panorama4: (5,3); case .panorama5: (5,4)
        case .trackside: (6,0); case .tracksideZoom: (7,0); case .fly: (8,0); case .television: (9,0)
        }
    }
    public var preferenceKey: String { let id=referenceID;return "fovy-\(id.head)-\(id.camera)" }
    public var distanceScaledZoom: Bool { self == .circuit || self == .tracksideZoom || self == .television }
    public var zoomLimits: (standard: Float, minimum: Float, maximum: Float) {
        switch self {
        case .bonnet,.road,.driver: (67.5,50,95)
        case .side1,.side2,.side3,.side4,.side5,.side6,.side7,.side8,.trackside: (30,5,60)
        case .overhead1,.overhead2,.overhead3,.overhead4,.fly: (67.5,1,90)
        case .circuit: (21,2,60)
        case .panorama1,.panorama2,.panorama3,.panorama4,.panorama5: (74,1,110)
        case .tracksideZoom,.television: (9,1,90)
        default: (40,5,95)
        }
    }
    func validateZoom(_ value: Float) throws {
        // Original loadDefaults does not clamp to factory limits. Preserve usable
        // out-of-range preferences, but reject nonfinite/degenerate projections.
        guard value.isFinite, value>0, distanceScaledZoom || (value<180 && (1/tan((value * .pi/180)/2)).isFinite) else { throw ACError.invalid("Invalid zoom for \(rawValue)") }
    }
    public func adjustedZoom(_ value: Float, command: CameraZoomCommand) throws -> Float {
        try validateZoom(value)
        let limits=zoomLimits
        switch command {
        case .zoomIn: return max(limits.minimum, value>2 ? value-1 : value/2)
        case .zoomOut: return min(limits.maximum, value+1)
        case .maximum: return limits.maximum
        case .minimum: return limits.minimum
        case .reset: return limits.standard
        }
    }
}

/// One native viewport. Original fovy-head-id keys identify independent settings.
/// Multi-screen and per-driver selection, and graph.xml import, remain separate.
public struct CameraPreferences: Codable, Equatable, Sendable {
    public var version=1
    public var selectedKey=DrivingCameraPreset.chase.preferenceKey
    public var zoomValues: [String:Float]=[:]
    public init() {}
    public var selectedPreset: DrivingCameraPreset { DrivingCameraPreset.allCases.first { $0.preferenceKey==selectedKey } ?? .chase }
    public func zoom(for preset: DrivingCameraPreset) -> Float { zoomValues[preset.preferenceKey] ?? preset.zoomLimits.standard }
    public mutating func select(_ preset: DrivingCameraPreset) { selectedKey=preset.preferenceKey }
    public mutating func adjust(_ command: CameraZoomCommand, for preset: DrivingCameraPreset) throws {
        zoomValues[preset.preferenceKey]=try preset.adjustedZoom(zoom(for:preset),command:command)
    }
    public func validate() throws {
        let keys=Set(DrivingCameraPreset.allCases.map(\.preferenceKey))
        guard version==1, keys.contains(selectedKey), Set(zoomValues.keys).isSubset(of:keys) else { throw ACError.invalid("Unsupported camera settings") }
        for preset in DrivingCameraPreset.allCases { try preset.validateZoom(zoom(for:preset)) }
    }
}
public struct CameraPreferencesStore: Sendable {
    private let store: ConfigurationStore
    public init(directory: URL? = nil) throws { store=try ConfigurationStore(directory:directory) }
    public func load() throws -> CameraPreferences {
        let url=store.directory.appendingPathComponent("cameras.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return CameraPreferences() }
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 65536 else { throw ACError.invalid("Camera settings exceed 64 KiB") }
        let data=try Data(contentsOf:url)
        guard data.count<=65536 else { throw ACError.invalid("Camera settings exceed 64 KiB") }
        let preferences=try JSONDecoder().decode(CameraPreferences.self,from:data)
        try preferences.validate();return preferences
    }
    public func save(_ preferences: CameraPreferences) throws { try preferences.validate();try store.save(preferences,name:"cameras.json") }
}
