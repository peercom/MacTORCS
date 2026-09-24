// SPDX-License-Identifier: GPL-2.0-only
// Schema adaptation for TORCS 1.3.9 version 0-3 track definitions.
// Attribute names follow src/modules/track/track3.cpp and private/track.h.
// Copyright (C) 1999-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

/// Translates a version 0-3 track definition into the version-4 shape.
///
/// TORCS dispatches on the declared version: 0 through 3 to `ReadTrack3`, 4 to
/// `ReadTrack4`. Seven of the thirty-nine shipped tracks are version 3,
/// including five of the eight dirt tracks, so supporting only version 4 leaves
/// a whole category unreachable.
///
/// The two schemas describe the same road. Segment attributes are identical —
/// `type`, `lg`, `radius`, `arc`, `grade`, `banking end`, `profil`,
/// `profil end tangent`, `z end`, `surface`. What differs is how the sides,
/// borders and barriers are written: version 3 uses flat attributes on the
/// owning section (`lside width`), version 4 a named subsection
/// (`Left Side/width`). Both take their defaults from `Main Track` and allow a
/// per-segment override.
///
/// So this is a rename, not a second geometry implementation, and the
/// version-4 builder — which is verified against the original reader — does the
/// actual work. Anything that turns out not to be a rename belongs in the
/// builder, not here.
public enum TrackVersion3 {
    /// Flat prefix to subsection name, per side.
    static let sideSections: [(prefix: String, section: String)] = [
        ("rside", "Right Side"), ("lside", "Left Side"),
        ("rborder", "Right Border"), ("lborder", "Left Border"),
        ("rbarrier", "Right Barrier"), ("lbarrier", "Left Barrier"),
    ]

    /// Attribute suffix to version-4 key. `type` becomes `banking type`, which
    /// is the only key whose name actually changes rather than losing a prefix.
    static let attributes: [(suffix: String, key: String)] = [
        ("surface", "surface"), ("width", "width"),
        ("start width", "start width"), ("end width", "end width"),
        ("type", "banking type"), ("style", "style"), ("height", "height"),
        ("friction", "friction"),
    ]

    /// Pit attributes are flat on `Main Track` in version 3 and a `Pits`
    /// subsection in version 4. `pit type` has no version-4 counterpart and is
    /// dropped rather than guessed at.
    static let pitAttributes = ["entry", "start", "end", "exit", "side", "length", "width"]

    /// Rewrites one section's flat side attributes into subsections, keeping
    /// every attribute that is not part of the side vocabulary where it is.
    static func lift(_ section: ParameterSection) -> ParameterSection {
        var remaining = section.parameters
        var lifted: [String: [String: Parameter]] = [:]

        for (prefix, name) in sideSections {
            for (suffix, key) in attributes {
                let flat = "\(prefix) \(suffix)"
                guard let value = remaining.removeValue(forKey: flat) else { continue }
                lifted[name, default: [:]][key] = value
            }
        }
        for key in pitAttributes {
            guard let value = remaining.removeValue(forKey: "pit \(key)") else { continue }
            lifted["Pits", default: [:]][key] = value
        }
        remaining.removeValue(forKey: "pit type")
        guard !lifted.isEmpty else {
            return ParameterSection(name: section.name, parameters: remaining, sections: section.sections)
        }
        // A version-3 file never writes these subsections itself, so merging
        // rather than replacing only matters if a file mixes both spellings.
        var sections = section.sections
        for (name, parameters) in lifted.sorted(by: { $0.key < $1.key }) {
            if let index = sections.firstIndex(where: { $0.name == name }) {
                let existing = sections[index]
                sections[index] = ParameterSection(name: name,
                                                   parameters: existing.parameters.merging(parameters) { current, _ in current },
                                                   sections: existing.sections)
            } else {
                sections.append(ParameterSection(name: name, parameters: parameters))
            }
        }
        return ParameterSection(name: section.name, parameters: remaining, sections: sections)
    }

    /// Returns a version-4 shaped document, or the original when it already is
    /// one. Only the road definition is translated; everything else is passed
    /// through untouched.
    public static func normalised(_ document: ParameterDocument) -> ParameterDocument {
        let version = document.section("Header")?.number("version", default: 0) ?? 0
        guard version >= 0, version < 4 else { return document }
        guard let main = document.section("Main Track") else { return document }

        // Version 3 names its segment list "segments"; version 4 names it
        // "Track Segments".
        let segments = main.section("segments")
        let translated = (segments?.sections ?? []).map(lift)

        var mainSections = main.sections.filter { $0.name != "segments" }
        mainSections.append(ParameterSection(name: "Track Segments", sections: translated))
        let liftedMain = lift(ParameterSection(name: main.name, parameters: main.parameters,
                                               sections: mainSections))

        var rootSections = document.root.sections.filter { $0.name != "Main Track" }
        rootSections.append(liftedMain)

        // Version 3 nests the camera entries one level deeper, under "list".
        // The entries themselves are identical, referencing segments by name in
        // both schemas — version 4's numeric-looking values are segment names
        // that happen to be numbers.
        if let cameras = document.section("Cameras"), let list = cameras.section("list") {
            rootSections.removeAll { $0.name == "Cameras" }
            rootSections.append(ParameterSection(name: "Cameras",
                                                 parameters: cameras.parameters,
                                                 sections: list.sections))
        }
        return ParameterDocument(name: document.name,
                                 root: ParameterSection(name: document.root.name,
                                                        parameters: document.root.parameters,
                                                        sections: rootSections))
    }
}
