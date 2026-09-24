// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import CryptoKit
import TORCSCore
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation

/// Actual native traffic with an explicit fixed launch order. This is a renderer
/// diagnostic, not an AI driver, race standings implementation or multi-car GUI.
@MainActor enum TrafficVisualSmoke {
    static func run(session:URL,output:URL,measure:Bool=false) throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ACError.invalid("Traffic output directory already exists") }
        let content=try DrivingContent.load(session),road=content.simulation.road,renderer=try SceneRenderer(scenes:content.renderScenes)
        guard let shadowTexture=content.shadow else { throw ACError.invalid("Traffic shadow diagnostic requires a prepared shadow texture") }
        try renderer.setEnvironment(content.graphics,background:content.background)
        try renderer.setCarLightTextures(content.lightTextures)
        try renderer.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow)
        try renderer.setShadowTextures([shadowTexture,shadowTexture,shadowTexture])
        guard renderer.shadowTextureCount==1 else { throw ACError.invalid("Identical car shadows were uploaded more than once") }
        let footprint=try CarShadow(dimensions:content.dimensions),world=try CameraWorld(bounds:road.bounds)
        let mapping:CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        var initial=try MultiVehicleSimulation(definition:content.simulation.vehicle.definition,road:road,carCount:3)
        try initial.settle()
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let width=960,height=640
        func hash(_ data:Data)->String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
        func changes(_ a:Data,_ b:Data)->Int { zip(a,b).reduce(0) { $0+($1.0 == $1.1 ? 0:1) } }
        var images:[String:String]=[:],views:[[String:Any]]=[],switches:[[String:Any]]=[],shadowChanges:[[String:Any]]=[],timings:[[String:Any]]=[]
        var repeats=0,totalChangedChannels=0
        for run in 0..<2 {
            try renderer.resetCarLightRandom()
            var simulation=initial,clock=FixedStepClock(),time:Double=0
            var history=Array(repeating:PresentationCollisionHistory(),count:3)
            var tv=try TVPresentation(carCount:3,settings:.init());try tv.activate(screen:0,car:2)
            func observe() throws {
                for id in 0..<3 {
                    let life=simulation.lifecycle[id]
                    try history[id].observe(tick:simulation.tick,flags:life.flags,accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
                }
            }
            try observe()
            var previousCar=2,switchCount=0
            for frameNumber in 0...900 {
                if frameNumber>0 {
                    var failure:Error?
                    clock.advanceContinuing(elapsed:1/60) { _ in
                        do {
                            try simulation.step(commands:(0..<3).map { DriverCommand(throttle:0.4+Float($0)*0.12,steering:0.04*sin(Float(frameNumber)*0.01),gear:1) })
                            time += FixedStepClock.step;try observe();return true
                        } catch { failure=error;return false }
                    }
                    if let failure { throw failure }
                }
                let frame=(0..<3).map { id in RacePresentationCar(index:id,visual:simulation.visualSnapshot(car:id),trackPosition:simulation.lifecycle[id].trackPosition,remainingLaps:5,pitRequested:false,collisions:history[id]) }
                let selected=try tv.view(screen:0,time:time,frame:frame,road:road,world:world)
                let switched=selected.selection.carIndex != previousCar
                if switched {
                    switchCount += 1;switches.append(["run":run,"frame":frameNumber,"tick":simulation.tick,"from":previousCar,"to":selected.selection.carIndex,"raceTime":time])
                    previousCar=selected.selection.carIndex
                }
                guard [0,30,180,450,900].contains(frameNumber) || switched && switchCount<=4 else { continue }
                guard selected.camera.target==frame[selected.selection.raceSlot].visual.body.position else { throw ACError.invalid("TV target does not match the selected car publication") }
                let poses=try frame.map { try VehiclePresentation($0.visual) }
                var shadows:[SceneShadow]=[],lights:[SceneCarLight]=[]
                func instances(hideDriver:Int?=nil) throws -> [SceneInstance] {
                    var result=[SceneInstance(resource:5,anchor:.land)]
                    for id in 0..<3 {
                        let pose=poses[id],car=frame[id]
                        let reflection=try CarReflection(body:pose.body,yaw:car.visual.body.orientation.z,track:road.geometry,startingAt:car.trackPosition.segment,trackShadow:mapping)
                        result += try pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,drawDriver:id != hideDriver,brakeResources:content.brakeResources,carIndex:id)
                    }
                    return result
                }
                // Initialization order is stable even when TV selects another car.
                for id in 0..<3 {
                    let body=poses[id].body
                    if !content.lightTextures.isEmpty {
                        lights += try CarLightInstance.instances(definitions:content.lights,body:body,brakeCommand:frame[id].visual.brakeCommand,lightCommand:frame[id].visual.lightCommand,display:true).map { SceneCarLight(carIndex:id,light:$0) }
                    }
                    let vertices=try footprint.project(body:body) { try road.geometry.height(at:$0,startingAt:frame[id].trackPosition.segment) }
                    shadows.append(SceneShadow(carIndex:id,resource:id,vertices:vertices,normal:SIMD3(body[2].x,body[2].y,body[2].z)))
                }
                try renderer.setCarLights(lights)
                renderer.lightView=ShadowView(currentCar:selected.selection.carIndex)
                try renderer.setInstances(instances());renderer.camera=selected.camera;renderer.mirror=nil;renderer.shadowView=ShadowView()
                func capture(_ mode:String,expectedDraws:Int) throws {
                    for quality in [false,true] {
                        renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                        var plain:Data?
                        for enabled in [false,true] {
                            try renderer.setShadows(enabled ? shadows:[])
                            let name="traffic-\(mode)-\(frameNumber)-\(quality ? "quality":"classic")-\(enabled ? "shadows":"plain")-run-\(run)"
                            let pixels=try renderer.render(width:width,height:height,captureCommands:true),digest=renderer.lastSubmissionSHA256
                            guard renderer.lastShadowDrawCount==(enabled ? expectedDraws:0) else { throw ACError.invalid("Unexpected per-view shadow draw count") }
                            let random=renderer.lightRandomDraws
                            let repeatPixels=try renderer.render(width:width,height:height,captureCommands:true)
                            try SceneSmoke.verifyRasterRepeat(pixels,repeatPixels)
                            guard digest==renderer.lastSubmissionSHA256,random==renderer.lightRandomDraws else { throw ACError.invalid("Repeated traffic submission changed") }
                            repeats += 1;images[name]=hash(pixels)
                            try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(name+".png"))
                            if run==1 { guard images[name.replacingOccurrences(of:"-run-1",with:"-run-0")]==images[name] else { throw ACError.invalid("Repeated native traffic changed raster") } }
                            if let plain { let changed=changes(plain,pixels);totalChangedChannels += changed;shadowChanges.append(["name":name,"changedChannels":changed]) } else { plain=pixels }
                            views.append(["name":name,"tick":simulation.tick,"raceTime":time,"selectedCar":selected.selection.carIndex,"shadowDraws":renderer.lastShadowDrawCount,"lightDraws":renderer.lastLightDrawCount,"eye":[renderer.camera.eye.x,renderer.camera.eye.y,renderer.camera.eye.z],"target":[renderer.camera.target.x,renderer.camera.target.y,renderer.camera.target.z]])
                        }
                    }
                }
                try capture("tv",expectedDraws:3)
                if frameNumber==0 {
                    let id=selected.selection.carIndex,body=poses[id].body
                    var rig=DrivingCameraRig()
                    renderer.camera=try rig.view(preset:.driver,body:body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,yaw:frame[id].visual.body.orientation.z,trackHeading:0) { _ in 0 }
                    try renderer.setInstances(instances(hideDriver:id))
                    renderer.mirror=RearViewMirror(body:body,bonnetPosition:content.bonnetPosition,hiddenInstances:Set((1+id*17)...(17+id*17)),currentCar:id)
                    try capture("driver-mirror",expectedDraws:5)
                    renderer.mirror=nil
                }
                if measure && run==0 && frameNumber==30 {
                    var gpu=Array(repeating:[Double](),count:4),wall=gpu
                    // Fixed three-car scene, interleaved settings, no physics or
                    // uploads in the measured loop. Validation runs omit this.
                    for sample in 0..<70 { for mode in 0..<4 {
                        let quality=mode>=2,enabled=mode%2==1
                        renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                        try renderer.setShadows(enabled ? shadows:[])
                        let start=ProcessInfo.processInfo.systemUptime
                        _=try renderer.render(width:width,height:height)
                        let elapsed=ProcessInfo.processInfo.systemUptime-start
                        if sample>=10 { gpu[mode].append(renderer.lastGPUTime*1000);wall[mode].append(elapsed*1000) }
                    } }
                    for mode in 0..<4 {
                        let g=gpu[mode].sorted(),w=wall[mode].sorted()
                        timings.append(["mode":mode,"quality":mode>=2,"shadows":mode%2==1,"samples":g.count,"gpuMedianMS":g[30],"gpuP95MS":g[57],"offscreenWallMedianMS":w[30]])
                    }
                }
            }
            guard switchCount>0 else { throw ACError.invalid("Traffic run did not exercise a TV target switch") }
        }
        guard totalChangedChannels>100 else { throw ACError.invalid("Traffic shadows did not affect captured pixels") }
        let report:[String:Any]=["schema":1,"width":width,"height":height,"cars":3,"raceOrder":"fixed launch order; no standings/AI implementation","physicsFramesPerRun":901,"nativeRuns":2,"sharedShadowGPUTextures":renderer.shadowTextureCount,"sceneGPUTextures":renderer.sceneTextureCount,"lightGPUTextures":renderer.lightTextureCount,"imagesRGBA_SHA256":images,"views":views,"switches":switches,"shadowChanges":shadowChanges,"rasterRepeatPairs":repeats,"timings":timings,"timingScope":"Optional 960x640 stationary three-car offscreen GPU commands; 60 interleaved samples after 10 warmups. Not gameplay FPS or whole-race performance.","scope":"Native scripted traffic, original TV kernel, one shadow per car plus two other-car shadows in mirror. No original GL raster parity or multi-car GUI claim."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("TRAFFIC_VISUAL images=\(images.count) repeatPairs=\(repeats) targetSwitches=\(switches.count) sharedShadowTextures=\(renderer.shadowTextureCount) changedShadowChannels=\(totalChangedChannels) exactRepeat=1")
    }
}
