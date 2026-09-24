// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import CryptoKit
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation

@MainActor enum CarLightVisualSmoke {
    static func run(session:URL,output:URL,measure:Bool=false) throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ACError.invalid("Light capture destination exists") }
        let content=try DrivingContent.load(session)
        guard !content.lightTextures.isEmpty else { throw ACError.invalid("Prepared session has no car-light textures") }
        let renderer=try SceneRenderer(scenes:content.renderScenes)
        try renderer.setCarLightTextures(content.lightTextures)
        try renderer.setEnvironment(content.graphics,background:content.background);try renderer.setShadowTexture(content.shadow)
        try renderer.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow)
        let footprint=try CarShadow(dimensions:content.dimensions),road=content.simulation.road.geometry
        let mapping:CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        var simulation=content.simulation
        for _ in 0..<1800 { try simulation.step(command:DriverCommand(throttle:0.4,gear:1)) }
        let released=simulation.visualSnapshot,releasedSegment=simulation.lifecycle.trackPosition.segment
        for _ in 0..<100 { try simulation.step(command:DriverCommand(brake:0.8,gear:1)) }
        let braking=simulation.visualSnapshot,brakingSegment=simulation.lifecycle.trackPosition.segment
        guard released.brakeCommand==0,braking.brakeCommand>0 else { throw ACError.invalid("Native light capture command states missing") }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let width=960,height=640
        var images:[String:String]=[:],records:[[String:Any]]=[],changes:[[String:Any]]=[],timings:[[String:Any]]=[]
        var repeats=0,brakingChange=0,releasedChange=0
        for (label,snapshot,segment) in [("released",released,releasedSegment),("braking",braking,brakingSegment)] {
            let pose=try VehiclePresentation(snapshot)
            let reflection=try CarReflection(body:pose.body,yaw:snapshot.body.orientation.z,track:road,startingAt:segment,trackShadow:mapping)
            let instances=try pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,brakeResources:content.brakeResources)
            let lights=try CarLightInstance.instances(definitions:content.lights,body:pose.body,brakeCommand:snapshot.brakeCommand,lightCommand:snapshot.lightCommand,display:true).map { SceneCarLight(carIndex:0,light:$0) }
            var rig=DrivingCameraRig()
            func camera(_ preset:DrivingCameraPreset) throws -> SceneCamera {
                try rig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,yaw:snapshot.body.orientation.z,trackHeading:0) { try road.height(at:$0,startingAt:segment) }
            }
            let target4=pose.body*SIMD4<Float>(-2.18,0,0.68,1),eye4=pose.body*SIMD4<Float>(-5,0,1.2,1)
            let detail=SceneCamera(eye:SIMD3(eye4.x,eye4.y,eye4.z),target:SIMD3(target4.x,target4.y,target4.z),fieldOfView:.pi/3,near:0.1,far:600)
            let chase=try camera(.chase),driver=try camera(.driver)
            try renderer.setShadow(footprint.project(body:pose.body) { try road.height(at:$0,startingAt:segment) },normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
            renderer.shadowView=ShadowView(currentCar:0);renderer.lightView=ShadowView(currentCar:0)
            for (name,view) in [("chase",chase),("rear-inspection",detail),("driver-mirror",driver)] {
                renderer.camera=view
                renderer.mirror=name=="driver-mirror" ? RearViewMirror(body:pose.body,bonnetPosition:content.bonnetPosition,hiddenInstances:Set(1...17)):nil
                try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+(name=="driver-mirror" ? pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,drawDriver:false,brakeResources:content.brakeResources):instances))
                for quality in [false,true] {
                    renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                    var captures:[Data]=[]
                    for enabled in [false,true] {
                        try renderer.setCarLights(enabled ? lights:[])
                        let title="lights-\(label)-\(name)-\(quality ? "quality":"classic")-\(enabled ? "enabled":"omitted")"
                        let pixels=try renderer.render(width:width,height:height,captureCommands:true),digest=renderer.lastSubmissionSHA256,random=renderer.lightRandomDraws
                        try SceneSmoke.verifyRasterRepeat(pixels,renderer.render(width:width,height:height,captureCommands:true))
                        guard renderer.lastSubmissionSHA256==digest,renderer.lightRandomDraws==random else { throw ACError.invalid("Repeated light frame changed") }
                        repeats += 1;captures.append(pixels)
                        images[title]=SHA256.hash(data:pixels).map { String(format:"%02x",$0) }.joined()
                        records.append(["name":title,"tick":snapshot.tick,"brakeCommand":snapshot.brakeCommand,"lightDraws":renderer.lastLightDrawCount,"randomDraws":random])
                        try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(title+".png"))
                    }
                    let delta=zip(captures[0],captures[1]).reduce(0) { $0+($1.0 == $1.1 ? 0:1) }
                    if label=="braking" { brakingChange += delta } else { releasedChange += delta }
                    changes.append(["snapshot":label,"camera":name,"quality":quality,"changedChannels":delta])
                }
            }
            if measure && label=="braking" {
                renderer.camera=chase;renderer.mirror=nil;try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+instances)
                var gpu=Array(repeating:[Double](),count:4),wall=gpu
                for sample in 0..<70 { for mode in 0..<4 {
                    renderer.smoothEdges=mode>=2;renderer.enhancedFiltering=mode>=2
                    try renderer.setCarLights(mode%2==0 ? []:lights)
                    let start=ProcessInfo.processInfo.systemUptime
                    _=try renderer.render(width:width,height:height)
                    if sample>=10 { gpu[mode].append(renderer.lastGPUTime*1000);wall[mode].append((ProcessInfo.processInfo.systemUptime-start)*1000) }
                } }
                for mode in 0..<4 { let g=gpu[mode].sorted(),w=wall[mode].sorted();timings.append(["quality":mode>=2,"lights":mode%2==1,"samples":g.count,"gpuMedianMS":g[30],"gpuP95MS":g[57],"offscreenWallMedianMS":w[30]]) }
            }
        }
        guard brakingChange>0,releasedChange==0 else { throw ACError.invalid("Brake-light switching was not visible or released lamps changed pixels") }
        let report:[String:Any]=["schema":1,"imagesRGBA_SHA256":images,"records":records,"changes":changes,"rasterRepeatPairs":repeats,"nativePhysicsTicks":1900,"lightGPUTextures":renderer.lightTextureCount,"timings":timings,"scope":"Actual native released/braking commands; omitted lights are a presentation control. Rear-inspection is a diagnostic view. Same publication retains random choices; each new publication samples the original draw stream. No original GL pixel parity claim.","timingScope":"Stationary 960x640 chase view. 60 interleaved samples per classic/quality and light-off/on mode after 10 warmups; resources and world light positions prepared beforehand. Includes per-view light culling/random/quad preparation in render wall time, excludes physics and file IO." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("CAR_LIGHT_VISUAL images=\(images.count) repeatPairs=\(repeats) nativeTicks=1900 brakingChanged=\(brakingChange) releasedChanged=\(releasedChange)")
    }
}
