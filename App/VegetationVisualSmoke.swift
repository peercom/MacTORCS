// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import CryptoKit
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation

@MainActor enum VegetationVisualSmoke {
    static func run(session:URL,output:URL,measure:Bool=false) throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ACError.invalid("Vegetation output directory already exists") }
        let content=try DrivingContent.load(session),renderer=try SceneRenderer(scenes:content.renderScenes,vegetationResource:5)
        guard let forest=renderer.vegetationForest,!forest.placements.isEmpty else { throw ACError.invalid("No supported tree placements") }
        try renderer.setEnvironment(content.graphics,background:content.background)
        try renderer.setShadowTexture(content.shadow);try renderer.setCarLightTextures(content.lightTextures)
        try renderer.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow)
        let snapshot=content.simulation.visualSnapshot,pose=try VehiclePresentation(snapshot),road=content.simulation.road
        let mapping:CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        let segment=content.simulation.lifecycle.trackPosition.segment
        let reflection=try CarReflection(body:pose.body,yaw:snapshot.body.orientation.z,track:road.geometry,startingAt:segment,trackShadow:mapping)
        let footprint=try CarShadow(dimensions:content.dimensions)
        let shadow=try footprint.project(body:pose.body) { try road.geometry.height(at:$0,startingAt:segment) }
        try renderer.setShadow(shadow,normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
        let world=try CameraWorld(bounds:road.bounds)
        var rig=DrivingCameraRig()
        func camera(_ preset:DrivingCameraPreset) throws -> SceneCamera {
            try rig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,world:world,roadCameraPosition:road.camera(at:segment)?.position,yaw:snapshot.body.orientation.z,trackHeading:0) { try road.geometry.height(at:$0,startingAt:segment) }
        }
        var views:[(String,SceneCamera,Bool)]=[]
        for preset:DrivingCameraPreset in [.chase,.trackside,.driver] { views.append((preset.rawValue,try camera(preset),preset == .driver)) }
        var television=try TVPresentation(carCount:1,settings:.init());try television.activate(screen:0,car:0)
        let runtime=try DrivingRuntime(simulation:content.simulation)
        views.append(("tv",try television.view(screen:0,time:0,frame:[runtime.frame.presentationCar],road:road,world:world).camera,false))
        var fly=try DrivingFlyCamera(height:DrivingSceneHeight(scenes:content.scenes.map { $0.asset.scene },snapshot:snapshot,shadowVertices:shadow,brakeScenes:content.brakeScenes.map { $0.asset.scene },lights:content.lights),vegetation:forest)
        _=try fly.draw(time:0.01,selected:true,snapshot:snapshot,drawsCar:true,drawsDriver:true,shadowVertices:shadow)
        guard let flyView=try fly.draw(time:0.02,selected:true,snapshot:snapshot,drawsCar:true,drawsDriver:true,shadowVertices:shadow) else { throw ACError.invalid("Fly capture did not initialize") }
        views.append(("fly",flyView,false))
        for family in 0..<3 {
            let tree=forest.placements.filter { $0.family==family }.min { simd_distance($0.center,snapshot.body.position)<simd_distance($1.center,snapshot.body.position) }!
            for (label,offset) in [("front",SIMD3<Float>(0,-28,2)),("oblique",SIMD3<Float>(22,-20,10)),("above",SIMD3<Float>(1,-3,32))] {
                views.append(("tree-\(family)-\(label)",SceneCamera(eye:tree.center+offset,target:tree.center,fieldOfView:50 * .pi/180,near:0.2,far:600,fogRange:SIMD2(300,600)),false))
            }
        }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var records:[[String:Any]]=[],images:[String:String]=[:],timings:[[String:Any]]=[],failures:[[String:Any]]=[]
        let width=960,height=640
        for (name,camera,mirror) in views {
            renderer.camera=camera
            renderer.mirror=mirror ? RearViewMirror(body:pose.body,bonnetPosition:content.bonnetPosition,hiddenInstances:Set(1...17)):nil
            try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,drawDriver:!mirror,brakeResources:content.brakeResources))
            for quality in [false,true] {
                renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                var original:Data?
                for enhanced in [false,true] {
                    renderer.enhancedVegetation=enhanced
                    let title="\(name)-\(quality ? "quality":"classic")-\(enhanced ? "volume":"original")"
                    let pixels=try renderer.render(width:width,height:height,captureCommands:true),digest=renderer.lastSubmissionSHA256
                    let repeated=try renderer.render(width:width,height:height,captureCommands:true)
                    do { try SceneSmoke.verifyRasterRepeat(pixels,repeated) }
                    catch {
                        print("VEGETATION_FAILED_VIEW \(title) COMMANDS_EQUAL \(digest==renderer.lastSubmissionSHA256)")
                        let differences=zip(pixels,repeated).map { abs(Int($0)-Int($1)) }
                        failures.append(["name":title,"changedChannels":differences.filter { $0>0 }.count,"maximumByteDelta":differences.max() ?? 0,"error":String(describing:error)])
                        try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(title+"-failed-first.png"))
                        try SceneSmoke.writePNG(repeated,width:width,height:height,output:output.appendingPathComponent(title+"-failed-repeat.png"))
                        for index in 0..<2 {
                            let next=try renderer.render(width:width,height:height,captureCommands:true)
                            print("VEGETATION_FAILED_NEXT_COMMANDS_EQUAL \(digest==renderer.lastSubmissionSHA256)")
                            try SceneSmoke.writePNG(next,width:width,height:height,output:output.appendingPathComponent(title+"-failed-next-\(index).png"))
                        }
                    }
                    guard digest==renderer.lastSubmissionSHA256 else { throw ACError.invalid("Vegetation repeat changed commands") }
                    let changed=original.map { zip($0,pixels).reduce(0) { $0+($1.0 == $1.1 ? 0:1) } } ?? 0
                    if !enhanced { original=pixels }
                    images[title]=SHA256.hash(data:pixels).map { String(format:"%02x",$0) }.joined()
                    try SceneSmoke.writePNG(pixels,width:width,height:height,output:output.appendingPathComponent(title+".png"))
                    records.append(["name":title,"enhanced":enhanced,"quality":quality,"changedChannels":changed,"draws":renderer.lastVegetationDrawCount,"triangles":renderer.lastVegetationTriangleCount,"eye":[camera.eye.x,camera.eye.y,camera.eye.z],"target":[camera.target.x,camera.target.y,camera.target.z],"physicsTick":snapshot.tick])
                }
                renderer.enhancedVegetation=false
                let restored=try renderer.render(width:width,height:height)
                if let original,original != restored {
                    let title="\(name)-\(quality ? "quality":"classic")-restoration"
                    let differences=zip(original,restored).map { abs(Int($0)-Int($1)) }
                    failures.append(["name":title,"changedChannels":differences.filter { $0>0 }.count,"maximumByteDelta":differences.max() ?? 0,"error":"Original tree restoration changed pixels"])
                    try SceneSmoke.writePNG(original,width:width,height:height,output:output.appendingPathComponent(title+"-expected.png"))
                    try SceneSmoke.writePNG(restored,width:width,height:height,output:output.appendingPathComponent(title+"-actual.png"))
                    print("VEGETATION_FAILED_RESTORATION \(title)")
                }
            }
        }
        if measure && failures.isEmpty {
            renderer.camera=views.first!.1;renderer.mirror=nil
            try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,brakeResources:content.brakeResources))
            var gpu=Array(repeating:[Double](),count:4),wall=gpu
            for sample in 0..<70 { for mode in 0..<4 {
                renderer.smoothEdges=mode>=2;renderer.enhancedFiltering=mode>=2;renderer.enhancedVegetation=mode%2==1
                let start=ProcessInfo.processInfo.systemUptime
                _=try renderer.render(width:width,height:height)
                if sample>=10 { gpu[mode].append(renderer.lastGPUTime*1000);wall[mode].append((ProcessInfo.processInfo.systemUptime-start)*1000) }
            } }
            for mode in 0..<4 { let g=gpu[mode].sorted(),w=wall[mode].sorted();timings.append(["quality":mode>=2,"enhanced":mode%2==1,"samples":g.count,"gpuMedianMS":g[30],"gpuP95MS":g[57],"wallMedianMS":w[30]]) }
        }
        let report:[String:Any]=["schema":1,"trees":forest.placements.count,"familyCounts":(0..<3).map { family in forest.placements.filter { $0.family==family }.count },"sharedMeshes":forest.meshes.count,"sourceAtlasTextures":1,"imagesRGBA_SHA256":images,"records":records,"rasterRepeatPairs":records.count,"repeatFailures":failures,"repeatAcceptancePassed":failures.isEmpty,"timings":timings,"scope":"Optional volume enhancement using existing local artwork. Fixed native settled pose and matched camera views; Fly canopy height tested separately. Tree shadows and moving LOD transition acceptance remain pending. Stationary offscreen timings exclude loading and physics; no full-race FPS claim."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("VEGETATION_VISUAL trees=\(forest.placements.count) images=\(images.count) repeatPairs=\(records.count) acceptancePassed=\(failures.isEmpty ? 1:0) failures=\(failures.count)")
        guard failures.isEmpty else { throw ACError.invalid("Vegetation raster acceptance failed for \(failures.count) views; all captures and failures recorded") }
    }
}
