// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import CryptoKit
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation

@MainActor enum BrakeVisualSmoke {
    static func run(session:URL,output:URL,measure:Bool=false) throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ACError.invalid("Brake capture destination exists") }
        let content=try DrivingContent.load(session),renderer=try SceneRenderer(scenes:content.renderScenes)
        try renderer.setEnvironment(content.graphics,background:content.background)
        try renderer.setShadowTexture(content.shadow)
        try renderer.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow)
        let footprint=try CarShadow(dimensions:content.dimensions),road=content.simulation.road.geometry
        let mapping:CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        var simulation=content.simulation
        let initial=simulation.visualSnapshot,initialSegment=simulation.lifecycle.trackPosition.segment
        var hottest=initial,hotSegment=initialSegment,highest:Float=0
        for tick in 0..<4500 {
            try simulation.step(command:DriverCommand(throttle:tick<3000 ? 0.8:0,brake:tick<3000 ? 0:1,gear:1))
            let snapshot=simulation.visualSnapshot,temperature=(0..<4).map { snapshot.wheels[$0].brakeTemperature }.max()!
            if temperature>highest { highest=temperature;hottest=snapshot;hotSegment=simulation.lifecycle.trackPosition.segment }
        }
        guard highest>0 else { throw ACError.invalid("Native braking did not publish any heat") }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let width=960,height=640
        func hash(_ pixels:Data)->String { SHA256.hash(data:pixels).map { String(format:"%02x",$0) }.joined() }
        func changed(_ a:Data,_ b:Data)->Int { zip(a,b).reduce(0) { $0+($1.0 == $1.1 ? 0:1) } }
        var images:[String:String]=[:],records:[[String:Any]]=[],changes:[[String:Any]]=[],timings:[[String:Any]]=[]
        var repeatPairs=0,heatChanged=0,geometryChanged=0
        for (label,snapshot,segment) in [("initial",initial,initialSegment),("native-braking",hottest,hotSegment)] {
            let pose=try VehiclePresentation(snapshot)
            let reflection=try CarReflection(body:pose.body,yaw:snapshot.body.orientation.z,track:road,startingAt:segment,trackShadow:mapping)
            let complete=try pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,brakeResources:content.brakeResources)
            let omitted=try pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection)
            let cold=complete.map { instance in
                SceneInstance(resource:instance.resource,transform:instance.transform,reflection:instance.reflection,hidesDriver:instance.hidesDriver,colorOverride:instance.colorOverride == nil ? nil:SIMD4(0.1,0.1,0.1,1),anchor:instance.anchor,car:instance.car)
            }
            let modes=[omitted,cold,complete],names=["omitted","cold-control","published-heat"]
            let focus=(0..<4).max { snapshot.wheels[$0].brakeTemperature<snapshot.wheels[$1].brakeTemperature }!
            let brake=pose.wheels[focus].brakeTransform,w=snapshot.wheels[focus]
            let offset=Float(focus%2==0 ? 0.2-Double(w.width)/2:Double(w.width)/2-0.2)
            let center=brake*SIMD4(0,offset,0,1),target=SIMD3(center.x,center.y,center.z)
            let outward=normalize(SIMD3(brake[1].x,brake[1].y,brake[1].z))*(focus%2==0 ? Float(-1):1)
            let up=SIMD3(brake[2].x,brake[2].y,brake[2].z)
            var rig=DrivingCameraRig()
            let side=try rig.view(preset:focus%2==0 ? .side1:.side2,body:pose.body,bonnetPosition:content.bonnetPosition,yaw:snapshot.body.orientation.z,trackHeading:0) { try road.height(at:$0,startingAt:segment) }
            let detail=SceneCamera(eye:target+outward*1.2,target:target,fieldOfView:45 * .pi/180,near:0.01,far:100,up:up)
            try renderer.setShadow(footprint.project(body:pose.body) { try road.height(at:$0,startingAt:segment) },normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
            for (cameraName,camera) in [("side",side),("wheel-detail",detail)] {
                renderer.camera=camera
                for quality in [false,true] {
                    renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                    var captured:[Data]=[]
                    for mode in 0..<3 {
                        try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+modes[mode])
                        let name="brakes-\(label)-\(cameraName)-\(quality ? "quality":"classic")-\(names[mode])"
                        let pixels=try renderer.render(width:width,height:height,captureCommands:true),digest=renderer.lastSubmissionSHA256
                        let repeated=try renderer.render(width:width,height:height,captureCommands:true)
                        try SceneSmoke.verifyRasterRepeat(pixels,repeated)
                        guard renderer.lastSubmissionSHA256==digest else { throw ACError.invalid("Repeated brake submission changed") }
                        repeatPairs += 1;captured.append(pixels);images[name]=hash(pixels)
                        try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(name+".png"))
                        records.append(["name":name,"tick":snapshot.tick,"focusWheel":focus,"temperatures":(0..<4).map { snapshot.wheels[$0].brakeTemperature },"instances":renderer.instances.count,"triangles":renderer.triangleCount])
                    }
                    let geometryDelta=changed(captured[0],captured[1]),heatDelta=changed(captured[1],captured[2])
                    geometryChanged += geometryDelta;heatChanged += heatDelta
                    changes.append(["snapshot":label,"camera":cameraName,"quality":quality,"geometryChangedChannels":geometryDelta,"publishedHeatChangedChannels":heatDelta])
                }
            }
            if measure && label=="native-braking" {
                renderer.camera=side
                var gpu=Array(repeating:[Double](),count:4),wall=gpu
                for sample in 0..<70 { for mode in 0..<4 {
                    renderer.smoothEdges=mode>=2;renderer.enhancedFiltering=mode>=2
                    try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+(mode%2==0 ? omitted:complete))
                    let start=ProcessInfo.processInfo.systemUptime
                    _=try renderer.render(width:width,height:height)
                    if sample>=10 { gpu[mode].append(renderer.lastGPUTime*1000);wall[mode].append((ProcessInfo.processInfo.systemUptime-start)*1000) }
                } }
                for mode in 0..<4 { let g=gpu[mode].sorted(),w=wall[mode].sorted();timings.append(["quality":mode>=2,"brakes":mode%2==1,"samples":g.count,"gpuMedianMS":g[30],"gpuP95MS":g[57],"offscreenWallMedianMS":w[30]]) }
            }
        }
        guard geometryChanged>0,heatChanged>0 else { throw ACError.invalid("Brake geometry or native heat was not visible in captures") }
        let report:[String:Any]=["schema":1,"imagesRGBA_SHA256":images,"records":records,"changes":changes,"rasterRepeatPairs":repeatPairs,"nativePhysicsTicks":4500,"highestPublishedTemperature":highest,"hottestTick":hottest.tick,"generatedParts":12,"generatedTriangles":172,"timings":timings,"scope":"Actual native accelerate/brake snapshots. Omitted geometry and fixed cold color are presentation controls; no physics state is changed. Wheel-detail view is an inspection camera. No GL pixel parity or race FPS claim.","timingScope":"960x640 stationary side view, original artwork plus optional generated brakes; 60 interleaved samples per classic/quality and brake-off/on mode after 10 warmups. Excludes physics, resource loading and file IO."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("BRAKE_VISUAL images=\(images.count) repeatPairs=\(repeatPairs) nativeTicks=4500 maximumHeat=\(highest) geometryChanged=\(geometryChanged) heatChanged=\(heatChanged)")
    }
}
