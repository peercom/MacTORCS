// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSMetal
import TORCSRaceEngine
import TORCSAssets
import simd
import CryptoKit

@MainActor enum CameraZoomSmoke {
    static func run(content:DrivingContent,renderer:SceneRenderer,mapping:CarTrackShadowMapping?,output:URL) throws -> [String:Any] {
        let simulation=content.simulation,road=simulation.road,pose=try VehiclePresentation(simulation.visualSnapshot)
        let segment=simulation.vehicle.chassis.trackPosition.segment,world=try CameraWorld(bounds:road.bounds)
        let reflection=try CarReflection(body:pose.body,yaw:simulation.visualSnapshot.body.orientation.z,track:road.geometry,startingAt:segment,trackShadow:mapping)
        try renderer.setShadow(CarShadow(dimensions:content.dimensions).project(body:pose.body){try road.geometry.height(at:$0,startingAt:segment)},normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
        renderer.smoothEdges=true;renderer.enhancedFiltering=false;renderer.carReflectionsEnabled=true;renderer.carTrackShadowsEnabled=true
        defer {renderer.mirror=nil;renderer.smoothEdges=false}
        var cases:[[String:Any]]=[]
        for preset:DrivingCameraPreset in [.chase,.driver,.side3,.circuit,.tracksideZoom] {
            try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,drawDriver:preset.drawsDriver))
            renderer.mirror=preset.allowsMirror ? RearViewMirror(body:pose.body,bonnetPosition:content.bonnetPosition,hiddenInstances:Set(1...5)):nil
            var zoom=preset.zoomLimits.standard,baseline:Data?,rig=DrivingCameraRig()
            // Settle the original per-update chase relaxation before comparing zoom.
            for _ in 0..<200 { _=try rig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,world:world,roadCameraPosition:road.camera(at:segment)?.position,yaw:simulation.visualSnapshot.body.orientation.z,trackHeading:0){try road.geometry.height(at:$0,startingAt:segment)} }
            for mode in ["default","in","wide","reset"] {
                if mode=="in" {for _ in 0..<10 {zoom=try preset.adjustedZoom(zoom,command:.zoomIn)}}
                if mode=="wide" {zoom=try preset.adjustedZoom(zoom,command:.maximum)}
                if mode=="reset" {zoom=try preset.adjustedZoom(zoom,command:.reset)}
                renderer.camera=try rig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,world:world,roadCameraPosition:road.camera(at:segment)?.position,zoomValue:zoom,yaw:simulation.visualSnapshot.body.orientation.z,trackHeading:0){try road.geometry.height(at:$0,startingAt:segment)}
                let name="zoom-"+preset.rawValue.lowercased().replacingOccurrences(of:" ",with:"-")+"-"+mode
                let pixels=try renderer.render(width:960,height:640,captureCommands:true),submission=renderer.lastSubmissionSHA256
                let repeated=try renderer.render(width:960,height:640,captureCommands:true)
                try SceneSmoke.verifyRasterRepeat(pixels,repeated)
                guard submission==renderer.lastSubmissionSHA256 else {throw RendererError.unavailable("Zoom repeat changed commands")}
                if mode=="default" {baseline=pixels}
                let changed=zip(pixels,baseline!).filter{$0 != $1}.count
                if mode=="reset" {try SceneSmoke.verifyRasterRepeat(baseline!,pixels)}
                if mode=="in" || mode=="wide" {guard changed>0 else {throw RendererError.unavailable("Zoom did not change \(preset.rawValue) pixels")}}
                try SceneSmoke.writePNG(pixels,width:960,height:640,output:output.appendingPathComponent(name+".png"))
                cases.append(["image":name,"preset":preset.rawValue,"mode":mode,"zoomValue":zoom,"fieldOfViewRadians":renderer.camera.fieldOfView,"changedFromDefaultChannels":changed,"sameSubmittedCommands":true,"changedRepeatChannels":0,"sampleCount":renderer.rasterSampleCount,"mirror":preset.allowsMirror,"RGBA_SHA256":SHA256.hash(data:pixels).map{String(format:"%02x",$0)}.joined()])
            }
        }
        return ["cases":cases,"note":"Five selected views at four zoom states, optional MSAA enabled, driver mirror included. Reset must restore exact default pixels. Not original GL pixels or a gameplay performance benchmark."]
    }
}
