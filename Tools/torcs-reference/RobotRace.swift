// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import CReference
import TORCSReferenceSupport
import TORCSTelemetry

private struct RobotLap:Codable {
    var number:Int,tick:Int
    var time:Double
    var valid:Bool
}
private struct RobotRaceReport:Codable {
    var schema=1
    var scenario="original-bt-0-aalborg-155-DTM-race-v1"
    var seed:UInt32
    var targetLaps:Int,ticks:Int,completed:Bool
    var driveCalls:UInt64,pitCalls:Int,services:Int
    var raceTime:Double
    var laps:[RobotLap]
    var commandSHA256:String
    var finalPhysics:[String:Double]
    var raceState:Int,carState:Int
}
func runRobotRace(_ args:[String]) throws {
    var fixtures:URL?,summary:URL?,telemetry:URL?,commands:URL?
    var laps=5,maxTicks=500_000,seed:UInt32=12345
    var i=0
    while i<args.count {
        guard i+1<args.count else { throw TelemetryError.invalid("Missing robot option value") }
        let value=args[i+1]
        switch args[i] {
        case "--robot":guard value=="bt" else { throw TelemetryError.invalid("Only the original bt reference driver is available") }
        case "--fixtures":fixtures=URL(fileURLWithPath:value)
        case "--summary":summary=URL(fileURLWithPath:value)
        case "--telemetry":telemetry=URL(fileURLWithPath:value)
        case "--commands":commands=URL(fileURLWithPath:value)
        case "--laps":guard let n=Int(value),(1...1000).contains(n) else { throw TelemetryError.invalid("Laps must be 1…1000") };laps=n
        case "--max-ticks":guard let n=Int(value),(1...10_000_000).contains(n) else { throw TelemetryError.invalid("Maximum ticks must be 1…10000000") };maxTicks=n
        case "--seed":guard let n=UInt32(value) else { throw TelemetryError.invalid("Invalid seed") };seed=n
        default:throw TelemetryError.invalid("Unknown robot option: \(args[i])")
        }
        i += 2
    }
    guard let fixtures,let summary else { throw TelemetryError.invalid("--robot bt requires --fixtures and --summary; optional --laps, --max-ticks, --seed, --telemetry and --commands") }
    let outputs=[summary,telemetry,commands].compactMap{$0?.standardizedFileURL.resolvingSymlinksInPath().path}
    guard Set(outputs).count==outputs.count else { throw TelemetryError.invalid("Robot output paths must differ") }
    let content=try ReferenceContent(fixtures:fixtures,bt:true)
    let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,seed:seed,btDirectory:content.directory,laps:laps)
    defer { world.close() }
    let trace=try telemetry.map { try TelemetryWriter(to:$0) }
    let callbacks=try commands.map { try TelemetryWriter(to:$0) }
    var state=try world.robotStatus(),completedLaps:[RobotLap]=[],digest=SHA256()
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    if let trace { try trace.append(world.record(scenario:"original-bt-race-physics-v1")) }
    for _ in 0..<maxTicks {
        let previous=state
        state=try world.stepRobot()
        if state.laps>previous.laps,state.laps>1 {
            let lap=RobotLap(number:Int(state.laps)-1,tick:world.tick,time:state.lastLap,valid:previous.validLap != 0)
            completedLaps.append(lap)
            print("BT lap \(lap.number): \(lap.time) s at tick \(lap.tick)")
        }
        try autoreleasepool {
            if let trace { try trace.append(world.record(scenario:"original-bt-race-physics-v1")) }
            if state.lastDriveTick==UInt64(world.tick) {
                var values=try world.robotInput().reduce(into:[String:Double]()) { $0["input."+$1.key]=$1.value }
                values["output.throttle"]=Double(state.throttle);values["output.brake"]=Double(state.brake)
                values["output.steering"]=Double(state.steering);values["output.clutch"]=Double(state.clutch);values["output.gear"]=Double(state.gear)
                values["robot.time"]=state.robotTime;values["robot.delta"]=state.robotDelta;values["robot.calls"]=Double(state.driveCalls)
                let record=TelemetryRecord(scenario:"original-bt-callback-v1",tick:world.tick,time:Double(world.tick)*0.002,values:values)
                digest.update(data:try encoder.encode(record))
                try callbacks?.append(record)
            }
        }
        if state.raceState==4 || (state.carState & 0x800) != 0 { break }
    }
    try trace?.finish();try callbacks?.finish()
    let report=RobotRaceReport(seed:seed,targetLaps:laps,ticks:world.tick,completed:completedLaps.count==laps && (state.carState & 0x100) != 0,
        driveCalls:state.driveCalls,pitCalls:Int(state.pitCalls),services:Int(state.services),raceTime:state.time,laps:completedLaps,
        commandSHA256:digest.finalize().map{String(format:"%02x",$0)}.joined(),finalPhysics:try world.sample(),raceState:Int(state.raceState),carState:Int(state.carState))
    encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    try encoder.encode(report).write(to:summary,options:.atomic)
    print("BT reference: \(world.tick) ticks, \(state.driveCalls) drive callbacks, \(completedLaps.count)/\(laps) laps; completed=\(report.completed)")
}
