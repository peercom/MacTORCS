// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CReference
import TORCSTelemetry
import CryptoKit
import TORCSTrack

public struct ReferenceCommand: Sendable {
    public var throttle: Float
    public var brake: Float
    public var steering: Float
    public var clutch: Float
    public var gear: Int32
    public init(throttle: Float = 0, brake: Float = 0, steering: Float = 0, clutch: Float = 0, gear: Int32 = 0) {
        self.throttle = throttle; self.brake = brake; self.steering = steering; self.clutch = clutch; self.gear = gear
    }
}

/// Serialized, test-only access to the original process-global TORCS engine.
/// Original race-manager "Starting Grid" values. `codeDefaults` are raceinit.cpp's
/// own fallbacks; `quickRace` are the values shipped in quickrace.xml. A track XML
/// "Starting Grid" section still overrides these inside the original routine.
public struct ReferenceStartingGrid: Sendable, Equatable {
    public var rows: Int
    public var toStart, columnDistance, columnOffset, initialSpeed, initialHeight: Float
    /// nil keeps the original inside-of-first-turn pole side.
    public var poleLeft: Bool?
    public init(rows: Int = 2,toStart: Float = 10,columnDistance: Float = 10,columnOffset: Float = 5,
                initialSpeed: Float = 0,initialHeight: Float = 0.3,poleLeft: Bool? = nil) {
        self.rows=rows;self.toStart=toStart;self.columnDistance=columnDistance;self.columnOffset=columnOffset
        self.initialSpeed=initialSpeed;self.initialHeight=initialHeight;self.poleLeft=poleLeft
    }
    public static let codeDefaults=Self()
    public static let quickRace=Self(rows:2,toStart:25,columnDistance:20,columnOffset:10,initialSpeed:0,initialHeight:0.2)
    var reference: RefStartingGrid {
        RefStartingGrid(rows:Int32(rows),poleSide:poleLeft.map { $0 ? 1:0 } ?? -1,toStart:toStart,
            columnDistance:columnDistance,columnOffset:columnOffset,initialSpeed:initialSpeed,initialHeight:initialHeight)
    }
}

/// Original tSituation race types.
public enum ReferenceRaceType: UInt32, Sendable { case practice=0, qualifying=1, race=2 }

