// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Sequential JSONL decoding. Total capture length is unbounded; individual
/// records are bounded before decoding. Blank lines are ignored, as in TelemetryIO.
public final class TelemetryReader {
    private let handle: FileHandle
    private let decoder=JSONDecoder()
    private let maximumRecordBytes,chunkBytes: Int
    private var chunk=Data(),cursor=0,lineNumber=0
    private var ended=false
    public init(_ url: URL,maximumRecordBytes: Int=16*1024*1024,chunkBytes: Int=64*1024) throws {
        guard (1...16*1024*1024).contains(maximumRecordBytes),(1...16*1024*1024).contains(chunkBytes) else {
            throw TelemetryError.invalid("Invalid telemetry reader limits")
        }
        handle=try FileHandle(forReadingFrom:url)
        self.maximumRecordBytes=maximumRecordBytes;self.chunkBytes=chunkBytes
    }
    deinit { try? handle.close() }
    public func next() throws -> TelemetryRecord? {
        // CLI/headless loops have no AppKit event-loop pool to drain Foundation
        // IO temporaries. Keep their lifetime bounded to one decoded record.
        try autoreleasepool { try readNext() }
    }
    private func readNext() throws -> TelemetryRecord? {
        guard !ended else { return nil }
        var line=Data()
        while true {
            if cursor==chunk.count {
                chunk=try handle.read(upToCount:chunkBytes) ?? Data();cursor=0
                if chunk.isEmpty {
                    ended=true
                    guard !line.isEmpty else { return nil }
                    lineNumber += 1
                    return try decode(line)
                }
            }
            let end=chunk[cursor...].firstIndex(of:10) ?? chunk.count
            guard line.count<=maximumRecordBytes-(end-cursor) else {
                throw TelemetryError.invalid("Line \(lineNumber+1) exceeds the \(maximumRecordBytes)-byte record limit")
            }
            line.append(contentsOf:chunk[cursor..<end]);cursor=end
            if end<chunk.count {
                cursor += 1;lineNumber += 1
                if line.isEmpty || line==Data([13]) { line.removeAll(keepingCapacity:true);continue }
                return try decode(line)
            }
        }
    }
    private func decode(_ data: Data) throws -> TelemetryRecord {
        do { return try decoder.decode(TelemetryRecord.self,from:data) }
        catch { throw TelemetryError.invalid("Line \(lineNumber): \(error)") }
    }
}
