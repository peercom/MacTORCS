// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public struct ConfigurationStore: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("TORCSMac", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    public func save<T: Encodable>(_ value: T, name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    public func load<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }
}
