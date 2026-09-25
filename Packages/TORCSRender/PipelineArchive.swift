// SPDX-License-Identifier: GPL-2.0-only
import CryptoKit
import Foundation
import Metal

/// Compiled pipelines kept between launches, so no pipeline compiles during
/// a race and the first frame after installation is as quick as the
/// hundredth (PORT_SPECIFICATION.md section 24).
///
/// Every pipeline the renderer builds goes through `make`: the archive is
/// offered to the descriptor, so a pipeline already in it is looked up
/// rather than compiled, and the descriptor is added to the archive after
/// so the next launch finds it. `save` serialises the archive; the file is
/// named by a hash of the shader sources, so a change to any shader starts
/// a new archive rather than looking up stale binaries. A missing or
/// unreadable file is not an error — the archive starts empty.
public final class PipelineArchive {
    public let url: URL
    private let archive: MTLBinaryArchive
    /// Whether the archive was loaded from `url` rather than started empty.
    public let loaded: Bool
    /// Pipelines recorded this launch, for diagnostics (a pipeline already
    /// in the archive is recorded again without harm).
    public private(set) var added = 0
    /// Refuse to compile: a pipeline the archive does not hold is an error.
    /// For proving an archive complete — the system keeps its own shader
    /// cache, so a fast launch alone does not say which of the two served.
    public var requiresHit = false

    /// The archive for the current shaders in `directory`.
    public convenience init(device: MTLDevice, directory: URL) throws {
        let name = try Self.shaderIdentity()
        try self.init(device: device, url: directory.appendingPathComponent("pipelines-\(name).metallib"))
    }

    public init(device: MTLDevice, url: URL) throws {
        self.url = url
        let descriptor = MTLBinaryArchiveDescriptor()
        if FileManager.default.fileExists(atPath: url.path) {
            descriptor.url = url
            if let opened = try? device.makeBinaryArchive(descriptor: descriptor) {
                archive = opened
                loaded = true
                return
            }
        }
        descriptor.url = nil
        archive = try device.makeBinaryArchive(descriptor: descriptor)
        loaded = false
    }

    /// A short hash of the shader sources, the archive's file name.
    public static func shaderIdentity() throws -> String {
        let source = try ShaderLibrary.combinedSource()
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds a render pipeline through the archive: found there, it is not
    /// compiled; built, it is recorded. Without an archive this is the
    /// device's own call.
    public static func make(_ descriptor: MTLRenderPipelineDescriptor, device: MTLDevice,
                            archive: PipelineArchive?) throws -> MTLRenderPipelineState {
        guard let archive else { return try device.makeRenderPipelineState(descriptor: descriptor) }
        descriptor.binaryArchives = [archive.archive]
        let options: MTLPipelineOption = archive.requiresHit ? [.failOnBinaryArchiveMiss] : []
        let state = try device.makeRenderPipelineState(descriptor: descriptor, options: options, reflection: nil)
        // Recording can fail for a pipeline the archive cannot hold; that is
        // not the renderer's problem.
        if (try? archive.archive.addRenderPipelineFunctions(descriptor: descriptor)) != nil { archive.added += 1 }
        return state
    }

    public static func make(_ descriptor: MTLComputePipelineDescriptor, device: MTLDevice,
                            archive: PipelineArchive?) throws -> MTLComputePipelineState {
        guard let archive else {
            return try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        }
        descriptor.binaryArchives = [archive.archive]
        let options: MTLPipelineOption = archive.requiresHit ? [.failOnBinaryArchiveMiss] : []
        let state = try device.makeComputePipelineState(descriptor: descriptor, options: options, reflection: nil)
        if (try? archive.archive.addComputePipelineFunctions(descriptor: descriptor)) != nil { archive.added += 1 }
        return state
    }

    /// Writes the archive for the next launch.
    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.serialize(to: url)
    }
}
