// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import TORCSConfiguration
import TORCSRaceEngine
import TORCSSimulation
import TORCSTelemetry
import TORCSTrack

/// The authoritative native race runtime as a headless diagnostic. Native and
/// XML-only: no reference-engine import, no artwork and no window.
func runNativeRace(_ args: [String]) throws {
    var fixtures:URL?,summary:URL?,telemetry:URL?
    var laps=3,maxTicks=2_000_000,seed:UInt32=12345,cars=3,humanCar:Int?
    var kind: RaceSessionKind = .race,grid: StartingGridConfiguration = try .quickRace()
    var i=0
    while i<args.count {
        guard i+1<args.count else { throw TelemetryError.invalid("Missing race option value") }
        let value=args[i+1]
        switch args[i] {
        case "--race":
            switch value {
            case "race":kind = .race
            case "practice":kind = .practice
            case "qualifying":kind = .qualifying
            default:throw TelemetryError.invalid("Session must be race, practice or qualifying")
            }
        case "--fixtures":fixtures=URL(fileURLWithPath:value)
        case "--summary":summary=URL(fileURLWithPath:value)
        case "--telemetry":telemetry=URL(fileURLWithPath:value)
        case "--cars":guard let n=Int(value),(1...16).contains(n) else { throw TelemetryError.invalid("Cars must be 1…16") };cars=n
        case "--human":guard let n=Int(value),n>=0 else { throw TelemetryError.invalid("Invalid human car index") };humanCar=n
        case "--laps":guard let n=Int(value),(1...1000).contains(n) else { throw TelemetryError.invalid("Laps must be 1…1000") };laps=n
        case "--max-ticks":guard let n=Int(value),(1...10_000_000).contains(n) else { throw TelemetryError.invalid("Maximum ticks must be 1…10000000") };maxTicks=n
        case "--seed":guard let n=UInt32(value) else { throw TelemetryError.invalid("Invalid seed") };seed=n
        case "--grid":
            switch value {
            case "quickrace":grid=try .quickRace()
            case "code":grid=try StartingGridConfiguration()
            default:throw TelemetryError.invalid("Grid must be quickrace or code")
            }
        default:throw TelemetryError.invalid("Unknown race option: \(args[i])")
        }
        i += 2
    }
    guard let fixtures,let summary else {
        throw TelemetryError.invalid("--race requires --fixtures and --summary; optional --cars, --human, --laps, --grid quickrace|code, --max-ticks, --seed, --telemetry")
    }
    if let humanCar { guard humanCar<cars else { throw TelemetryError.invalid("The human car index must be inside the field") } }
    if let telemetry,telemetry.standardizedFileURL.resolvingSymlinksInPath()==summary.standardizedFileURL.resolvingSymlinksInPath() {
        throw TelemetryError.invalid("Summary and telemetry paths must differ")
    }
    let pinned=["155-DTM.xml":"7b069b816636ed85ace6b440d87aa400c3e54716170766df3e7a7483475f52bb",
        "Track-4WD-GrB.xml":"b08bc4a12ccfeff49ce1d608583a858cec69985d94aa057640d231016fed37eb",
        "aalborg.xml":"bfd4bfc66977a515e1d5bafb37e1698adaa9b05808d4da003f94d98a570a7b57",
        "surfaces.xml":"9e0c5fb78cd7d9fd635beed670750f69c851ab14a83e275fab2973330797bbb9",
        "objects.xml":"446e70833abb16942559315db5c4d224bd5a2a2da72b526e5d097c52fb2f0b37"]
    var content:[String:Data]=[:]
    for (name,hash) in pinned {
        let bytes=try Data(contentsOf:fixtures.appendingPathComponent(name))
        guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==hash else {
            throw TelemetryError.invalid("Unpinned race fixture: \(name)")
        }
        content[name]=bytes
    }
    let parameters=try ParameterDocument.parse(content["Track-4WD-GrB.xml"]!).merging(ParameterDocument.parse(content["155-DTM.xml"]!))
    let road=try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(content["aalborg.xml"]!,entities:[
        "default-surfaces":content["surfaces.xml"]!,"default-objects":content["objects.xml"]!],allowLegacyLatin1:true))
    let entries=(0..<cars).map { index in
        RaceEntry(parameters:parameters,kind:index==humanCar ? .human:.bt,team:"bt",skillLevel:3)
    }
    var race=try RaceRuntime(road:road,entries:entries,grid:grid,
        configuration:try RaceSessionConfiguration(kind:kind,laps:laps,countdown:true),seed:seed)
    let writer=try telemetry.map { try TelemetryWriter(to:$0) }
    var reported=Array(repeating:0,count:cars)
    // A human entry in a headless run holds the brake: there is nobody driving it.
    let humanCommand=DriverCommand(brake:1)
    for _ in 0..<maxTicks {
        try race.step(humanCommand:humanCommand)
        if let writer { try writer.append(VehicleTelemetry.record(race.simulation,scenario:"native-race-aalborg-155-DTM-v1")) }
        for car in 0..<cars where race.progress.laps[car].count>reported[car] {
            let lap=race.progress.laps[car].last!
            print("Car \(car) lap \(lap.number): \(lap.time) s at tick \(race.simulation.tick), valid=\(lap.valid)")
            reported[car]=race.progress.laps[car].count
        }
        if race.ended { break }
    }
    try writer?.finish()
    if race.result==nil { race.endRace() }
    let result=race.result!
    #if DEBUG
    let buildConfiguration="debug"
    #else
    let buildConfiguration="release"
    #endif
    let executableHash=SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0])))
        .map { String(format:"%02x",$0) }.joined()
    let report:[String:Any]=["schema":1,
        "implementation":"Native Swift race runtime, BT single-car policy drivers",
        "buildConfiguration":buildConfiguration,"executableSHA256":executableHash,
        "seed":seed,"cars":cars,"humanCar":humanCar ?? -1,"session":String(describing:kind),"targetLaps":laps,
        "ticks":race.simulation.tick,"raceTime":race.raceTime,"reason":result.reason.rawValue,
        "completed":result.reason == .completed,"classification":result.classification,
        "grid":["rows":grid.rows,"toStart":grid.toStart,"columnDistance":grid.columnDistance,
                "columnOffset":grid.columnOffset,"initialHeight":grid.initialHeight],
        "cars_detail":result.cars.map { car in
            ["car":car.car,"position":car.position,"laps":car.laps,"totalTime":car.totalTime,"bestLap":car.bestLap,
             "behindLeader":car.behindLeader,"lapsBehindLeader":car.lapsBehindLeader,"penalties":car.penalties,
             "penaltyTime":car.penaltyTime,"fuel":car.fuel,"damage":car.damage,"flags":car.flags,
             "finished":car.finished,"eliminated":car.eliminated,
             "driveCalls":race.driveCalls[car.car],"pitCalls":race.pitCalls[car.car],
             "laps_detail":car.completedLaps.map { ["number":$0.number,"time":$0.time,"valid":$0.valid] as [String:Any] }] as [String:Any]
        },
        "sourceHashes":pinned,
        "scope":"Original ReOneStep order, grid, rules and sorting; BT drivers have no opponent handling yet"]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:summary,options:.atomic)
    let laptotals=result.cars.map { "\($0.laps)" }.joined(separator:"/")
    print("Native race: \(cars) car(s), \(race.simulation.tick) ticks, laps \(laptotals) of \(laps); order \(result.classification); reason=\(result.reason.rawValue)")
}
