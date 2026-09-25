// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import CryptoKit
import TORCSAssets
import TORCSPresentation
import TORCSRaceEngine
import TORCSRender
import TORCSSimulation
import TORCSTrack
import TORCSTrackMesh

/// Renders a whole field offscreen: the same view with one car and with the
/// field, so the other cars are shown to actually reach the image, plus the
/// rear-view mirror that has to contain them. A renderer diagnostic, not a race.
@MainActor enum ModernTrafficSmoke {
    static func run(session: URL, output: URL, cars: Int = 3, width: Int = 1280, height: Int = 832) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ACError.invalid("Traffic output directory already exists")
        }
        guard (2 ... 16).contains(cars) else { throw ACError.invalid("A traffic capture needs 2…16 cars") }
        let content = try DrivingContent.load(session)
        guard content.gridSlots.count >= cars else { throw ACError.invalid("The session paints fewer grid slots than cars") }
        let renderer = try ForwardRenderer()
        let resources = try SessionRenderResources(
            device: renderer.device, scenes: content.renderScenes,
            road: content.simulation.road.geometry, pits: content.simulation.road.pits, terrain: TerrainParameters(),
            materials: ModernDrivingRenderer.materialsDirectory(beside: session))
        let lighting = ModernDrivingRenderer.lighting(from: content.graphics)
        renderer.roadPaint.set(content.gridSlots.map { RoadPaint.Box(centre: $0.world, yaw: $0.yaw) })
        let geometry = content.simulation.road.geometry
        // The field stands on the original grid slots the session already paints.
        let definition = content.simulation.vehicle.definition
        let slots = Array(content.gridSlots.prefix(cars))
        var simulation = try MultiVehicleSimulation(definitions: Array(repeating: definition, count: cars),
                                                   road: content.simulation.road, grid: slots)
        try simulation.settle()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let poses = try (0 ..< cars).map { try VehiclePresentation(simulation.visualSnapshot(car: $0)) }
        let field = poses.map { ModernDrivingRenderer.FieldCar(pose: $0) }
        // Grid slots run back from the line, so the car on the last slot has the
        // whole field ahead of it: the view where opponents must be visible.
        let viewer = cars - 1
        let body = poses[viewer].body
        let world = try CameraWorld(bounds: content.simulation.road.bounds)
        let heading = geometry.tangent(try geometry.globalToLocal(SIMD2(body[3].x, body[3].y), startingAt: 0))
        // Chase relaxation steps a fixed fraction per call, so spin it to steady
        // state before capture, as the single-car diagnostic does.
        var rig = DrivingCameraRig()
        var chase: SceneCamera?
        for _ in 0 ..< 200 {
            chase = try rig.view(preset: .chase, body: body, bonnetPosition: content.bonnetPosition,
                                 driverPosition: content.driverPosition, world: world, roadCameraPosition: nil,
                                 yaw: simulation.visualSnapshot(car: viewer).body.orientation.z,
                                 trackHeading: heading) { try geometry.height(at: $0, startingAt: 0) }
        }
        guard let chase else { throw ACError.invalid("Chase camera unavailable") }
        let camera = ModernDrivingRenderer.camera(from: chase)
        func capture(_ drawn: [ModernDrivingRenderer.FieldCar], name: String) throws -> (Data, Int, Int) {
            renderer.resetHistory()
            let instances = resources.staticInstances() + ModernDrivingRenderer.vehicleInstances(field: drawn)
            let pixels = try renderer.render(resources: resources.resources, instances: instances,
                                             camera: camera, lighting: lighting, width: width, height: height)
            let data = Data(pixels)
            try writePNG(data, width: width, height: height, output: output.appendingPathComponent("\(name).png"))
            return (data, renderer.lastDrawCount, renderer.lastTriangleCount)
        }
        let (single, singleDraws, singleTriangles) = try capture([field[viewer]], name: "one-car")
        let (whole, wholeDraws, wholeTriangles) = try capture(field, name: "field")
        let (repeated, _, _) = try capture(field, name: "field-repeat")
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let changed = zip(single, whole).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        // Cars behind the camera still cast into the shadow cascades, so a small
        // difference proves nothing: chasing the pole car that way measured 0.77%
        // of the image with no opponent visible. One per cent separates opponents
        // in view from opponents only shadowing the road.
        let visibleFraction = Double(changed) / Double(width * height * 4)
        guard visibleFraction >= 0.01 else {
            throw ACError.invalid("Only \(changed) channels changed: the field is not in view")
        }
        guard hash(whole) == hash(repeated) else { throw ACError.invalid("The field render did not repeat") }
        guard wholeDraws > singleDraws, wholeTriangles > singleTriangles else {
            throw ACError.invalid("The field submitted no additional geometry")
        }
        // Instance accounting is exact: every car contributes the same parts.
        let expected = cars * ModernDrivingRenderer.instancesPerCar
        let produced = ModernDrivingRenderer.vehicleInstances(field: field).count
        guard produced == expected else {
            throw ACError.invalid("Field produced \(produced) instances, expected \(expected)")
        }
        // The mirror must contain the other cars even when the viewer's own car
        // is drawn in the main view.
        let mirrorCars = ModernDrivingRenderer.mirrorCarInstances(
            field: field, viewer: viewer, viewerDrawsCar: true).count
        guard mirrorCars == (cars - 1) * ModernDrivingRenderer.instancesPerCar else {
            throw ACError.invalid("Mirror carried \(mirrorCars) opponent instances")
        }
        let report: [String: Any] = [
            "schema": 1, "cars": cars, "width": width, "height": height,
            "oneCarDraws": singleDraws, "fieldDraws": wholeDraws,
            "oneCarTriangles": singleTriangles, "fieldTriangles": wholeTriangles,
            "viewerCar": viewer, "changedChannels": changed, "fieldSHA256": hash(whole),
            "repeatIdentical": true, "changedFraction": visibleFraction, "instancesPerCar": ModernDrivingRenderer.instancesPerCar,
            "fieldInstances": produced, "mirrorOpponentInstances": mirrorCars,
            "scope": "Renderer field submission and mirror contents; no race engine or AI"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("traffic.json"), options: .atomic)
        print("Modern traffic: \(cars) cars, draws \(singleDraws)→\(wholeDraws), "
            + "triangles \(singleTriangles)→\(wholeTriangles), changed channels \(changed), repeat identical")
    }
}
