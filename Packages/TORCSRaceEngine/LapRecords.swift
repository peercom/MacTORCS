// SPDX-License-Identifier: GPL-2.0-only
// The player's best valid lap on each circuit in each car, kept between
// launches so a lap has something to beat.
import Foundation
import TORCSCore

public struct LapRecord: Codable,Sendable,Equatable {
    public let track,car: String
    public let time: Double
    public let date: Date
    public init(track: String,car: String,time: Double,date: Date) { self.track=track;self.car=car;self.time=time;self.date=date }
}
public struct LapRecords: Codable,Sendable,Equatable {
    /// One record per circuit and car.
    public private(set) var records: [LapRecord]
    public init(records: [LapRecord]=[]) {
        self.records=[]
        for record in records { _=submit(track:record.track,car:record.car,time:record.time,date:record.date) }
    }
    /// The best lap on a circuit in one car, or in any car when `car` is nil.
    public func best(track: String,car: String?) -> LapRecord? {
        records.filter { $0.track==track && (car==nil || $0.car==car) }.min { $0.time<$1.time }
    }
    /// Take a valid lap. True when it is the best yet for the pairing; a
    /// slower lap, or a time that is not a lap time, changes nothing.
    @discardableResult public mutating func submit(track: String,car: String,time: Double,date: Date) -> Bool {
        guard time.isFinite,time>0,!track.isEmpty,!car.isEmpty else { return false }
        if let index=records.firstIndex(where:{ $0.track==track && $0.car==car }) {
            guard time<records[index].time else { return false }
            records[index]=LapRecord(track:track,car:car,time:time,date:date)
        } else {
            records.append(LapRecord(track:track,car:car,time:time,date:date))
        }
        return true
    }
}
public struct LapRecordsStore: Sendable {
    private let store: ConfigurationStore
    public init(directory: URL? = nil) throws { store=try ConfigurationStore(directory:directory) }
    public func load() throws -> LapRecords {
        let url=store.directory.appendingPathComponent("records.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return LapRecords() }
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        // Re-submitted on the way in, so a hand-edited file cannot hold two
        // records for one pairing or a time that is not one.
        return LapRecords(records:try decoder.decode(LapRecords.self,from:Data(contentsOf:url)).records)
    }
    public func save(_ records: LapRecords) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to:store.directory.appendingPathComponent("records.json"),options:.atomic)
    }
}
