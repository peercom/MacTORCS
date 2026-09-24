// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Darwin

public struct FieldSummary: Codable,Sendable {
    public let maximumAbsolute,maximumRelative,rms: Double
    public let failures: Int
    public let firstDivergentTick: Int?
}
/// The in-memory result contains aggregates only. A requested schema-2 report
/// contains every divergence sample, streamed by record, followed by these fields.
public struct StreamingDiffSummary: Codable,Sendable {
    public let passed: Bool
    public let records: Int
    public let absoluteTolerance,relativeTolerance: Double
    public let fields: [String:FieldSummary]
    public var text: String {
        var result="\(passed ? "PASS":"FAIL") — \(records) aligned records; abs \(absoluteTolerance), rel \(relativeTolerance)\n"
        for name in fields.keys.sorted() {
            let f=fields[name]!
            result += "\(name): max abs=\(f.maximumAbsolute), max rel=\(f.maximumRelative), RMS=\(f.rms), failures=\(f.failures)\n"
        }
        return result
    }
}
private struct FieldAccumulator {
    var maximumAbsolute:Double=0,maximumRelative:Double=0,scaledSquares:Double=0
    var failures=0,firstDivergentTick:Int?
    mutating func add(absolute:Double,relative:Double,failed:Bool,tick:Int) {
        if absolute>maximumAbsolute {
            let ratio=maximumAbsolute/absolute
            scaledSquares=scaledSquares*ratio*ratio+1
            maximumAbsolute=absolute
        } else if maximumAbsolute>0 {
            let ratio=absolute/maximumAbsolute;scaledSquares += ratio*ratio
        }
        maximumRelative=max(maximumRelative,relative)
        if failed { failures += 1;if firstDivergentTick==nil { firstDivergentTick=tick } }
    }
    func summary(count:Int) -> FieldSummary {
        FieldSummary(maximumAbsolute:maximumAbsolute,maximumRelative:maximumRelative,
                     rms:maximumAbsolute*sqrt(min(1,scaledSquares/Double(count))),failures:failures,firstDivergentTick:firstDivergentTick)
    }
}
private struct DivergenceValue: Encodable { let absolute,relative:Double }
private struct DivergenceRecord: Encodable { let tick:Int;let time:Double;let fields:[String:DivergenceValue] }

