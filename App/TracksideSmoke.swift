// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation
import simd
import CryptoKit

@MainActor enum TracksideSmoke {
    /// Exercise each assigned camera with a native vehicle settled in its range.
    /// These independent placements are coverage fixtures, not a completed lap.
    static func run(content:DrivingContent,renderer:SceneRenderer,mapping:CarTrackShadowMapping?,output:URL) throws -> [String:Any] {
        let road=content.simulation.road,geometry=road.geometry,world=try CameraWorld(bounds:road.bounds)
        renderer.mirror=nil;renderer.smoothEdges=true;renderer.enhancedFiltering=false
        renderer.carReflectionsEnabled=true;renderer.carTrackShadowsEnabled=true
        defer {renderer.smoothEdges=false}
        var cases:[[String:Any]]=[]
        for id in road.cameras.indices {
            let assigned=geometry.mainSegments.filter{road.cameraIndices[$0]==id}
            guard !assigned.isEmpty else {continue}
            let index=assigned[assigned.count/2],segment=geometry.segments[index]
            let distance=segment.distanceFromStart+segment.length*0.5
            var simulation=try SingleVehicleSimulation(definition:content.simulation.vehicle.definition,road:road,startDistance:distance)
            try simulation.settle()
            let current=simulation.vehicle.chassis.trackPosition.segment
            guard road.cameraIndices[current]==id else {throw RendererError.unavailable("Trackside coverage vehicle settled outside expected camera range")}
            let pose=try VehiclePresentation(simulation.visualSnapshot),body=pose.body
            let reflection=try CarReflection(body:body,yaw:simulation.visualSnapshot.body.orientation.z,track:geometry,startingAt:current,trackShadow:mapping)
            try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection))
            try renderer.setShadow(CarShadow(dimensions:content.dimensions).project(body:body){try geometry.height(at:$0,startingAt:current)},normal:SIMD3(body[2].x,body[2].y,body[2].z))
            for preset:DrivingCameraPreset in [.trackside,.tracksideZoom] {
                var rig=DrivingCameraRig()
                renderer.camera=try rig.view(preset:preset,body:body,bonnetPosition:content.bonnetPosition,world:world,roadCameraPosition:road.camera(at:current)?.position,yaw:0,trackHeading:0){_ in 0}
                let name="road-camera-\(id)-"+(preset == .trackside ? "fixed":"zoom")
                let pixels=try renderer.render(width:960,height:640,captureCommands:true),submission=renderer.lastSubmissionSHA256
                let repeated=try renderer.render(width:960,height:640,captureCommands:true)
                try SceneSmoke.verifyRasterRepeat(pixels,repeated)
                guard submission==renderer.lastSubmissionSHA256 else {throw RendererError.unavailable("Trackside repeat changed commands")}
                try SceneSmoke.writePNG(pixels,width:960,height:640,output:output.appendingPathComponent(name+".png"))
                cases.append(["image":name,"camera":road.cameras[id].name,"segment":current,"startDistance":distance,"settlingTicks":simulation.settlingTicks,"sampleCount":renderer.rasterSampleCount,"RGBA_SHA256":SHA256.hash(data:pixels).map{String(format:"%02x",$0)}.joined(),"changedRepeatChannels":0,"sameSubmittedCommands":true])
            }
        }
        return ["cameras":road.cameras.count,"cases":cases,"note":"Independent native settled placements cover camera ranges; not a driving lap or original GL pixel comparison."]
    }
}
