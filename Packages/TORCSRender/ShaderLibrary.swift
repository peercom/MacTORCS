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
/// the sources are concatenated in dependency order and their *local* includes
/// are stripped. System includes such as `<metal_stdlib>` are left alone.
///
/// Keeping the `#include "..."` lines in the files themselves is deliberate: it
/// means any single shader can still be compiled standalone with
/// `xcrun metal -I Shaders`, which is a much faster way to find a syntax error
/// than a full package build. Every file also carries an include guard, so the
/// concatenation tolerates duplication.
///
/// A prebuilt `TORCSRender.metallib` beside the sources — written by
/// `Scripts/build-shaders.sh` into the app's resource bundle — is preferred
/// when present, so the shipped app compiles no shader source at launch;
/// `TORCS_METALLIB` names one explicitly for tools and measurement. Without
/// either the sources compile at runtime, which is what `swift test` and the
/// render tool do. PORT_SPECIFICATION.md section 24 requires no shader
/// compilation stalls during a race; every pipeline is built when the
/// renderer is, so either route satisfies it once the renderer exists.
public struct ShaderLibrary {
    /// Whether the library came from a prebuilt `.metallib` rather than source.
    public let prebuilt: Bool
    public static let prebuiltName = "TORCSRender"
    /// Dependency order: shared decoding, the BRDF that uses it, tonemapping,
    /// then the passes that draw on all three.
    public static let sourceOrder = ["Common", "BRDF", "Post", "Atmosphere", "Shadow", "Forward", "Sky", "Occlusion", "Reflections", "MotionBlur", "Bloom", "Particles", "SkidMarks", "Resolve"]

    /// Drops `#include "local.metal"` while preserving `#include <system>`.
    static func strippingLocalIncludes(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("#include") && trimmed.contains("\""))
        }.joined(separator: "\n")
    }

    public let library: MTLLibrary

    public init(device: MTLDevice, bundle: Bundle? = nil) throws {
        let bundle = bundle ?? .module
        // The package bundle, the copy of it inside an application bundle
        // (SwiftPM's accessor does not look in Contents/Resources), or an
        // explicit path.
        let candidates: [URL?] = [
            bundle.url(forResource: Self.prebuiltName, withExtension: "metallib", subdirectory: "Shaders"),
            Bundle.main.resourceURL?.appendingPathComponent("TORCSMac_TORCSRender.bundle/Shaders/\(Self.prebuiltName).metallib"),
            ProcessInfo.processInfo.environment["TORCS_METALLIB"].map { URL(fileURLWithPath: $0) }]
        if let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let loaded: MTLLibrary
            do {
                loaded = try device.makeLibrary(URL: url)
            } catch {
                throw RenderError.shaderCompilation("Could not load the prebuilt library at \(url.path): \(error)")
            }
            self.init(library: loaded, prebuilt: true)
            return
        }
        var combined = ""
        for name in Self.sourceOrder {
            guard let url = bundle.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
                ?? bundle.url(forResource: name, withExtension: "metal") else {
                throw RenderError.unavailable("Missing shader source \(name).metal in \(bundle.bundlePath)")
            }
            combined += Self.strippingLocalIncludes(try String(contentsOf: url, encoding: .utf8)) + "\n"
        }
        try self.init(device: device, source: combined)
    }

    private init(library: MTLLibrary, prebuilt: Bool) {
        self.library = library
        self.prebuilt = prebuilt
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
        prebuilt = false
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
            combined += strippingLocalIncludes(try String(contentsOf: url, encoding: .utf8)) + "\n"
        }
        return combined
    }
}
