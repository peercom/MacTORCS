// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSTelemetry

final class StreamingTelemetryTests: XCTestCase {
    func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try FileManager.default.removeItem(at:url) }
        return url
    }
    func record(_ tick:Int=0,_ value:Double=2,scenario:String="test",key:String="x") -> TelemetryRecord {
        .init(scenario:scenario,tick:tick,time:Double(tick)*0.002,values:[key:value])
    }
    func testReaderChunkBoundariesUnicodeCRLFAndFinalLine() throws {
        let url=try folder().appendingPathComponent("input.jsonl")
        let source=[record(0,scenario:"車 🏁"),record(1,3,scenario:"車 🏁"),record(2,4,scenario:"車 🏁")]
        let lines=try source.map { try JSONEncoder().encode($0) }
        var data=Data([10]);data.append(lines[0]);data.append(contentsOf:[13,10,13,10,13,10,10]);data.append(lines[1]);data.append(10);data.append(lines[2])
        try data.write(to:url)
        for size in [1,2,7,64,65536] {
            let reader=try TelemetryReader(url,chunkBytes:size)
            for expected in source {
                let r=try XCTUnwrap(reader.next());XCTAssertEqual(r.tick,expected.tick);XCTAssertEqual(r.scenario,expected.scenario);XCTAssertEqual(r.values,expected.values)
            }
            XCTAssertNil(try reader.next());XCTAssertNil(try reader.next())
        }
    }
    func testReaderBoundsMalformedLineAndMissingFiles() throws {
        let dir=try folder(),url=dir.appendingPathComponent("input.jsonl")
        let data=try JSONEncoder().encode(record())
        for newline in [false,true] {
            var input=Data([13,10,13,10]);input.append(data);if newline { input.append(10) };try input.write(to:url)
            XCTAssertNotNil(try TelemetryReader(url,maximumRecordBytes:data.count,chunkBytes:7).next())
            XCTAssertThrowsError(try TelemetryReader(url,maximumRecordBytes:data.count-1,chunkBytes:3).next())
        }
        try Data("\n\n{broken}\n".utf8).write(to:url)
        XCTAssertThrowsError(try TelemetryReader(url,chunkBytes:2).next()) { XCTAssertTrue(String(describing:$0).contains("Line 3:")) }
        XCTAssertThrowsError(try TelemetryReader(dir.appendingPathComponent("missing")))
        XCTAssertThrowsError(try TelemetryReader(url,chunkBytes:0))
        XCTAssertThrowsError(try TelemetryReader(url,maximumRecordBytes:0))
    }
    func testStreamingMetricsAndEveryReportSampleMatchArrayOracle() throws {
        let dir=try folder(),reference=dir.appendingPathComponent("reference"),candidate=dir.appendingPathComponent("candidate"),output=dir.appendingPathComponent("report")
        let keys=["zero","small","normal","large","escaped\"\\\n車"]
        var a:[TelemetryRecord]=[],b:[TelemetryRecord]=[]
        for i in 0..<1000 {
            var r:[String:Double]=[:],c:[String:Double]=[:]
            for (j,key) in keys.enumerated() {
                let scale=[0,1e-200,1,1e200,1e-6][j],value=Double(i%17+1)*scale
                r[key]=value;c[key]=value+Double(i%23-11)*scale*0.001
            }
            a.append(.init(scenario:"metric-check",tick:i*2,time:Double(i)*0.004,values:r))
            b.append(.init(scenario:"metric-check",tick:i*2,time:Double(i)*0.004,values:c))
        }
        try TelemetryIO.write(a,to:reference);try TelemetryIO.write(b,to:candidate)
        let expected=try TelemetryDiff.compare(reference:a,candidate:b,absoluteTolerance:1e-205,relativeTolerance:0.001)
        let actual=try TelemetryDiff.compareFiles(reference:reference,candidate:candidate,absoluteTolerance:1e-205,relativeTolerance:0.001,reportURL:output)
        XCTAssertEqual(actual.passed,expected.passed);XCTAssertEqual(actual.records,expected.records)
        for key in keys {
            let x=try XCTUnwrap(actual.fields[key]),e=try XCTUnwrap(expected.fields[key])
            XCTAssertEqual(x.maximumAbsolute,e.maximumAbsolute);XCTAssertEqual(x.maximumRelative,e.maximumRelative)
            XCTAssertEqual(x.failures,e.failures);XCTAssertEqual(x.firstDivergentTick,e.firstDivergentTick)
            XCTAssertEqual(x.rms,e.rms,accuracy:max(e.rms*2e-14,1e-300))
        }
        struct Sample:Decodable { let tick:Int;let time:Double;let fields:[String:[String:Double]] }
        struct Report:Decodable { let schema:Int;let divergenceLayout:String;let passed:Bool;let divergence:[Sample] }
        let report=try JSONDecoder().decode(Report.self,from:Data(contentsOf:output))
        XCTAssertEqual(report.schema,2);XCTAssertEqual(report.divergenceLayout,"by-record");XCTAssertFalse(report.passed)
        XCTAssertEqual(report.divergence.count,1000)
        for (i,row) in report.divergence.enumerated() {
            XCTAssertEqual(row.tick,a[i].tick);XCTAssertEqual(row.time,a[i].time)
            XCTAssertEqual(Set(row.fields.keys),Set(keys))
            for key in keys {
                XCTAssertEqual(row.fields[key]?["absolute"],expected.fields[key]?.divergence[i].absolute)
                XCTAssertEqual(row.fields[key]?["relative"],expected.fields[key]?.divergence[i].relative)
            }
        }
        let repeatOutput=dir.appendingPathComponent("repeat")
        _=try TelemetryDiff.compareFiles(reference:reference,candidate:candidate,absoluteTolerance:1e-205,relativeTolerance:0.001,reportURL:repeatOutput)
        XCTAssertEqual(try Data(contentsOf:output),try Data(contentsOf:repeatOutput))
        let summaryOnly=try TelemetryDiff.compareFiles(reference:reference,candidate:candidate,absoluteTolerance:1e-205,relativeTolerance:0.001)
        XCTAssertEqual(summaryOnly.text,actual.text)
        print("STREAM_METRICS records=1000 fields=5 divergenceValues=10000 maximumRMSRelativeTolerance=2e-14")
    }
    func testInvalidCaptureNeverPublishesPartialReport() throws {
        let dir=try folder(),reference=dir.appendingPathComponent("reference"),candidate=dir.appendingPathComponent("candidate"),output=dir.appendingPathComponent("report")
        let old=Data("previous report".utf8);try old.write(to:output)
        let baseline=[record(),record(1)]
        let variants:[[TelemetryRecord]]=[[],[record()],[record(),record(1),record(2)],[record(),record()],
            [record(),record(2)],[record(),record(1,scenario:"different")],[record(),record(1,key:"other")],
            [record(),.init(scenario:"test",tick:1,time:0,values:["x":2])],
            [.init(scenario:"test",tick:-1,time:-0.002,values:["x":2]),record(1)]]
        try TelemetryIO.write(baseline,to:reference)
        for records in variants {
            try TelemetryIO.write(records,to:candidate)
            XCTAssertThrowsError(try TelemetryDiff.compareFiles(reference:reference,candidate:candidate,reportURL:output))
            XCTAssertEqual(try Data(contentsOf:output),old)
        }
        for tail in ["{broken}","{\"schema\":2,\"scenario\":\"test\",\"tick\":1,\"time\":0.002,\"values\":{\"x\":2}}", "{\"schema\":1,\"scenario\":\"test\",\"tick\":1,\"time\":0.002,\"values\":{\"x\":1e999}}"] {
            var data=try JSONEncoder().encode(record());data.append(10);data.append(Data(tail.utf8));try data.write(to:candidate)
            XCTAssertThrowsError(try TelemetryDiff.compareFiles(reference:reference,candidate:candidate,reportURL:output))
            XCTAssertEqual(try Data(contentsOf:output),old)
        }
        try TelemetryIO.write([],to:reference);try TelemetryIO.write([],to:candidate)
        XCTAssertThrowsError(try TelemetryDiff.compareFiles(reference:reference,candidate:candidate,reportURL:output))
        XCTAssertThrowsError(try TelemetryDiff.compareFiles(reference:reference,candidate:candidate,absoluteTolerance:.nan,reportURL:output))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:dir.path)),["reference","candidate","report"])
    }
    func testReportCannotOverwriteInputOrAliases() throws {
        let dir=try folder(),input=dir.appendingPathComponent("input"),link=dir.appendingPathComponent("link"),hard=dir.appendingPathComponent("hard")
        try TelemetryIO.write([record()],to:input)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:input)
        try FileManager.default.linkItem(at:input,to:hard)
        for output in [input,link,hard] {
            XCTAssertThrowsError(try TelemetryDiff.compareFiles(reference:input,candidate:input,reportURL:output))
        }
        let indirect=dir.appendingPathComponent("indirect")
        try FileManager.default.createSymbolicLink(at:indirect,withDestinationURL:hard)
        XCTAssertThrowsError(try TelemetryDiff.compareFiles(reference:input,candidate:input,reportURL:indirect))
        XCTAssertEqual(try TelemetryIO.read(input).count,1)
    }
}
