// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import CryptoKit
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation

/// Actual native simulation and Metal readbacks; no GPU/gameplay timing claims.
@MainActor enum FlyVisualSmoke {
    static func run(session: URL,output: URL) throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ACError.invalid("Fly output directory already exists") }
        let content=try DrivingContent.load(session),renderer=try SceneRenderer(scenes:content.renderScenes)
        try renderer.setEnvironment(content.graphics,background:content.background)
        try renderer.setShadowTexture(content.shadow)
        try renderer.setCarLightTextures(content.lightTextures)
        try renderer.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow)
        let footprint=try CarShadow(dimensions:content.dimensions)
        let mapping: CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        let road=content.simulation.road.geometry
        let initial=content.simulation.visualSnapshot
        let initialShadow=try footprint.project(body:VehiclePresentation.matrix(initial.body)) { try road.height(at:$0,startingAt:0) }
        let initialHeight=try DrivingSceneHeight(scenes:content.scenes.map { $0.asset.scene },snapshot:initial,shadowVertices:initialShadow,brakeScenes:content.brakeScenes.map { $0.asset.scene },lights:content.lights)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let width=960,height=640
        func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
        var images: [String:String]=[:],views: [[String:Any]]=[],repeatPairs=0
        for run in 0..<2 {
            try renderer.resetCarLightRandom()
            var runtime=try DrivingRuntime(simulation:content.simulation),fly=try DrivingFlyCamera(height:initialHeight)
            for frameNumber in 0...900 {
                if frameNumber>0 { try runtime.advance(elapsed:1/60,command:DriverCommand(throttle:0.6,steering:0.04*sin(Float(frameNumber)*0.01),gear:1)) }
                let frame=runtime.frame
                let current=try VehiclePresentation(frame.current),previous=try VehiclePresentation(frame.previous)
                let pose=try VehiclePresentation.interpolate(previous:previous,current:current,alpha:frame.interpolation)
                func ground(_ point: SIMD2<Float>) throws -> Float { try road.height(at:point,startingAt:frame.trackSegment) }
                let selected=frameNumber<301 || frameNumber>360
                let publishedShadow=try footprint.project(body:current.body,groundHeight:ground)
                let camera=try fly.draw(time:frame.raceTime,selected:selected,snapshot:frame.current,drawsCar:true,drawsDriver:true,shadowVertices:publishedShadow)
                guard [30,180,450,900].contains(frameNumber),let camera else { continue }
                let yaw=frame.previous.body.orientation.z,delta=frame.current.body.orientation.z-yaw
                let cameraYaw=yaw+atan2(sin(delta),cos(delta))*frame.interpolation
                let reflection=try CarReflection(body:pose.body,yaw:cameraYaw,track:road,startingAt:frame.trackSegment,trackShadow:mapping)
                try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,brakeResources:content.brakeResources))
                let lights=content.lightTextures.isEmpty ? []:try CarLightInstance.instances(definitions:content.lights,body:pose.body,brakeCommand:frame.current.brakeCommand,lightCommand:frame.current.lightCommand,display:true)
                try renderer.setCarLights(lights.map { SceneCarLight(carIndex:0,light:$0) })
                try renderer.setShadow(footprint.project(body:pose.body,groundHeight:ground),normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
                let zooms: [Float]=frameNumber==900 ? [67.5,30,90]:[67.5]
                for zoom in zooms {
                    let view=try fly.draw(time:frame.raceTime,selected:true,snapshot:frame.current,drawsCar:true,drawsDriver:true,shadowVertices:publishedShadow,zoom:zoom) ?? camera
                    guard view.eye==camera.eye else { throw ACError.invalid("Paused fly zoom changed motion") }
                    renderer.camera=view
                    for quality in [false,true] {
                        renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                        let name="fly-\(frameNumber)-zoom-\(Int(zoom*10))-\(quality ? "quality":"classic")-run-\(run)"
                        let pixels=try renderer.render(width:width,height:height,captureCommands:true)
                        let submission=renderer.lastSubmissionSHA256
                        let repeated=try renderer.render(width:width,height:height,captureCommands:true)
                        try SceneSmoke.verifyRasterRepeat(pixels,repeated)
                        guard submission==renderer.lastSubmissionSHA256 else { throw ACError.invalid("Repeated fly submission changed") }
                        repeatPairs += 1
                        try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(name+".png"));images[name]=hash(pixels)
                        if run==1 {
                            guard images[name.replacingOccurrences(of:"-run-1",with:"-run-0")]==images[name] else { throw ACError.invalid("Repeated native simulation changed fly raster") }
                        }
                        views.append(["name":name,"time":frame.time,"raceTime":frame.raceTime,"tick":frame.current.tick,"carPosition":[frame.current.body.position.x,frame.current.body.position.y,frame.current.body.position.z],"eye":[view.eye.x,view.eye.y,view.eye.z],"target":[view.target.x,view.target.y,view.target.z],"zoom":zoom])
                    }
                }
            }
        }
        let report: [String:Any]=["schema":1,"width":width,"height":height,"imagesRGBA_SHA256":images,"views":views,"rasterRepeatPairs":repeatPairs,"repeatedNativeRuns":2,"framesPerRun":901,"cameraDeselectedFrames":[301,360],"pausedZooms":[67.5,30,90],"scope":"Native selected scene and actual physics; no original GL pixel parity, whole-scene parity or performance claim."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("FLY_VISUAL images=\(images.count) rasterRepeatPairs=\(repeatPairs) nativeRuns=2 exactRepeat=1")
    }
}
