// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSAssets
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation
import TORCSMetal
import simd

/// Real native physics plus compiled track/body/wheels. This diagnostic does not
/// substitute a scripted transform for vehicle dynamics or claim a playable race.
@MainActor enum VehicleSceneSmoke {
    static func run(scenes: URL,fixtures: URL,output: URL) throws {
        func data(_ name: String) throws -> Data { try ContentSearchPath.readBounded(fixtures.appendingPathComponent(name)) }
        let parameters=try ParameterDocument.parse(data("Track-4WD-GrB.xml")).merging(ParameterDocument.parse(data("155-DTM.xml")))
        let road=try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data("aalborg.xml"),entities:["default-surfaces":data("surfaces.xml"),"default-objects":data("objects.xml")],allowLegacyLatin1:true))
        var simulation=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:parameters),road:road)
        try simulation.settle()
        let names=["155-DTM","wheel0","wheel1","wheel2","wheel3","aalborg"]
        let models=try names.map { try CompiledScene.load(scenes.appendingPathComponent($0)) }
        let renderer=try SceneRenderer(scenes:models)
        let start=simulation.visualSnapshot
        var previous=try VehiclePresentation(start)
        for _ in 0..<1000 {
            previous=try VehiclePresentation(simulation.visualSnapshot)
            try simulation.step(command:.init(throttle:0.65,gear:1))
        }
        let end=simulation.visualSnapshot,current=try VehiclePresentation(end)
        let interpolated=try VehiclePresentation.interpolate(previous:previous,current:current,alpha:0.5)
        let instances=try interpolated.instances(bodyResource:0,wheelResources:[1,2,3,4])
        try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+instances)
        renderer.camera.target=end.body.position+SIMD3(0,0,0.8);renderer.camera.distance=9;renderer.camera.pitch=0.35;renderer.camera.yaw=end.body.orientation.z-0.9
        let pixels=try renderer.render(width:960,height:640)
        let repeated=try renderer.render(width:960,height:640)
        try SceneSmoke.verifyRasterRepeat(pixels,repeated)
        let moved=simd_length(end.body.position-start.body.position)
        guard moved>1,renderer.instances.count==6 else { throw RendererError.unavailable("Vehicle diagnostic did not move or attach all instances") }
        try SceneSmoke.writePNG(pixels,width:960,height:640,output:output)
        try pixels.write(to:output.deletingPathExtension().appendingPathExtension("rgba"),options:.atomic)
        let sum=pixels.reduce(UInt64(0)) { $0+UInt64($1) }
        print("VEHICLE_SCENE ticks=\(simulation.tick) instances=\(renderer.instances.count) triangles=\(renderer.triangleCount) distance=\(moved) rgbaChecksum=\(sum) repeat=1")
        print("Wheel levels: \((0..<4).map { current.wheels[$0].level })")
    }
}
