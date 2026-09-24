// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSMetal
import TORCSRaceEngine
import TORCSAssets
import simd
import CryptoKit

/// Offscreen diagnostic of actual compiled content and native settled physics.
/// GPU command timings exclude CPU readback; these are not gameplay FPS.
@MainActor enum DrivingVisualSmoke {
    static func run(session: URL,output: URL) throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ACError.invalid("Visual output directory already exists") }
        let content=try DrivingContent.load(session),renderer=try SceneRenderer(scenes:content.scenes)
        guard let texture=content.shadow else { throw ACError.invalid("Prepare a session with a shadow texture first") }
        try renderer.setEnvironment(content.graphics,background:content.background)
        try renderer.setShadowTexture(texture)
        try renderer.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow)
        let world=try CameraWorld(bounds:content.simulation.road.bounds)
        let pose=try VehiclePresentation(content.simulation.visualSnapshot)
        let mapping:CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        let reflection=try CarReflection(body:pose.body,yaw:content.simulation.visualSnapshot.body.orientation.z,track:content.simulation.road.geometry,startingAt:0,trackShadow:mapping)
        let shadowNormal=SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z)
        let shadow=try CarShadow(dimensions:content.dimensions).project(body:pose.body) { try content.simulation.road.geometry.height(at:$0,startingAt:0) }
        // Query resolution walks from a valid segment, like the gameplay path.
        try renderer.setShadow(shadow,normal:shadowNormal)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let width=960,height=640
        func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
        var images:[String:String]=[:],repeats:[[String:Any]]=[],repeatFailures=0
        for preset in DrivingCameraPreset.allCases where preset != .fly && preset != .television {
            try renderer.setShadow(preset.drawsCar ? shadow:[],normal:shadowNormal)
            try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+(preset.drawsCar ? pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,drawDriver:preset.drawsDriver):[]))
            var rig=DrivingCameraRig()
            let p=pose.body[3],geometry=content.simulation.road.geometry
            let heading=geometry.tangent(try geometry.globalToLocal(SIMD2(p.x,p.y),startingAt:0))
            for _ in 0..<200 {
                renderer.camera=try rig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,world:world,roadCameraPosition:content.simulation.road.camera(at:content.simulation.vehicle.chassis.trackPosition.segment)?.position,yaw:content.simulation.visualSnapshot.body.orientation.z,trackHeading:heading) {
                    try geometry.height(at:$0,startingAt:0)
                }
            }
            for smoothing in [false,true] {
            renderer.smoothEdges=smoothing
            let pixels=try renderer.render(width:width,height:height,captureCommands:true)
            let submission=renderer.lastSubmissionSHA256
            let name=preset.rawValue.replacingOccurrences(of:" ",with:"-").lowercased()+(smoothing ? "-smooth":"")
            try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(name+".png"));images[name]=hash(pixels)
            let repeated=try renderer.render(width:width,height:height,captureCommands:true)
            let deltas=zip(pixels,repeated).map { abs(Int($0)-Int($1)) }
            repeats.append(["camera":name,"changedChannels":deltas.filter{$0>0}.count,"maximumChannelDelta":deltas.max() ?? 0,"sameSubmittedCommands":submission==renderer.lastSubmissionSHA256])
            do { try SceneSmoke.verifyRasterRepeat(pixels,repeated) }
            catch {
                try SceneSmoke.writePNG(repeated,width:width,height:height,output:output.appendingPathComponent(name+"-repeat-failure.png"))
                repeatFailures += 1
                print("Raster failure in \(name): \(error)")
            }
        }
        }
        renderer.smoothEdges=false
        var chase=DrivingCamera()
        for _ in 0..<200 { renderer.camera=try chase.update(position:content.simulation.visualSnapshot.body.position,yaw:content.simulation.visualSnapshot.body.orientation.z) { try content.simulation.road.geometry.height(at:$0,startingAt:0) } }
        try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection))
        let baseline=try SceneRenderer(scenes:content.scenes)
        baseline.camera=renderer.camera;try baseline.setInstances(renderer.instances);try baseline.setShadowTexture(texture)
        var times=Array(repeating:[Double](),count:6),cpu=Array(repeating:[Double](),count:6),captures:[Data]=[]
        // Interleave modes to reduce warming/order bias. Discard 10 warmups each.
        for iteration in 0..<70 { for mode in 0..<6 {
            try autoreleasepool {
                let active=mode==3 ? baseline:renderer
                try active.setShadow(mode==0 ? []:shadow,normal:shadowNormal);active.enhancedFiltering=mode==2;active.carReflectionsEnabled=mode != 4;active.carTrackShadowsEnabled=mode != 5
                let start=ProcessInfo.processInfo.systemUptime
                let pixels=try active.render(width:width,height:height)
                let elapsed=ProcessInfo.processInfo.systemUptime-start
                if iteration>=10 { times[mode].append(active.lastGPUTime*1000);cpu[mode].append(elapsed*1000) }
                if iteration==69 { captures.append(pixels) }
            }
        } }
        func changed(_ a:Data,_ b:Data)->Int { zip(a,b).reduce(0) { $0+($1.0 == $1.1 ? 0:1) } }
        let shadowChange=changed(captures[0],captures[1]),filterChange=changed(captures[1],captures[2])
        guard shadowChange>0,filterChange>0 else { throw ACError.invalid("Shadow or filtering did not affect the content render") }
        let names=["classic-no-shadow","classic-shadow","enhanced-shadow","previous-placeholder-lighting","classic-shadow-no-reflections","classic-shadow-no-track-projection"]
        var modes:[[String:Any]]=[]
        for i in 0..<6 {
            let sorted=times[i].sorted(),wall=cpu[i].sorted()
            modes.append(["mode":names[i],"samples":sorted.count,"gpuMedianMS":sorted[30],"gpuP95MS":sorted[57],"offscreenWallMedianMS":wall[30]])
            try SceneSmoke.writePNG(captures[i],width:width,height:height,output:output.appendingPathComponent(names[i]+".png"))
            images[names[i]]=hash(captures[i])
        }
        let witness=try CarTrackShadowSmoke.run(content:content,renderer:renderer,mapping:mapping,output:output)
        let mirrors=try MirrorSmoke.run(content:content,renderer:renderer,output:output)
        let smoothing=try EdgeSmoothingSmoke.run(content:content,renderer:renderer,output:output)
        let trackside=try TracksideSmoke.run(content:content,renderer:renderer,mapping:mapping,output:output)
        let zoom=try CameraZoomSmoke.run(content:content,renderer:renderer,mapping:mapping,output:output)
        let report:[String:Any]=["schema":4,"trackShadowWitness":witness ?? [:],"uniqueSceneGPUTextures":renderer.sceneTextureCount,"carTrackShadowAvailable":content.trackShadow != nil && mapping != nil,"changedTrackProjectionChannels":changed(captures[1],captures[5]),"carEnvironmentAvailable":content.reflection != nil && content.environmentShade != nil,"changedReflectionChannels":changed(captures[1],captures[4]),"rasterRepeatPassed":repeatFailures==0,"rasterRepeat":repeats,"width":width,"height":height,"imagesRGBA_SHA256":images,"cameraCount":DrivingCameraPreset.allCases.filter { $0 != .fly && $0 != .television }.count,"shadowVertices":6,"shadowTriangles":4,"changedShadowChannels":shadowChange,"changedFilteringChannels":filterChange,"modes":modes,"note":"Offscreen stationary single-car scene. Per-command GPU timing, not gameplay FPS or multi-car performance. Classic filtering remains default."]
        var completeReport=report;completeReport["schema"]=8;completeReport["cameraZoom"]=zoom;completeReport["trackside"]=trackside;completeReport["mirrors"]=mirrors;completeReport["edgeSmoothing"]=smoothing
        try JSONSerialization.data(withJSONObject:completeReport,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"),options:.atomic)
        print("DRIVING_VISUAL cameras=\(DrivingCameraPreset.allCases.filter { $0 != .fly && $0 != .television }.count) repeatFailures=\(repeatFailures) shadowChangedChannels=\(shadowChange) filteringChangedChannels=\(filterChange) timings=\(modes)")
        guard repeatFailures==0 else { throw RendererError.unavailable("\(repeatFailures) camera repeat checks failed; full report and failure images were saved") }
    }
}
