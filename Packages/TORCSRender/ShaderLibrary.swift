// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal

public enum RenderError: Error, CustomStringConvertible {
    case unavailable(String)
    case shaderCompilation(String)
    public var description: String {
        switch self {
        case .unavailable(let message): return message
        case .shaderCompilation(let message): return "Shader compilation failed: \(message)"
        }
    }
}

/// Loads and compiles the render path's Metal sources.
///
/// `makeLibrary(source:)` does not resolve filesystem `#include` directives, so
/// the sources are concatenated in dependency order instead. Every shader file
/// carries an include guard, which makes the concatenation order-tolerant and
/// keeps each file independently compilable with `xcrun metal` for quick checks.
///
/// This compiles at runtime, matching the classic path. Phase 8 replaces it
/// with a prebuilt `.metallib` plus an `MTLBinaryArchive`, because
/// PORT_SPECIFICATION.md section 24 requires that no pipeline compiles during a
/// race.
public struct ShaderLibrary {
    /// Dependency order: shared decoding first, then the BRDF that uses it.
    public static let sourceOrder = ["Common", "BRDF"]

    public let library: MTLLibrary

    public init(device: MTLDevice, bundle: Bundle? = nil) throws {
        let bundle = bundle ?? .module
        var combined = ""
        for name in Self.sourceOrder {
            guard let url = bundle.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
                ?? bundle.url(forResource: name, withExtension: "metal") else {
                throw RenderError.unavailable("Missing shader source \(name).metal in \(bundle.bundlePath)")
            }
            combined += try String(contentsOf: url, encoding: .utf8) + "\n"
        }
        try self.init(device: device, source: combined)
    }

    /// Compiles explicit source. Used by tests that append a probe kernel to
    /// the shared sources.
    public init(device: MTLDevice, source: String) throws {
        let options = MTLCompileOptions()
        // The temporal path depends on positions being reproducible between
        // passes; the classic renderer needed this for its repeat-render
        // determinism and the reasoning has not changed.
        options.preserveInvariance = true
        do {
            library = try device.makeLibrary(source: source, options: options)
        } catch {
            throw RenderError.shaderCompilation(String(describing: error))
        }
    }

    /// The concatenated shared sources, for tests that build on them.
    public static func combinedSource(bundle: Bundle? = nil) throws -> String {
        let bundle = bundle ?? .module
        var combined = ""
        for name in sourceOrder {
            guard let url = bundle.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
                ?? bundle.url(forResource: name, withExtension: "metal") else {
                throw RenderError.unavailable("Missing shader source \(name).metal")
            }
            combined += try String(contentsOf: url, encoding: .utf8) + "\n"
        }
        return combined
    }
}
