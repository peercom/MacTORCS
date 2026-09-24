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
private struct RobotGridSlot:Codable {
    var segment:Int,mode:Int
    var toStart,toRight,toMiddle,toLeft:Double
    var x,y,z,yaw,speed:Double
    init(_ slot:RefGridSlot) {
        segment=Int(slot.position.segment);mode=Int(slot.position.mode)
        toStart=Double(slot.position.toStart);toRight=Double(slot.position.toRight)
        toMiddle=Double(slot.position.toMiddle);toLeft=Double(slot.position.toLeft)
        x=Double(slot.x);y=Double(slot.y);z=Double(slot.z);yaw=Double(slot.yaw);speed=Double(slot.speed)
    }
}
private struct RobotGridConfiguration:Codable {
    var rows:Int
    var toStart,columnDistance,columnOffset,initialSpeed,initialHeight:Double
    var poleSide:String
    init(_ grid:ReferenceStartingGrid) {
        rows=grid.rows;toStart=Double(grid.toStart);columnDistance=Double(grid.columnDistance)
        columnOffset=Double(grid.columnOffset);initialSpeed=Double(grid.initialSpeed);initialHeight=Double(grid.initialHeight)
        poleSide=grid.poleLeft.map { $0 ? "left":"right" } ?? "original first turn"
    }
}
/// One car's original classification, rules and penalties at the final step.
private struct RobotCarReport:Codable {
    var index:Int
    var position:Int
    var laps:Int,remainingLaps:Int
    var raceTime:Double,bestLap:Double,lastLap:Double
    var timeBehindLeader:Double,lapsBehindLeader:Int
    var driveCalls:UInt64,pitCalls:Int,services:Int
    var carState:Int,eliminated:Bool,validLap:Bool
    var ruleState:Int,penalties:Int,firstPenalty:Int,firstPenaltyLapToClear:Int
    var penaltyTime:Double
    var completedLaps:[RobotLap]
    var grid:RobotGridSlot?
}
private struct RobotRaceReport:Codable {
    var schema=2
    var scenario:String
    var seed:UInt32
    var cars:Int
    var targetLaps:Int,ticks:Int,completed:Bool
    var raceTime:Double
    var raceState:Int
    /// Stable car indices in the final original race order, leader first.
    var classification:[Int]
    var grid:RobotGridConfiguration?
    var commandSHA256:String
    var carReports:[RobotCarReport]
    var finalPhysics:[String:Double]
    // Retained single-car fields so existing recorded values stay comparable.
    var driveCalls:UInt64,pitCalls:Int,services:Int
    var laps:[RobotLap]
    var carState:Int
}
func runRobotRace(_ args:[String]) throws {
    var fixtures:URL?,summary:URL?,telemetry:URL?,commands:URL?
    var laps=5,maxTicks=500_000,seed:UInt32=12345,cars=1
    var grid:ReferenceStartingGrid?,poleLeft:Bool?
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
        case "--cars":guard let n=Int(value),(1...10).contains(n) else { throw TelemetryError.invalid("Reference BT cars must be 1…10") };cars=n
        case "--grid":
            switch value {
            case "code":grid = .codeDefaults
            case "quickrace":grid = .quickRace
            default:throw TelemetryError.invalid("Grid must be code or quickrace")
            }
        case "--pole":
            switch value {
            case "left":poleLeft=true
            case "right":poleLeft=false
            default:throw TelemetryError.invalid("Pole must be left or right")
            }
        default:throw TelemetryError.invalid("Unknown robot option: \(args[i])")
        }
        i += 2
    }
    guard let fixtures,let summary else {
        throw TelemetryError.invalid("--robot bt requires --fixtures and --summary; optional --cars, --grid code|quickrace, --pole left|right, --laps, --max-ticks, --seed, --telemetry and --commands")
    }
    // A field needs the original grid builder; one car keeps the pinned
    // centreline diagnostic start unless a grid is requested explicitly.
    if cars>1,grid==nil { grid = .quickRace }
    if poleLeft != nil { guard grid != nil else { throw TelemetryError.invalid("--pole requires --grid") };grid?.poleLeft=poleLeft }
    let outputs=[summary,telemetry,commands].compactMap{$0?.standardizedFileURL.resolvingSymlinksInPath().path}
    guard Set(outputs).count==outputs.count else { throw TelemetryError.invalid("Robot output paths must differ") }
    let scenario=grid==nil ? "original-bt-0-aalborg-155-DTM-race-v1":"original-bt-field-aalborg-155-DTM-race-v1"
    let content=try ReferenceContent(fixtures:fixtures,bt:true,drivers:cars)
    let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,seed:seed,cars:cars,
        btDirectory:content.directory,laps:laps,grid:grid)
    defer { world.close() }
    let trace=try telemetry.map { try TelemetryWriter(to:$0) }
    let callbacks=try commands.map { try TelemetryWriter(to:$0) }
    let slots=grid==nil ? nil:try (0..<cars).map { RobotGridSlot(try world.gridSlot(car:$0)) }
    var states=try (0..<cars).map { try world.robotStatus(car:$0) }
    var completed=Array(repeating:[RobotLap](),count:cars)
    var digest=SHA256()
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let physicsScenario=grid==nil ? "original-bt-race-physics-v1":"original-bt-field-physics-v1"
    let callbackScenario=grid==nil ? "original-bt-callback-v1":"original-bt-field-callback-v1"
    if let trace { try trace.append(world.record(scenario:physicsScenario)) }
    var raceState=Int(states[0].raceState)
    for _ in 0..<maxTicks {
        let previous=states
        raceState=try world.stepRace()
        states=try (0..<cars).map { try world.robotStatus(car:$0) }
        for car in 0..<cars where states[car].laps>previous[car].laps && states[car].laps>1 {
            let lap=RobotLap(number:Int(states[car].laps)-1,tick:world.tick,time:states[car].lastLap,valid:previous[car].validLap != 0)
            completed[car].append(lap)
            print("BT car \(car) lap \(lap.number): \(lap.time) s at tick \(lap.tick)")
        }
        try autoreleasepool {
            if let trace { try trace.append(world.record(scenario:physicsScenario)) }
            guard let callbacks else { return }
            for car in 0..<cars where states[car].lastDriveTick==UInt64(world.tick) {
                let state=states[car]
                var values=try world.robotInput(car:car).reduce(into:[String:Double]()) { $0["input."+$1.key]=$1.value }
                values["car.index"]=Double(car)
                values["output.throttle"]=Double(state.throttle);values["output.brake"]=Double(state.brake)
                values["output.steering"]=Double(state.steering);values["output.clutch"]=Double(state.clutch);values["output.gear"]=Double(state.gear)
                values["robot.time"]=state.robotTime;values["robot.delta"]=state.robotDelta;values["robot.calls"]=Double(state.driveCalls)
                let record=TelemetryRecord(scenario:callbackScenario,tick:world.tick,time:Double(world.tick)*0.002,values:values)
                digest.update(data:try encoder.encode(record))
                try callbacks.append(record)
            }
        }
        // The original ends the race itself; a field also stops once no car can
        // still be simulated, which the single-car harness expressed as 0x800.
        if raceState==Int(0x4) { break }
        if states.allSatisfy({ $0.carState & 0x8FF != 0 }) { break }
    }
    try trace?.finish();try callbacks?.finish()
    let order=try world.classification()
    var reports:[RobotCarReport]=[]
    for car in 0..<cars {
        let state=states[car],race=try world.raceCarState(car:car)
        reports.append(RobotCarReport(index:car,position:Int(state.position),laps:Int(state.laps),remainingLaps:Int(state.remainingLaps),
            raceTime:state.totalTime,bestLap:state.bestLap,lastLap:state.lastLap,
            timeBehindLeader:race.timeBehindLeader,lapsBehindLeader:Int(race.lapsBehindLeader),
            driveCalls:state.driveCalls,pitCalls:Int(state.pitCalls),services:Int(state.services),
            carState:Int(state.carState),eliminated:race.eliminated != 0,validLap:state.validLap != 0,
            ruleState:Int(race.ruleState),penalties:Int(race.penalties),firstPenalty:Int(race.firstPenalty),
            firstPenaltyLapToClear:Int(race.firstPenaltyLapToClear),penaltyTime:Double(race.penaltyTime),
            completedLaps:completed[car],grid:slots?[car]))
    }
    let finished=reports.allSatisfy { $0.completedLaps.count==laps && $0.carState & 0x100 != 0 }
    let report=RobotRaceReport(scenario:scenario,seed:seed,cars:cars,targetLaps:laps,ticks:world.tick,
        completed:finished,raceTime:states[0].time,raceState:raceState,classification:order,
        grid:grid.map(RobotGridConfiguration.init),
        commandSHA256:digest.finalize().map{String(format:"%02x",$0)}.joined(),carReports:reports,
        finalPhysics:try world.sample(),driveCalls:states[0].driveCalls,pitCalls:Int(states[0].pitCalls),
        services:Int(states[0].services),laps:completed[0],carState:Int(states[0].carState))
    encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    try encoder.encode(report).write(to:summary,options:.atomic)
    let lapCounts=reports.map { "\($0.completedLaps.count)" }.joined(separator:"/")
    print("BT reference: \(cars) car(s), \(world.tick) ticks, laps \(lapCounts) of \(laps); order \(order); completed=\(report.completed)")
}
