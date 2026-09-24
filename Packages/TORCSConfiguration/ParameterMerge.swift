// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 params.cpp insertParamMerge/GfParmMergeHandles.
// Copyright (C) 1999-2014 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public struct ParameterMergeMode: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let reference = Self(rawValue: 1)
    public static let target = Self(rawValue: 2)
    public static let both: Self = [.reference, .target]
}

extension ParameterDocument {
    /// Category/setup merge: intersects bounds, uses target values, and retains
    /// upstream's string-choice/default quirks. Inputs remain immutable.
    public func merging(_ target: Self, mode: ParameterMergeMode = .both) throws -> Self {
        guard mode.rawValue & ~3 == 0 else { throw ParameterError.invalid("Unknown merge mode") }
        final class Builder {
            let name: String
            var parameters: [String: Parameter] = [:]
            var children: [Builder] = []
            init(_ name: String) { self.name = name }
            func at(_ path: [String]) -> Builder {
                guard let first = path.first else { return self }
                let child: Builder
                if let found = children.first(where: { $0.name == first }) { child = found }
                else { child = Builder(first); children.append(child) }
                return child.at(Array(path.dropFirst()))
            }
            func freeze() -> ParameterSection {
                .init(name: name, parameters: parameters, sections: children.map { $0.freeze() })
            }
        }
        // GfParmMergeHandles only traverses sections, not root attributes.
        guard root.parameters.isEmpty, target.root.parameters.isEmpty else {
            throw ParameterError.invalid("TORCS parameters must be inside sections")
        }
        let output = Builder(target.name)
        func combine(_ reference: Parameter, _ value: Parameter, existing: Parameter?) throws -> Parameter {
            switch (reference, value) {
            case (.number(let a), .number(let b)):
                let minimum = max(a.minimum, b.minimum), maximum = min(a.maximum, b.maximum)
                // Preserve the original sequential clamps, even for disjoint ranges.
                let clamped = min(maximum, max(minimum, b.value))
                return .number(.init(value: clamped, minimum: minimum, maximum: maximum, unit: b.unit))
            case (.string(let fallback, let accepted), .string(let requested, let choices)):
                var previous: [String] = []
                if case .string(_, let existingChoices) = existing { previous = existingChoices }
                // The original processes common keys twice in BOTH mode without
                // clearing the choices. Preserve those duplicates deliberately.
                return .string(accepted.contains(requested) ? requested : fallback,
                               allowed: previous + choices.filter { accepted.contains($0) })
            default: throw ParameterError.invalid("Cannot merge numeric and string parameters with the same key")
            }
        }
        func traverse(_ section: ParameterSection, parent: [String], fromReference: Bool) throws {
            let path = parent + [section.name]
            for (name, parameter) in section.parameters {
                let ref = fromReference ? parameter : self.section(path.joined(separator: "/"))?.parameters[name]
                let dst = fromReference ? target.section(path.joined(separator: "/"))?.parameters[name] : parameter
                let destination = output.at(path)
                if let ref, let dst { destination.parameters[name] = try combine(ref, dst, existing: destination.parameters[name]) }
                else { destination.parameters[name] = parameter }
            }
            for child in section.sections { try traverse(child, parent: path, fromReference: fromReference) }
        }
        if mode.contains(.reference) { for section in root.sections { try traverse(section, parent: [], fromReference: true) } }
        if mode.contains(.target) { for section in target.root.sections { try traverse(section, parent: [], fromReference: false) } }
        return Self(name: target.name, root: output.freeze())
    }
}