extension TelemetryDiff {
    /// Strict lockstep comparison with O(fields + largest record) memory, even
    /// when writing all divergence samples. Invalid inputs never replace a report.
    public static func compareFiles(reference: URL,candidate: URL,absoluteTolerance: Double=1e-5,
                                    relativeTolerance: Double=1e-6,reportURL: URL?=nil) throws -> StreamingDiffSummary {
        guard absoluteTolerance.isFinite,relativeTolerance.isFinite,absoluteTolerance>=0,relativeTolerance>=0 else {
            throw TelemetryError.invalid("Tolerances must be finite and non-negative")
        }
        if let reportURL {
            for input in [reference,candidate] where sameFile(input,reportURL) {
                throw TelemetryError.invalid("The report must not replace a telemetry input")
            }
        }
        let referenceReader=try TelemetryReader(reference),candidateReader=try TelemetryReader(candidate)
        let output=try reportURL.map { try StreamingDiffOutput(to:$0) }
        var keys:Set<String>?,scenario:String?,previousTick:Int?,previousTime:Double?,count=0
        var accumulators:[String:FieldAccumulator]=[:]
        while true {
            let r=try referenceReader.next(),c=try candidateReader.next()
            if r==nil && c==nil { break }
            guard let r,let c else { throw TelemetryError.invalid("Mismatched record count at record \(count+1)") }
            if keys==nil {
                keys=Set(r.values.keys);scenario=r.scenario
                guard !keys!.isEmpty else { throw TelemetryError.invalid("No telemetry fields") }
                accumulators=Dictionary(uniqueKeysWithValues:keys!.map { ($0,FieldAccumulator()) })
            }
            guard r.schema==1,c.schema==r.schema,r.scenario==c.scenario,r.scenario==scenario,
                  r.tick>=0,r.tick==c.tick,r.time.isFinite,r.time>=0,r.time==c.time,
                  Set(r.values.keys)==keys,Set(c.values.keys)==keys,
                  previousTick.map({r.tick>$0}) ?? true,previousTime.map({r.time>$0}) ?? true else {
                throw TelemetryError.invalid("Schema, scenario, tick, time, or field mismatch at record \(count+1)")
            }
            var divergence:[String:DivergenceValue]=[:]
            for key in keys! {
                let rv=r.values[key]!,cv=c.values[key]!
                guard rv.isFinite,cv.isFinite else { throw TelemetryError.invalid("Non-finite \(key) at tick \(r.tick)") }
                let absolute=abs(cv-rv),relative=absolute/max(abs(rv),1e-30)
                guard absolute.isFinite,relative.isFinite else { throw TelemetryError.invalid("Error overflow in \(key)") }
                accumulators[key]!.add(absolute:absolute,relative:relative,
                    failed:absolute>absoluteTolerance+relativeTolerance*abs(rv),tick:r.tick)
                if output != nil { divergence[key]=DivergenceValue(absolute:absolute,relative:relative) }
            }
            try output?.append(DivergenceRecord(tick:r.tick,time:r.time,fields:divergence))
            count += 1;previousTick=r.tick;previousTime=r.time
        }
        guard count>0 else { throw TelemetryError.invalid("Empty telemetry capture") }
        let fields=accumulators.mapValues { $0.summary(count:count) }
        let summary=StreamingDiffSummary(passed:fields.values.allSatisfy { $0.failures==0 },records:count,
            absoluteTolerance:absoluteTolerance,relativeTolerance:relativeTolerance,fields:fields)
        try output?.finish(summary)
        return summary
    }
    private static func sameFile(_ a:URL,_ b:URL) -> Bool {
        let resolvedA=a.standardizedFileURL.resolvingSymlinksInPath(),resolvedB=b.standardizedFileURL.resolvingSymlinksInPath()
        if resolvedA==resolvedB { return true }
        guard let aa=try? FileManager.default.attributesOfItem(atPath:resolvedA.path),let bb=try? FileManager.default.attributesOfItem(atPath:resolvedB.path),
              let an=aa[.systemFileNumber] as? NSNumber,let bn=bb[.systemFileNumber] as? NSNumber,
              let ad=aa[.systemNumber] as? NSNumber,let bd=bb[.systemNumber] as? NSNumber else { return false }
        return an==bn && ad==bd
    }
}

private final class StreamingDiffOutput {
    private let destination:URL,temporary:URL
    private var handle:FileHandle?
    private let encoder=JSONEncoder()
    private var records=0
    init(to destination:URL) throws {
        self.destination=destination
        temporary=destination.deletingLastPathComponent().appendingPathComponent(".diff-\(UUID().uuidString).tmp")
        encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil) else { throw TelemetryError.invalid("Cannot create diff report") }
        do {
            handle=try FileHandle(forWritingTo:temporary)
            try handle!.write(contentsOf:Data("{\"schema\":2,\"divergenceLayout\":\"by-record\",\"divergence\":[\n".utf8))
        } catch { try? handle?.close();try? FileManager.default.removeItem(at:temporary);throw error }
    }
    func append(_ record:DivergenceRecord) throws {
        try autoreleasepool {
            var data=Data((records==0 ? "":",\n").utf8)
            data.append(try encoder.encode(record));try handle!.write(contentsOf:data);records += 1
        }
    }
    func finish(_ summary:StreamingDiffSummary) throws {
        // Both fragments are independently JSON-encoded, so field names and
        // values require no hand escaping. Strip only the opening object brace.
        let metadata=try encoder.encode(summary)
        var data=Data("\n],".utf8);data.append(contentsOf:metadata.dropFirst());data.append(10)
        try handle!.write(contentsOf:data);try handle!.synchronize();try handle!.close();handle=nil
        guard rename(temporary.path,destination.path)==0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
    }
    deinit { try? handle?.close();try? FileManager.default.removeItem(at:temporary) }
}
