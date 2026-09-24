// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import CryptoKit
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation

/// Same one-car presentation path as the driving view. Multi-car selection is
/// covered separately against original code; no racing AI is implied here.
@MainActor enum TVVisualSmoke {
    static func run(session: URL,output: URL) throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ACError.invalid("TV output directory already exists") }
        let content=try DrivingContent.load(session),renderer=try SceneRenderer(scenes:content.renderScenes)
        try renderer.setEnvironment(content.graphics,background:content.background)
        try renderer.setShadowTexture(content.shadow)
        try renderer.setCarLightTextures(content.lightTextures)
        try renderer.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow)
        let footprint=try CarShadow(dimensions:content.dimensions),world=try CameraWorld(bounds:content.simulation.road.bounds)
        let mapping: CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        let road=content.simulation.road
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let width=960,height=640
        func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
        var images:[String:String]=[:],views:[[String:Any]]=[],repeatPairs=0
        for run in 0..<2 {
            try renderer.resetCarLightRandom()
            var runtime=try DrivingRuntime(simulation:content.simulation),television=try TVPresentation(carCount:1,settings:.init())
            try television.activate(screen:0,car:0)
            for frameNumber in 0...900 {
                if frameNumber>0 { try runtime.advance(elapsed:1/60,command:DriverCommand(throttle:0.6,steering:0.04*sin(Float(frameNumber)*0.01),gear:1)) }
                let frame=runtime.frame
                // Switching away does not reset or advance the TV director.
                guard frameNumber<301 || frameNumber>360 else { continue }
                let result=try television.view(screen:0,time:frame.raceTime,frame:[frame.presentationCar],road:road,world:world)
                guard [30,180,450,900].contains(frameNumber) else { continue }
                let previous=try VehiclePresentation(frame.previous),current=try VehiclePresentation(frame.current)
                let pose=try VehiclePresentation.interpolate(previous:previous,current:current,alpha:frame.interpolation)
                func ground(_ point:SIMD2<Float>) throws -> Float { try road.geometry.height(at:point,startingAt:frame.trackSegment) }
                let yaw=frame.previous.body.orientation.z,delta=frame.current.body.orientation.z-yaw
                let reflection=try CarReflection(body:pose.body,yaw:yaw+atan2(sin(delta),cos(delta))*frame.interpolation,track:road.geometry,startingAt:frame.trackSegment,trackShadow:mapping)
                try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,brakeResources:content.brakeResources))
                let lights=content.lightTextures.isEmpty ? []:try CarLightInstance.instances(definitions:content.lights,body:pose.body,brakeCommand:frame.current.brakeCommand,lightCommand:frame.current.lightCommand,display:true)
                try renderer.setCarLights(lights.map { SceneCarLight(carIndex:0,light:$0) })
                try renderer.setShadow(footprint.project(body:pose.body,groundHeight:ground),normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
                for zoom:Float in frameNumber==900 ? [9,1,90]:[9] {
                    let view=try television.view(screen:0,time:frame.raceTime,frame:[frame.presentationCar],road:road,world:world,zoom:zoom)
                    guard view.selection.carIndex==result.selection.carIndex,view.camera.eye==result.camera.eye else { throw ACError.invalid("Paused TV zoom changed target or placement") }
                    renderer.camera=view.camera
                    for quality in [false,true] {
                        renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                        let name="tv-\(frameNumber)-zoom-\(Int(zoom))-\(quality ? "quality":"classic")-run-\(run)"
                        let pixels=try renderer.render(width:width,height:height,captureCommands:true),submission=renderer.lastSubmissionSHA256
                        let repeated=try renderer.render(width:width,height:height,captureCommands:true)
                        try SceneSmoke.verifyRasterRepeat(pixels,repeated)
                        guard submission==renderer.lastSubmissionSHA256 else { throw ACError.invalid("Repeated TV submission changed") }
                        repeatPairs += 1
                        try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(name+".png"));images[name]=hash(pixels)
                        if run==1 { guard images[name.replacingOccurrences(of:"-run-1",with:"-run-0")]==images[name] else { throw ACError.invalid("Repeated native simulation changed TV raster") } }
                        views.append(["name":name,"raceTime":frame.raceTime,"tick":frame.current.tick,"carIndex":view.selection.carIndex,"eye":[view.camera.eye.x,view.camera.eye.y,view.camera.eye.z],"target":[view.camera.target.x,view.camera.target.y,view.camera.target.z],"zoom":zoom])
                    }
                }
            }
        }
        let report:[String:Any]=["schema":1,"width":width,"height":height,"imagesRGBA_SHA256":images,"views":views,"rasterRepeatPairs":repeatPairs,"repeatedNativeRuns":2,"framesPerRun":901,"cameraDeselectedFrames":[301,360],"pausedZooms":[9,1,90],"scope":"Actual single-car native physics and Metal. Multi-car TV selection tested separately. No original GL pixel parity, GUI acceptance or performance claim."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("TV_VISUAL images=\(images.count) rasterRepeatPairs=\(repeatPairs) nativeRuns=2 exactRepeat=1")
    }
}
