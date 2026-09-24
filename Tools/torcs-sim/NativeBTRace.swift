// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import TORCSConfiguration
import TORCSTrack
import TORCSRaceEngine
import TORCSTelemetry

/// Native, XML-only diagnostic; no reference-engine import or artwork required.
func runNativeBTRace(_ args: [String]) throws {
    var fixtures:URL?,summary:URL?,telemetry:URL?,laps=5,maxTicks=500000,seed:UInt32=12345
    var i=0
    while i<args.count {
        guard i+1<args.count else { throw TelemetryError.invalid("Missing robot option value") }
        let value=args[i+1]
        switch args[i] {
        case "--robot": guard value=="bt" else { throw TelemetryError.invalid("Only the native single-car BT driver is available") }
        case "--fixtures": fixtures=URL(fileURLWithPath:value)
        case "--summary": summary=URL(fileURLWithPath:value)
        case "--telemetry": telemetry=URL(fileURLWithPath:value)
        case "--laps": guard let n=Int(value),(1...1000).contains(n) else { throw TelemetryError.invalid("Laps must be 1…1000") };laps=n
        case "--max-ticks": guard let n=Int(value),(1...10000000).contains(n) else { throw TelemetryError.invalid("Maximum ticks must be 1…10000000") };maxTicks=n
        case "--seed": guard let n=UInt32(value) else { throw TelemetryError.invalid("Invalid seed") };seed=n
        default: throw TelemetryError.invalid("Unknown native robot option: \(args[i])")
        }
        i += 2
    }
    guard let fixtures,let summary else { throw TelemetryError.invalid("--robot bt requires --fixtures and --summary; optional --laps, --max-ticks, --seed, --telemetry") }
    if let telemetry,telemetry.standardizedFileURL.resolvingSymlinksInPath()==summary.standardizedFileURL.resolvingSymlinksInPath() { throw TelemetryError.invalid("Summary and telemetry paths must differ") }
    let pinned=["155-DTM.xml":"7b069b816636ed85ace6b440d87aa400c3e54716170766df3e7a7483475f52bb",
        "Track-4WD-GrB.xml":"b08bc4a12ccfeff49ce1d608583a858cec69985d94aa057640d231016fed37eb",
        "aalborg.xml":"bfd4bfc66977a515e1d5bafb37e1698adaa9b05808d4da003f94d98a570a7b57",
        "surfaces.xml":"9e0c5fb78cd7d9fd635beed670750f69c851ab14a83e275fab2973330797bbb9",
        "objects.xml":"446e70833abb16942559315db5c4d224bd5a2a2da72b526e5d097c52fb2f0b37"]
    var content:[String:Data]=[:]
    for (name,hash) in pinned {
        let bytes=try Data(contentsOf:fixtures.appendingPathComponent(name))
        guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==hash else { throw TelemetryError.invalid("Unpinned robot fixture: \(name)") }
        content[name]=bytes
    }
    let parameters=try ParameterDocument.parse(content["Track-4WD-GrB.xml"]!).merging(ParameterDocument.parse(content["155-DTM.xml"]!))
    let road=try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(content["aalborg.xml"]!,entities:[
        "default-surfaces":content["surfaces.xml"]!,"default-objects":content["objects.xml"]!],allowLegacyLatin1:true))
    var runtime=try BTSoloRuntime(road:road,parameters:parameters,laps:laps,seed:seed)
    let writer=try telemetry.map { try TelemetryWriter(to:$0) }
    var previousLaps=0
    for _ in 0..<maxTicks {
        try runtime.step()
        if let writer { try writer.append(VehicleTelemetry.record(runtime.simulation,scenario:"native-bt-0-aalborg-155-DTM-race-v1")) }
        if runtime.completedLaps.count>previousLaps,let lap=runtime.completedLaps.last {
            print("Native BT lap \(lap.number): \(lap.time) s at tick \(runtime.simulation.tick), valid=\(lap.valid)")
            previousLaps=runtime.completedLaps.count
        }
        if runtime.finished || runtime.retired { break }
    }
    try writer?.finish()
    let vehicle=runtime.simulation.cars[0]
    #if DEBUG
    let buildConfiguration="debug"
    #else
    let buildConfiguration="release"
    #endif
    let executableHash=SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]))).map { String(format:"%02x",$0) }.joined()
    let report:[String:Any]=["schema":1,"implementation":"Native Swift BT solo driver and physics","buildConfiguration":buildConfiguration,"executableSHA256":executableHash,"seed":seed,"targetLaps":laps,
        "ticks":runtime.simulation.tick,"raceTime":runtime.clock.time,"completed":runtime.finished && runtime.completedLaps.count==laps,
        "retired":runtime.retired,"driveCalls":runtime.driver.calls,"pitCalls":runtime.pitCalls,"fuel":vehicle.fuel,"damage":vehicle.damage,
        "laps":runtime.completedLaps.map { ["number":$0.number,"time":$0.time,"valid":$0.valid] as [String:Any] },
        "sourceHashes":pinned,"scope":"One car, diagnostic centerline start; no opponents, original grid or penalties",
        "finalPhysics":VehicleTelemetry.values(vehicle,track:road.geometry)]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:summary,options:.atomic)
    print("Native BT: \(runtime.completedLaps.count)/\(laps) laps, \(runtime.simulation.tick) ticks, \(runtime.pitCalls) pit callbacks; completed=\(runtime.finished)")
}
