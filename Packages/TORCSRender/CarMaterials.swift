// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Physically based material assignment for TORCS car models.
///
/// A TORCS car is one texture atlas and one AC material for everything —
/// paint, glass, lights, interior, driver — so nothing in the render state
/// distinguishes them. The node names do: `grcar` itself relies on the `WI`
/// prefix to find windows. The same convention identifies the rest, and the
/// wheels, which TORCS builds procedurally, by their texture.
public enum CarMaterials {
    public enum Part: String, Sendable, CaseIterable {
        case paint, glass, lens, brakeLens, headLens, interior, driver, wheel
    }

    /// Classifies a car node. `nil` for scenes that are not cars.
    public static func part(name: String, texture: String?, isDriver: Bool) -> Part {
        let upper = name.uppercased()
        let tex = (texture ?? "").lowercased()
        if isDriver || upper.hasPrefix("DRIVER") { return .driver }
        if tex.contains("tex-wheel") || upper.hasPrefix("WHEEL") && !upper.contains("COVER") { return .wheel }
        if upper.hasPrefix("WI") {
            if upper.contains("LIGHTREAR") { return .brakeLens }
            if upper.contains("FRONTLIGHT") { return .headLens }
            return upper.contains("LIGHT") ? .lens : .glass
        }
        if upper.contains("INTERIOR") || upper.contains("COCKPIT") { return .interior }
        return .paint
    }

    /// The material for a part, keeping the atlas colour as the base.
    public static func material(for part: Part, base: ResolvedMaterial) -> ResolvedMaterial {
        var m = base
        m.clearcoat = 0
        switch part {
        case .paint:
            // Metallic flake under a smooth clear coat: the coat carries the
            // sharp environment reflection, the base a broad coloured one.
            m.roughness = 0.42
            m.metallic = 0.3
            m.clearcoat = 1
            m.clearcoatRoughness = 0.05
        case .glass:
            // Smooth dielectric; the deferred, blended pipeline supplies the
            // transparency, this supplies the reflection.
            m.roughness = 0.06
            m.metallic = 0
        case .lens:
            m.roughness = 0.2
            m.metallic = 0
        case .brakeLens:
            // Red through the lens, lit by the brake command. Bright enough
            // to bloom in daylight, as a brake light does.
            m.roughness = 0.2
            m.metallic = 0
            m.emissive = SIMD3(1.0, 0.04, 0.02) * 6
            m.emissiveChannel = 1
        case .headLens:
            m.roughness = 0.2
            m.metallic = 0
            m.emissive = SIMD3(1.0, 0.95, 0.85) * 8
            m.emissiveChannel = 2
        case .interior:
            m.roughness = 0.92
            m.metallic = 0
        case .driver:
            m.roughness = 0.95
            m.metallic = 0
        case .wheel:
            // Tyre and rim share one texture; a compromise between rubber
            // and painted alloy.
            m.roughness = 0.8
            m.metallic = 0.2
        }
        return m
    }
}