/// Native gameplay targets must never depend on this module.
public final class ReferenceWorld {
    private var handle: OpaquePointer?
    public let carCount: Int
    public let trackLength: Double
    public let trackWidth: Double
    public let trackSegments: Int
    public private(set) var tick: Int = 0
    private let fields: [String]
    public init(track: URL, car: URL, category: URL, seed: UInt32 = 12345, cars: Int = 1,
                startDistance: Float = 10, spacing: Float = 10,lateralPosition: Float? = nil, btDirectory: URL? = nil, laps: Int = 5,
                grid: ReferenceStartingGrid? = nil) throws {
        guard (1...16).contains(cars) else { throw TelemetryError.invalid("Reference car count must be 1…16") }
        if btDirectory != nil {
            guard (1...1000).contains(laps) else { throw TelemetryError.invalid("BT oracle requires 1…1000 laps") }
            // Ten original BT driver indices exist; a field needs a starting grid.
            guard grid != nil || cars==1 else { throw TelemetryError.invalid("A BT field requires an original starting grid") }
            guard cars==1 || (1...10).contains(cars) else { throw TelemetryError.invalid("BT provides ten driver indices") }
        }
        let created: OpaquePointer?
        if let btDirectory {
            if let grid {
                var value=grid.reference
                created=ref_world_bt_field_create(track.path,car.path,category.path,btDirectory.path,seed,Int32(laps),Int32(cars),&value)
            } else {
                created=ref_world_bt_create(track.path,car.path,category.path,btDirectory.path,seed,Int32(laps))
            }
        } else if let grid {
            // Placement-only grid world: no driver is loaded, so the original
            // grid can be compared for more cars than BT has driver indices.
            var value=grid.reference
            created=ref_world_grid_create(track.path,car.path,category.path,seed,Int32(cars),&value)
        } else {
            created=ref_world_create_lateral(track.path, car.path, category.path, seed, Int32(cars), startDistance, spacing,lateralPosition ?? .nan)
        }
        guard let handle=created else {
            throw TelemetryError.invalid(String(cString: ref_world_error()))
        }
        self.handle = handle; carCount = cars
        trackWidth = ref_world_track_width(handle)
        trackLength = ref_world_track_length(handle); trackSegments = Int(ref_world_track_segments(handle))
        fields = (0..<ref_world_field_count()).map { String(cString: ref_world_field_name($0)) }
    }
    deinit { close() }
    public func close() {
        if let handle { ref_world_destroy(handle); self.handle = nil }
    }
    public func settle(ticks: Int = 501) throws {
        guard (0...10000).contains(ticks), let handle, ref_world_settle(handle, Int32(ticks)) == 1 else {
            throw TelemetryError.invalid("Cannot settle reference world after measured stepping, or invalid settling count")
        }
    }
    public func command(_ command: ReferenceCommand, car: Int = 0) throws {
        guard (0..<carCount).contains(car), let handle,
              ref_world_command(handle, Int32(car), command.throttle, command.brake, command.steering, command.clutch, command.gear) == 1 else {
            throw TelemetryError.invalid("Invalid reference driver command or closed world")
        }
    }
    public func step(raceState: UInt32 = 1) throws {
        guard let handle, ref_world_step_mode(handle,raceState) == 1 else { throw TelemetryError.invalid("Reference world is closed") }
        tick += 1
    }
    public func robotInput() throws -> [String:Double] {
        var values=[Double](repeating:0,count:fields.count)
        guard let handle,ref_world_bt_input(handle,&values,Int32(values.count))==fields.count else { throw TelemetryError.invalid("No BT drive input captured") }
        return Dictionary(uniqueKeysWithValues:zip(fields,values))
    }
    public func robotStatus() throws -> RefRobotRaceState {
        var state=RefRobotRaceState()
        guard let handle,ref_world_bt_status(handle,&state)==1 else { throw TelemetryError.invalid("No BT race is active") }
        return state
    }
    @discardableResult public func stepRobot() throws -> RefRobotRaceState {
        var state=RefRobotRaceState()
        guard let handle,ref_world_bt_step(handle,&state)==1 else { throw TelemetryError.invalid("BT race ended or is not active") }
        tick += 1;return state
    }
    /// One original ReOneStep for the whole field. Returns the original race state.
    @discardableResult public func stepRace() throws -> Int {
        guard let handle else { throw TelemetryError.invalid("Reference world is closed") }
        let state=ref_world_race_step(handle)
        guard state >= 0 else { throw TelemetryError.invalid("BT race ended or is not active") }
        tick += 1;return Int(state)
    }
    public func robotStatus(car: Int) throws -> RefRobotRaceState {
        var state=RefRobotRaceState()
        guard (0..<carCount).contains(car),let handle,ref_world_bt_car_status(handle,Int32(car),&state)==1 else {
            throw TelemetryError.invalid("No BT race is active for car \(car)")
        }
        return state
    }
    public func robotInput(car: Int) throws -> [String:Double] {
        var values=[Double](repeating:0,count:fields.count)
        guard (0..<carCount).contains(car),let handle,
              ref_world_bt_car_input(handle,Int32(car),&values,Int32(values.count))==fields.count else {
            throw TelemetryError.invalid("No BT drive input captured for car \(car)")
        }
        return Dictionary(uniqueKeysWithValues:zip(fields,values))
    }
    public func robotObservation(car: Int = 0) throws -> RefBTObservation {
        var value=RefBTObservation()
        guard (0..<carCount).contains(car),let handle,ref_world_bt_car_observation(handle,Int32(car),&value)==1 else {
            throw TelemetryError.invalid("No BT observation captured for car \(car)")
        }
        return value
    }
    /// The whole field as the original opponent model saw it at this callback.
    public func robotField(car: Int) throws -> [RefBTFieldCar] {
        var values=[RefBTFieldCar](repeating:RefBTFieldCar(),count:carCount)
        guard (0..<carCount).contains(car),let handle,
              ref_world_bt_field(handle,Int32(car),&values,Int32(values.count))==carCount else {
            throw TelemetryError.invalid("No BT field captured for car \(car)")
        }
        return values
    }
    public func gridSlot(car: Int) throws -> RefGridSlot {
        var value=RefGridSlot()
        guard (0..<carCount).contains(car),let handle,ref_world_grid_slot(handle,Int32(car),&value)==1 else {
            throw TelemetryError.invalid("No original grid placement is available for car \(car)")
        }
        return value
    }
    public func raceCarState(car: Int) throws -> RefRaceCarState {
        var value=RefRaceCarState()
        guard (0..<carCount).contains(car),let handle,ref_world_race_car_state(handle,Int32(car),&value)==1 else {
            throw TelemetryError.invalid("No original race state is available for car \(car)")
        }
        return value
    }
    /// Original rule inputs. `rules` is the RmRaceRules bitmask: 1 corner-cut
    /// invalidation, 2 wall-hit invalidation, 4 race corner-cut time penalty.
    /// Penalties and the lap-time DNF rule need skill 3+ and a robot driver.
    public func configureRules(_ rules: UInt32,raceType: ReferenceRaceType = .race,skill: Int = 3,human: Bool = false) throws {
        guard (0...4).contains(skill),let handle,
              ref_world_race_configure(handle,rules,raceType.rawValue,Int32(skill),human ? 1:2)==1 else {
            throw TelemetryError.invalid("Invalid original race rule configuration")
        }
    }
    /// The original total speed, which the corner-cutting time penalty reads.
    public func setPublicSpeed(_ speed: Float,car: Int) throws {
        guard (0..<carCount).contains(car),let handle,ref_world_race_public_speed(handle,Int32(car),speed)==1 else {
            throw TelemetryError.invalid("Invalid public speed for car \(car)")
        }
    }
    /// Stable car indices in the current original race order (leader first).
    public func classification() throws -> [Int] {
        var order=[Int32](repeating:0,count:carCount)
        guard let handle,ref_world_race_classification(handle,&order,Int32(carCount))==1 else {
            throw TelemetryError.invalid("No original classification is available")
        }
        return order.map(Int.init)
    }
    public func sample(car: Int = 0) throws -> [String: Double] {
        guard (0..<carCount).contains(car), let handle else { throw TelemetryError.invalid("Invalid car or closed reference world") }
        var values = [Double](repeating: 0, count: fields.count)
        guard ref_world_read(handle, Int32(car), &values, Int32(values.count)) == fields.count else {
            throw TelemetryError.invalid(String(cString: ref_world_error()))
        }
        return Dictionary(uniqueKeysWithValues: zip(fields, values))
    }
    public func record(scenario: String) throws -> TelemetryRecord {
        var values: [String: Double] = [:]
        for car in 0..<carCount {
            for (name, value) in try sample(car: car) { values["car.\(car).\(name)"] = value }
        }
        return TelemetryRecord(scenario: scenario, tick: tick, time: Double(tick) * 0.002, values: values)
    }
    public func parameterNumber(section: String, key: String, fallback: Float = .nan) throws -> Float {
        guard let handle else { throw TelemetryError.invalid("Reference world is closed") }
        return ref_world_parameter_number(handle, 0, section, key, fallback)
    }
    public func parameterString(section: String, key: String) throws -> String? {
        guard let handle else { throw TelemetryError.invalid("Reference world is closed") }
        return ref_world_parameter_string(handle, 0, section, key).map { String(cString: $0) }
    }
    public func massProperties() throws -> RefMassProperties {
        var output = RefMassProperties()
        guard let handle, ref_world_mass_properties(handle, 0, &output) == 1 else { throw TelemetryError.invalid("Reference world is closed") }
        return output
    }
}

