// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation
import TORCSTelemetry

private enum NativeScenario: String {
    case stationary, acceleration, braking, cornering, combined
    case carCollision = "car-collision"
    var identifier: String { "aalborg-155-DTM-\(rawValue)-physics-v1" }
    func command(tick: Int,car: Int = 0) -> DriverCommand {
        switch self {
        case .carCollision: return car==0 ? .init(throttle:1,gear:1) : .init(brake:1)
        case .stationary: return .init(brake:1)
        case .acceleration: return .init(throttle:1,gear:1)
        case .braking: return tick<=1500 ? .init(throttle:1,gear:1) : .init(brake:1,gear:1)
        case .cornering: return .init(throttle:0.35,steering:0.2,gear:1)
        case .combined: return tick<=1500 ? .init(throttle:1,gear:1) : .init(brake:0.7,steering:0.25,gear:1)
        }
    }
}
func runNativeVehicleScenario(_ args: [String]) throws {
    var scenario: NativeScenario?, fixtures: URL?, output: URL?, ticks = 3000, seed: UInt32 = 12345, cars = 1
    var i = 0
    while i < args.count {
        guard i+1 < args.count else { throw TelemetryError.invalid("Missing option value") }
        switch args[i] {
        case "--scenario": scenario = NativeScenario(rawValue:args[i+1])
        case "--fixtures": fixtures = URL(fileURLWithPath:args[i+1],isDirectory:true)
        case "--telemetry": output = URL(fileURLWithPath:args[i+1])
        case "--ticks": guard let n = Int(args[i+1]), (1...20000).contains(n) else { throw TelemetryError.invalid("Vehicle ticks must be 1…20000") }; ticks = n
        case "--seed": guard let n = UInt32(args[i+1]) else { throw TelemetryError.invalid("Invalid seed") }; seed = n
        case "--cars": guard let n = Int(args[i+1]), (1...16).contains(n) else { throw TelemetryError.invalid("Cars must be 1…16") }; cars = n
        default: throw TelemetryError.invalid("Unknown vehicle option: \(args[i])")
        }
        i += 2
    }
    guard let scenario, let fixtures, let output else {
        throw TelemetryError.invalid("Usage: --scenario stationary|acceleration|braking|cornering|combined|car-collision --fixtures Tests/UnitTests/Fixtures --telemetry output.jsonl [--ticks 3000] [--seed 12345] [--cars 1]")
    }
    if scenario == .carCollision {
        if !args.contains("--cars") { cars = 2 }
        guard cars==2 else { throw TelemetryError.invalid("car-collision requires exactly two cars") }
    }
    let pinned = ["155-DTM.xml":"7b069b816636ed85ace6b440d87aa400c3e54716170766df3e7a7483475f52bb",
        "Track-4WD-GrB.xml":"b08bc4a12ccfeff49ce1d608583a858cec69985d94aa057640d231016fed37eb",
        "aalborg.xml":"bfd4bfc66977a515e1d5bafb37e1698adaa9b05808d4da003f94d98a570a7b57",
        "surfaces.xml":"9e0c5fb78cd7d9fd635beed670750f69c851ab14a83e275fab2973330797bbb9",
        "objects.xml":"446e70833abb16942559315db5c4d224bd5a2a2da72b526e5d097c52fb2f0b37"]
    var content: [String:Data] = [:]
    for (name,hash) in pinned {
        let bytes = try Data(contentsOf:fixtures.appendingPathComponent(name))
        guard SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == hash else { throw TelemetryError.invalid("Unpinned fixture: \(name)") }
        content[name] = bytes
    }
    let car = try ParameterDocument.parse(content["Track-4WD-GrB.xml"]!).merging(ParameterDocument.parse(content["155-DTM.xml"]!))
    let road = try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(content["aalborg.xml"]!,entities:[
        "default-surfaces":content["surfaces.xml"]!,"default-objects":content["objects.xml"]!],allowLegacyLatin1:true))
    let definition = try VehicleDynamicsDefinition(parameters:car)
    let writer = try TelemetryWriter(to:output)
    let settlingTicks: Int, randomDraws: UInt64
    if cars==1 {
        var simulation = try SingleVehicleSimulation(definition:definition,road:road,seed:seed)
        try simulation.settle()
        for tick in 1...ticks {
            try simulation.step(command:scenario.command(tick:tick))
            try writer.append(VehicleTelemetry.record(simulation,scenario:scenario.identifier))
        }
        settlingTicks = simulation.settlingTicks; randomDraws = simulation.random.draws
    } else {
        var simulation = try MultiVehicleSimulation(definition:definition,road:road,carCount:cars,seed:seed)
        try simulation.settle()
        for tick in 1...ticks {
            try simulation.step(commands:(0..<cars).map { scenario.command(tick:tick,car:$0) })
            try writer.append(VehicleTelemetry.record(simulation,scenario:scenario.identifier))
        }
        settlingTicks = simulation.settlingTicks; randomDraws = simulation.random.draws
    }
    try writer.finish()
    let metadata: [String:Any] = ["schema":1,"scenario":scenario.identifier,"implementation":"Native Swift active vehicle physics",
        "archiveSHA256":"f9c69e86d290295467451b01d7838d85005ba613644a6fe8a3f85a7c6a03cd4c",
        "seed":seed,"cars":cars,"ticks":ticks,"stepSeconds":0.002,"settlingTicks":settlingTicks,
        "startDistanceMetres":10,"trackLengthMetres":road.length,"trackSegments":road.geometry.mainSegments.count,
        "physicsFieldsPerCar":142,"sourceHashes":pinned,"randomAlgorithm":"Darwin rand-compatible Park–Miller, owned UInt32 state",
        "randomDraws":randomDraws,
        "executableSHA256":SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]))).map { String(format:"%02x",$0) }.joined(),
        "scope":"Active cars, ground/barriers, car/car and fixed-wall collisions including degenerate fixed pairs; invalid wall-as-car access is rejected; no removal/towing, pits, race engine or robots",
        "parser":"Native XML, units and category merge; legacy Latin-1 entity compatibility"]
    try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathExtension("metadata.json"),options:.atomic)
    print("Wrote \(ticks) native vehicle physics ticks (\(cars) cars, 142 fields per car, \(road.geometry.mainSegments.count) Aalborg segments) to \(output.path)")
}