/// Build an installed-layout XML-only reference directory from pinned fixtures.
/// No source fixture is edited, no legacy model/audio/texture is copied.
public final class ReferenceContent {
    public static let sourceHashes = [
        "155-DTM.xml": "7b069b816636ed85ace6b440d87aa400c3e54716170766df3e7a7483475f52bb",
        "aalborg.xml": "bfd4bfc66977a515e1d5bafb37e1698adaa9b05808d4da003f94d98a570a7b57",
        "surfaces.xml": "9e0c5fb78cd7d9fd635beed670750f69c851ab14a83e275fab2973330797bbb9",
        "objects.xml": "446e70833abb16942559315db5c4d224bd5a2a2da72b526e5d097c52fb2f0b37",
        "Track-4WD-GrB.xml": "b08bc4a12ccfeff49ce1d608583a858cec69985d94aa057640d231016fed37eb"
    ]
    public let directory: URL
    public let track: URL
    public let car: URL
    public let category: URL
    public init(fixtures: URL, bt: Bool = false, drivers: Int = 1) throws {
        let btDrivers = bt ? drivers : 0
        guard (0...10).contains(btDrivers) else { throw TelemetryError.invalid("BT provides ten driver indices") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TORCS-reference-" + UUID().uuidString)
        directory = base
        track = base.appendingPathComponent("tracks/road/aalborg/aalborg.xml")
        car = base.appendingPathComponent("cars/155-DTM/155-DTM.xml")
        category = base.appendingPathComponent("categories/Track-4WD-GrB.xml")
        let files = ["aalborg.xml": track, "155-DTM.xml": car, "Track-4WD-GrB.xml": category,
                     "surfaces.xml": base.appendingPathComponent("data/tracks/surfaces.xml"),
                     "objects.xml": base.appendingPathComponent("data/tracks/objects.xml")]
        do {
            for (name, destination) in files {
                var bytes = try Data(contentsOf: fixtures.appendingPathComponent(name))
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard hash == Self.sourceHashes[name] else { throw TelemetryError.invalid("Unpinned reference content: \(name)") }
                if name == "objects.xml" {
                    // The pinned file has an ISO-8859-1 copyright byte but says
                    // UTF-8. Correct only the staged entity's declaration. The
                    // original bytes, including every numeric value, are retained.
                    guard String(data: bytes, encoding: .utf8) == nil,
                          let range = bytes.range(of: Data("encoding=\"UTF-8\"".utf8)) else {
                        throw TelemetryError.invalid("objects.xml differs from the expected legacy encoding fixture")
                    }
                    bytes.replaceSubrange(range, with: Data("encoding=\"ISO-8859-1\"".utf8))
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination, options: .atomic)
            }
            if btDrivers>0 {
                let bytes=try Data(contentsOf:fixtures.appendingPathComponent("Robots/bt/0/default.xml"))
                let hash=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
                guard hash=="f8ba8bf45d243986b52d2b2ed924d17c1b11937dfc31132b6341b8b7004003f2" else { throw TelemetryError.invalid("Unpinned BT default setup") }
                // Every driver index receives the same pinned BT-0 setup. Real
                // installations ship per-index setups; this is a fixed oracle
                // fixture, so the field differs only by grid slot and index.
                for index in 0..<btDrivers {
                    let destination=base.appendingPathComponent("drivers/bt/\(index)/default.xml")
                    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try bytes.write(to:destination)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

public enum VehicleScenario: String, CaseIterable, Codable, Sendable {
    case stationary, acceleration, braking, cornering, combined
    case carCollision = "car-collision"
    public func command(tick: Int, car: Int = 0) -> ReferenceCommand {
        switch self {
        case .stationary: return .init(brake: 1, gear: 0)
        case .acceleration: return .init(throttle: 1, gear: 1)
        case .braking: return tick <= 1500 ? .init(throttle: 1, gear: 1) : .init(brake: 1, gear: 1)
        case .cornering: return .init(throttle: 0.35, steering: 0.2, gear: 1)
        case .combined: return tick <= 1500 ? .init(throttle: 1, gear: 1) : .init(brake: 0.7, steering: 0.25, gear: 1)
        case .carCollision: return car == 0 ? .init(throttle: 1, gear: 1) : .init(brake: 1, gear: 0)
        }
    }
    public var identifier: String { "aalborg-155-DTM-\(rawValue)-physics-v1" }
}


extension ReferenceWorld {
    /// Diagnostic transfer of original geometry only. Native production content
    /// loading must construct TrackGeometry without calling this test-only adapter.
    public func trackCamera(at index: Int) -> (name: String, position: SIMD3<Float>)? {
        var position = [Float](repeating: 0, count: 3)
        guard let name = ref_world_track_camera(handle, Int32(index), &position) else { return nil }
        return (String(cString: name), SIMD3(position[0],position[1],position[2]))
    }
    public func trackBounds() throws -> SIMD3<Float> {
        guard let handle else { throw TelemetryError.invalid("Closed reference world") }
        let p = ref_world_track_bounds(handle); return SIMD3(p.x, p.y, p.z)
    }
    public func trackGeometry() throws -> TrackGeometry {
        guard let handle else { throw TelemetryError.invalid("Closed reference world") }
        func vector(_ p: RefTrackVector) -> SIMD3<Float> { SIMD3(p.x, p.y, p.z) }
        var segments: [TrackSegment] = []
        for index in 0..<ref_world_geometry_count(handle) {
            var s = RefTrackSegment()
            guard ref_world_geometry_segment(handle, index, &s) == 1,
                  let curve = TrackCurve(rawValue: Int(s.curve)), let role = TrackRole(rawValue: Int(s.role)),
                  let style = TrackStyle(rawValue: Int(s.style)) else { throw TelemetryError.invalid("Unsupported reference geometry") }
            let name = ref_world_geometry_name(handle, index).map { String(cString: $0) } ?? ""
            let material = ref_world_geometry_material(handle, index).map { String(cString: $0) } ?? ""
            segments.append(TrackSegment(name: name, upstreamID: Int(s.upstreamID), curve: curve, role: role, style: style,
                mainIndex: Int(s.mainIndex), previous: Int(s.previous), next: Int(s.next),
                right: s.right < 0 ? nil : Int(s.right), left: s.left < 0 ? nil : Int(s.left),
                length: s.length, width: s.width, startWidth: s.startWidth, endWidth: s.endWidth, distanceFromStart: s.distanceFromStart,
                radius: s.radius, rightRadius: s.rightRadius, leftRadius: s.leftRadius, arc: s.arc,
                center: vector(s.center), startRight: vector(s.startRight), startLeft: vector(s.startLeft),
                endRight: vector(s.endRight), endLeft: vector(s.endLeft), headingStart: s.headingStart, headingEnd: s.headingEnd,
                pitchLeft: s.pitchLeft, pitchRight: s.pitchRight, bankStart: s.bankStart, bankEnd: s.bankEnd, centerStart: s.centerStart,
                longitudinalSlope: s.longitudinalSlope, bankingSlope: s.bankingSlope, widthSlope: s.widthSlope, curbHeight: s.curbHeight,
                rightNormal: SIMD2(s.rightNormalX, s.rightNormalY),
                surface: TrackSurface(material: material, friction: s.friction, rebound: s.rebound, rollingResistance: s.rollingResistance,
                    roughness: s.roughness, roughWaveNumber: s.roughWaveNumber, damage: s.damage), raceFlags: s.raceFlags,
                rightBarrier: try trackBarrier(segment: Int(index), side: .right), leftBarrier: try trackBarrier(segment: Int(index), side: .left)))
        }
        return try TrackGeometry(segments: segments)
    }
    public func trackSample(_ position: TrackLocalPosition, origin: TrackLateralOrigin = .right) throws -> RefTrackSample {
        var result = RefTrackSample()
        let p = RefTrackPosition(segment: Int32(position.segment), mode: Int32(position.mode.rawValue), toStart: position.toStart,
                                 toRight: position.toRight, toMiddle: position.toMiddle, toLeft: position.toLeft)
        guard let handle, ref_world_track_local(handle, p, Int32(origin.rawValue), &result) == 1 else {
            throw TelemetryError.invalid("Invalid reference track sample")
        }
        return result
    }
    public func trackPosition(_ point: SIMD2<Float>, startingAt start: Int, mode: TrackPositionMode) throws -> TrackLocalPosition {
        var result = RefTrackPosition()
        guard let handle, ref_world_track_global(handle, Int32(start), point.x, point.y, Int32(mode.rawValue), &result) == 1 else {
            throw TelemetryError.invalid("Invalid reference track position")
        }
        return TrackLocalPosition(segment: Int(result.segment), toStart: result.toStart, toRight: result.toRight,
                                  toMiddle: result.toMiddle, toLeft: result.toLeft, mode: mode)
    }
    public func trackNeighbour(main: Int, current: Int, side: TrackSide) throws -> Int {
        guard let handle else { throw TelemetryError.invalid("Closed reference world") }
        let result = ref_world_track_neighbour(handle, Int32(main), Int32(current), Int32(side.rawValue))
        guard result >= 0 else { throw TelemetryError.invalid("Invalid reference neighbour query") }
        return Int(result)
    }
}

extension ReferenceWorld {
    public func trackBarrier(segment: Int, side: TrackSide) throws -> TrackBarrier? {
        guard let handle else { throw TelemetryError.invalid("Closed reference world") }
        var b = RefTrackBarrier()
        guard ref_world_barrier(handle, Int32(segment), Int32(side.rawValue), &b) == 1 else { return nil }
        guard let style = TrackStyle(rawValue: Int(b.style)),
              let material = ref_world_barrier_material(handle, Int32(segment), Int32(side.rawValue)) else {
            throw TelemetryError.invalid("Invalid reference barrier")
        }
        return TrackBarrier(style: style, width: b.width, height: b.height,
            surface: TrackSurface(material: String(cString: material), friction: b.friction, rebound: b.rebound,
                rollingResistance: b.rollingResistance, roughness: b.roughness, roughWaveNumber: b.roughWaveNumber, damage: b.damage),
            normal: SIMD2(b.normalX, b.normalY))
    }
    public func trackPits() throws -> TrackPits {
        var p = RefTrackPits()
        guard let handle, ref_world_pits(handle, &p) == 1,
              let type = TrackPitType(rawValue: Int(p.type)), (0..<100000).contains(p.capacity) else {
            throw TelemetryError.invalid("Invalid reference pits")
        }
        var positions: [TrackLocalPosition] = []
        for index in 0..<p.capacity {
            var position = RefTrackPosition()
            guard ref_world_pit_position(handle, index, &position) == 1,
                  let mode = TrackPositionMode(rawValue: Int(position.mode)) else { throw TelemetryError.invalid("Invalid reference pit position") }
            positions.append(TrackLocalPosition(segment: Int(position.segment), toStart: position.toStart, toRight: position.toRight,
                toMiddle: position.toMiddle, toLeft: position.toLeft, mode: mode))
        }
        func optionalIndex(_ index: Int32) -> Int? { index < 0 ? nil : Int(index) }
        let side: TrackSide? = p.side == 1 ? .right : (p.side == 2 ? .left : nil)
        return TrackPits(type: type, side: side, entry: optionalIndex(p.entry), start: optionalIndex(p.start),
            end: optionalIndex(p.end), exit: optionalIndex(p.exit), stallLength: p.stallLength,
            laneWidth: p.laneWidth, speedLimit: p.speedLimit, positions: positions)
    }
    public func pitDistance(from position: TrackLocalPosition, stall: Int) throws -> SIMD2<Float> {
        var longitudinal: Float = 0, lateral: Float = 0
        let p = RefTrackPosition(segment: Int32(position.segment), mode: Int32(position.mode.rawValue), toStart: position.toStart,
            toRight: position.toRight, toMiddle: position.toMiddle, toLeft: position.toLeft)
        guard let handle, ref_world_pit_distance(handle, Int32(stall), p, &longitudinal, &lateral) == 1 else {
            throw TelemetryError.invalid("Invalid reference pit distance")
        }
        return SIMD2(longitudinal, lateral)
    }
}

extension ReferenceWorld {
    public func configureTransmission(xml: String) throws {
        guard let handle, ref_world_configure_transmission_xml(handle, xml) == 1 else { throw TelemetryError.invalid("Cannot configure reference transmission after dynamics, or invalid fixture") }
    }
    public func transmissionSetup() throws -> RefTransmissionSetup {
        var output = RefTransmissionSetup()
        guard let handle, ref_world_transmission_setup(handle, &output) == 1 else { throw TelemetryError.invalid("Invalid reference transmission setup") }
        return output
    }
    public func transmissionState() throws -> RefTransmissionState {
        var output = RefTransmissionState()
        guard let handle, ref_world_transmission_state(handle, &output) == 1 else { throw TelemetryError.invalid("Invalid reference transmission state") }
        return output
    }
    public func preparePowertrain(_ control: RefPowertrainControl) throws -> RefTransmissionState {
        var output = RefTransmissionState()
        guard let handle, ref_world_powertrain_prepare(handle, control, &output) == 1 else { throw TelemetryError.invalid("Invalid reference powertrain controls") }
        return output
    }
    public func stepDrivenGear(_ input: RefRunningGearInput) throws -> (RefRunningGearStep, RefTransmissionState) {
        var wheels = RefRunningGearStep(), state = RefTransmissionState()
        guard let handle, ref_world_driven_gear_step(handle, input, &wheels, &state) == 1 else { throw TelemetryError.invalid("Invalid reference driven wheel step") }
        return (wheels, state)
    }
    public func engineSetup() throws -> (RefEngineSetup, [RefEngineCurvePoint]) {
        var result = RefEngineSetup(), curve = [RefEngineCurvePoint](repeating: .init(), count: 10000)
        guard let handle, ref_world_engine_setup(handle, &result, &curve, Int32(curve.count)) == 1 else { throw TelemetryError.invalid("Invalid original engine setup request") }
        return (result, Array(curve.prefix(Int(result.curveCount))))
    }
    public func engineStep(_ input: RefEngineInput) throws -> RefEngineOutput {
        var result = RefEngineOutput()
        guard let handle, ref_world_engine_step(handle, input, &result) == 1 else { throw TelemetryError.invalid("Invalid original engine step") }
        return result
    }
    public func differentialConfiguration(_ index: Int) throws -> RefDifferentialConfig {
        var result = RefDifferentialConfig()
        guard let handle, ref_world_differential_config(handle, Int32(index), &result) == 1 else { throw TelemetryError.invalid("Invalid original differential configuration") }
        return result
    }
    public func differentialStep(configuration: RefDifferentialConfig, driveTorque: Float, first: RefDriveAxis, second: RefDriveAxis,
                                 outputInertias: SIMD2<Float>, primary: Bool, engine: RefEngineInput) throws -> RefDifferentialOutput {
        var result = RefDifferentialOutput()
        guard let handle, ref_world_differential_step(handle, configuration, driveTorque, first, second, outputInertias.x,
                outputInertias.y, primary ? 1 : 0, engine, &result) == 1 else { throw TelemetryError.invalid("Invalid original differential step") }
        return result
    }
    public func runningGear(car: Int = 0) throws -> RefRunningGear {
        var result = RefRunningGear()
        guard let handle, ref_world_running_gear(handle, Int32(car), &result) == 1 else { throw TelemetryError.invalid("Invalid original running gear request") }
        return result
    }
    public func stepRunningGear(_ input: RefRunningGearInput) throws -> RefRunningGearStep {
        var result = RefRunningGearStep()
        guard let handle, ref_world_running_gear_step(handle, input, &result) == 1 else { throw TelemetryError.invalid("Invalid original running gear step") }
        return result
    }
    public func wheelRide(_ input: RefWheelRideInput) throws -> RefWheelRideResult {
        var result = RefWheelRideResult()
        guard let handle, ref_world_wheel_ride(handle, input, &result) == 1 else { throw TelemetryError.invalid("Invalid original wheel ride input") }
        return result
    }
    public func wheelForce(_ input: RefWheelForceInput) throws -> RefWheelForceResult {
        var result = RefWheelForceResult()
        guard let handle, ref_world_wheel_force(handle, input, &result) == 1 else { throw TelemetryError.invalid("Invalid original wheel force input") }
        return result
    }
}

extension ReferenceWorld {
    public func aeroSetup() throws -> RefAeroSetup {
        var output = RefAeroSetup()
        guard let handle, ref_world_aero_setup(handle,&output) == 1 else { throw TelemetryError.invalid("Invalid reference aero setup") }
        return output
    }
}

extension ReferenceWorld {
    public func chassisCorners() throws -> [RefTrackVector] {
        var output = [RefTrackVector](repeating:.init(),count:4)
        guard let handle, ref_world_chassis_corners(handle,&output,4) == 1 else { throw TelemetryError.invalid("Invalid reference chassis setup") }
        return output
    }
    public func chassisStep(_ input: RefChassisInput) throws -> RefChassisOutput {
        var output = RefChassisOutput()
        guard let handle, ref_world_chassis_step(handle,input,&output) == 1 else { throw TelemetryError.invalid("Invalid reference chassis input") }
        return output
    }
}

extension ReferenceWorld {
    public func initializeVehicle(_ input: RefChassisInput) throws {
        guard let handle, ref_world_vehicle_initialize(handle,input) == 1 else { throw TelemetryError.invalid("Cannot initialize reference vehicle after dynamics") }
    }
    public func stepVehicleWithoutCollision(_ input: RefVehicleControl) throws -> RefVehicleOutput {
        var output = RefVehicleOutput()
        guard let handle, ref_world_vehicle_step_without_collision(handle,input,&output) == 1 else { throw TelemetryError.invalid("Invalid reference vehicle step") }
        return output
    }
}

extension ReferenceWorld {
    public func collideEnvironment(_ input: RefEnvironmentInput) throws -> RefEnvironmentOutput {
        var output = RefEnvironmentOutput()
        guard let handle, ref_world_environment_step(handle,input,&output) == 1 else { throw TelemetryError.invalid("Invalid reference environment input") }
        return output
    }
    public func stepVehicle(_ input: RefVehicleControl, damageFactor: Float) throws -> RefVehicleOutput {
        var output = RefVehicleOutput()
        guard let handle, ref_world_vehicle_step(handle,input,damageFactor,&output) == 1 else { throw TelemetryError.invalid("Invalid reference vehicle input") }
        return output
    }
}

extension ReferenceWorld {
    public func driverSetup() throws -> RefDriverSetup {
        var output = RefDriverSetup()
        guard let handle, ref_world_driver_setup(handle,&output) == 1 else { throw TelemetryError.invalid("Invalid reference driver setup") }
        return output
    }
    public func stepSimulation(command: RefDriverCommand, carFlags: UInt32 = 0, raceState: UInt32 = 1,
        randomSeed: UInt32, damageFactor: Float = 1, tireFactor: Float = 0) throws -> RefSimulationOutput {
        var output = RefSimulationOutput()
        guard let handle, ref_world_simulation_step(handle,command,carFlags,raceState,randomSeed,damageFactor,tireFactor,&output) == 1 else {
            throw TelemetryError.invalid("Invalid single-car reference simulation update")
        }
        tick += 1; return output
    }
}

extension ReferenceWorld {
    public func removalStep(_ input: RefRemovalState) throws -> RefRemovalState {
        var output = RefRemovalState()
        guard let handle,ref_world_removal_step(handle,input,&output)==1 else { throw TelemetryError.invalid("Invalid removal oracle input or closed world") }
        return output
    }
}

extension ReferenceWorld {
    public func updateCarStatus(car: Int,flags: UInt32? = nil,fuel: Float? = nil,damage: Int32? = nil,
        pitOccupant: Int32? = nil,maximumDamage: Int32 = 0) throws {
        guard (0..<carCount).contains(car),let handle else { throw TelemetryError.invalid("Invalid lifecycle car") }
        let mask: UInt32 = (flags == nil ? 0:1) | (fuel == nil ? 0:2) | (damage == nil ? 0:4) | (pitOccupant == nil ? 0:8)
        guard ref_world_status(handle,Int32(car),mask,flags ?? 0,fuel ?? 0,damage ?? 0,pitOccupant ?? 0,maximumDamage)==1 else {
            throw TelemetryError.invalid("Invalid lifecycle status")
        }
    }
    public func visual(car: Int = 0) throws -> RefVehicleVisual {
        var output=RefVehicleVisual()
        guard let handle,ref_world_visual(handle,Int32(car),&output)==1 else { throw TelemetryError.invalid("Invalid car or closed reference world") }
        return output
    }
    public func lifecycle(car: Int = 0) throws -> RefLifecycleOutput {
        var output=RefLifecycleOutput()
        guard (0..<carCount).contains(car),let handle,ref_world_read_lifecycle(handle,Int32(car),&output)==1 else {
            throw TelemetryError.invalid("Invalid lifecycle read")
        }
        return output
    }
}

extension ReferenceWorld {
    /// Consumes the original stream without reseeding. Only probe after the
    /// scenario capture is finished; callers compare a copy of native RNG state.
    public func randomTail(count: Int = 32) throws -> [Float] {
        guard let handle,(1...1000).contains(count) else { throw TelemetryError.invalid("Invalid random tail capture") }
        var values=[Float](repeating:0,count:count)
        guard ref_world_random_tail(handle,&values,Int32(count))==1 else { throw TelemetryError.invalid("Random tail capture failed") }
        return values
    }
}

extension ReferenceWorld {
    public func pitSetup(car: Int = 0) throws -> RefPitSetup {
        var output=RefPitSetup()
        guard (0..<carCount).contains(car),let handle,ref_world_pit_setup(handle,Int32(car),&output)==1 else { throw TelemetryError.invalid("Invalid pit setup read") }
        return output
    }
    public func service(car: Int = 0,setup: RefPitSetup,fuel: Float = 0,repair: Int32 = 0,changeAllTires: Bool = false) throws -> RefPitSetup {
        var output=RefPitSetup()
        guard (0..<carCount).contains(car),let handle,ref_world_service(handle,Int32(car),setup,fuel,repair,changeAllTires ? 1:0,&output)==1 else { throw TelemetryError.invalid("Invalid pit service") }
        return output
    }
}

extension ReferenceWorld {
    public func setRuleFactors(damage: Float = 1,tires: Float = 0) throws {
        guard let handle,ref_world_rule_factors(handle,damage,tires)==1 else { throw TelemetryError.invalid("Invalid simulation rule factors") }
    }
    public func servicePublication(car: Int = 0) throws -> [Double] {
        var values=[Double](repeating:0,count:27)
        guard (0..<carCount).contains(car),let handle,ref_world_service_publication(handle,Int32(car),&values,27)==27 else { throw TelemetryError.invalid("Invalid service publication read") }
        return values
    }
}

extension ReferenceWorld {
    public func raceRegistration(car: Int,team: String,length: Float,width: Float,skill: Int) throws {
        guard let handle,ref_world_race_registration(handle,Int32(car),team,length,width,Int32(skill))==1 else { throw TelemetryError.invalid("Invalid race registration") }
    }
    public func initializeRacePits(carsPerPit: Int) throws {
        guard let handle,ref_world_race_pits_init(handle,Int32(carsPerPit))==1 else { throw TelemetryError.invalid("Cannot initialize race pits") }
    }
    public func raceStall(_ index: Int) throws -> RefRacePitStall {
        var out=RefRacePitStall()
        guard let handle,ref_world_race_stall(handle,Int32(index),&out)==1 else { throw TelemetryError.invalid("Invalid race stall") }; return out
    }
    public func racePitCommand(car: Int,command: UInt32,setup: RefPitSetup,fuel: Float,repair: Int32,tires: Bool,stop: Int32,penalty: Float,menu: Bool = false,tireOverride: Int32 = -1) throws {
        guard let handle,ref_world_race_command(handle,Int32(car),command,setup,fuel,repair,tires ? 1:0,stop,penalty,menu ? 1:0,tireOverride)==1 else { throw TelemetryError.invalid("Invalid race pit command") }
    }
    public func manageRacePit(car: Int,position: TrackLocalPosition,flags: UInt32,damage: Int32,speed: SIMD2<Float>,time: Double,maximumDamage: Int32 = 0,session: Int32,rules: RefRacePitRules,usePublished: Bool = false) throws {
        let p=RefTrackPosition(segment:Int32(position.segment),mode:Int32(position.mode.rawValue),toStart:position.toStart,toRight:position.toRight,toMiddle:position.toMiddle,toLeft:position.toLeft)
        guard let handle,ref_world_race_manage(handle,Int32(car),p,flags,damage,speed.x,speed.y,time,maximumDamage,session,rules,usePublished ? 1:0)==1 else { throw TelemetryError.invalid("Invalid race pit management") }
    }
    public func scheduleRacePit(car: Int,time: Double,session: Int32,rules: RefRacePitRules) throws {
        guard let handle,ref_world_race_pit_time(handle,Int32(car),time,session,rules)==1 else { throw TelemetryError.invalid("Invalid race pit timing") }
    }
    public func racePitState(car: Int) throws -> RefRacePitState {
        var out=RefRacePitState()
        guard let handle,ref_world_race_state(handle,Int32(car),&out)==1 else { throw TelemetryError.invalid("Invalid race pit state") }; return out
    }
}

extension ReferenceWorld {
    public func completeRacePitMenu(car: Int) throws {
        guard let handle,ref_world_race_complete_menu(handle,Int32(car))==1 else { throw TelemetryError.invalid("No original pit menu is pending") }
    }
}

extension ReferenceWorld {
    public func initializeLaps(segment: Int,target: Int=5) throws {
        guard let handle,ref_world_laps_init(handle,Int32(segment),Int32(target))==1 else { throw TelemetryError.invalid("Invalid lap initialization") }
    }
    public func initializeProgress(segments: [Int],target: Int) throws {
        guard segments.count==carCount,let handle,ref_world_progress_init(handle,segments.map(Int32.init),Int32(target))==1 else {
            throw TelemetryError.invalid("Invalid field timing initialization")
        }
    }
    public func manageProgress(samples: [RefRaceProgressSample],time: Double,rules: UInt32=3) throws -> (cars:[RefRaceProgressCar],order:[Int],state:Int32) {
        guard samples.count==carCount,let handle else { throw TelemetryError.invalid("Invalid field timing samples") }
        var cars=Array(repeating:RefRaceProgressCar(),count:carCount),order=Array(repeating:Int32(0),count:carCount)
        let state=ref_world_progress_step(handle,samples,time,rules,&cars,&order)
        guard state != 0 else { throw TelemetryError.invalid("Original field timing failed") }
        return (cars,order.map(Int.init),state)
    }
    public func manageLaps(position: TrackLocalPosition,speed: Float,width: Float,flags: UInt32=0,collision: UInt32=0,time: Double,rules: UInt32=3,finishing: Bool=false,usePublished: Bool=false) throws -> RefLapTiming {
        let p=RefTrackPosition(segment:Int32(position.segment),mode:Int32(position.mode.rawValue),toStart:position.toStart,toRight:position.toRight,toMiddle:position.toMiddle,toLeft:position.toLeft)
        var out=RefLapTiming()
        guard let handle,ref_world_laps_manage(handle,p,speed,width,flags,collision,time,rules,finishing ? 1:0,usePublished ? 1:0,&out)==1 else { throw TelemetryError.invalid("Invalid lap management") }
        return out
    }
}

extension ReferenceWorld {
    public func robotObservation() throws -> RefBTObservation {
        var out=RefBTObservation()
        guard let handle,ref_world_bt_observation(handle,&out)==1 else { throw TelemetryError.invalid("No original BT callback observation") }
        return out
    }
}

extension ReferenceWorld {
    public func robotPitDecision() throws -> RefBTPitDecision {
        var out=RefBTPitDecision()
        guard let handle,ref_world_bt_pit_decision(handle,&out)==1 else { throw TelemetryError.invalid("No original BT pit callback") }
        return out
    }
}
