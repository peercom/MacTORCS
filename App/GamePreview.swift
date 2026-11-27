// SPDX-License-Identifier: GPL-2.0-only
// Menu images made by the game's own renderer: a car standing on a real
// grid, a circuit seen from above its start line. Rendered offscreen when a
// library is prepared, so the menus show what the player will drive.
import Foundation
import Metal
import QuartzCore
import simd
import TORCSAssets
import TORCSPresentation
import TORCSRaceEngine
import TORCSRender
import TORCSTrack
import TORCSTrackMesh

@MainActor enum GamePreview {
    enum Subject: String { case car,track }
    /// `--render-preview car|track <track-dir> <car-dir> <output.png> [WxH]`
    static func runIfRequested() {
        let arguments=CommandLine.arguments
        guard let index=arguments.firstIndex(of:"--render-preview") else { return }
        do {
            guard arguments.count>=index+5,let subject=Subject(rawValue:arguments[index+1]) else {
                throw RenderError.unavailable("Usage: --render-preview car|track track-directory car-directory output.png [WIDTHxHEIGHT]")
            }
            var width=1280,height=720
            if arguments.count>index+5 {
                let parts=arguments[index+5].split(separator:"x").compactMap { Int($0) }
                if parts.count==2,parts.allSatisfy({ (64...4096).contains($0) }) { width=parts[0];height=parts[1] }
            }
            try render(subject,track:URL(fileURLWithPath:arguments[index+2]),car:URL(fileURLWithPath:arguments[index+3]),
                       output:URL(fileURLWithPath:arguments[index+4]),width:width,height:height)
            exit(0)
        } catch { FileHandle.standardError.write(Data("torcs: \(error)\n".utf8));exit(2) }
    }
    /// `--frame-cost <track-dir> <car-dir> [WxH] [preset]`: what one frame of
    /// the chase view costs the GPU on this content, pass by pass, rendered
    /// offscreen at the given size. A synchronous loop lowers the GPU's
    /// clock, so the passes are comparable with one another, not with a
    /// paced frame.
    static func costIfRequested() {
        let arguments=CommandLine.arguments
        guard let index=arguments.firstIndex(of:"--frame-cost") else { return }
        do {
            guard arguments.count>=index+3 else { throw RenderError.unavailable("Usage: --frame-cost track-directory car-directory [WIDTHxHEIGHT] [m2Air|balanced|high]") }
            var width=2560,height=1664
            if arguments.count>index+3 {
                let parts=arguments[index+3].split(separator:"x").compactMap { Int($0) }
                if parts.count==2 { width=parts[0];height=parts[1] }
            }
            let preset=arguments.count>index+4 ? RenderSettings.Preset(rawValue:arguments[index+4]) ?? .m2Air:.m2Air
            let track=URL(fileURLWithPath:arguments[index+1])
            let content=try DrivingContent.load(track:track,car:URL(fileURLWithPath:arguments[index+2]))
            // `--archive`: through the saved pipeline archive, as the window does.
            let archive: PipelineArchive? = arguments.contains("--archive")
                ? try PipelineArchive(device:MTLCreateSystemDefaultDevice()!,directory:FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("TORCSMac",isDirectory:true))
                : nil
            var settings=RenderSettings(preset:preset)
            settings.upscalingMode = .resolve   // as the game sets it; `--render-off metalfx` for the scaler
            DrivingSession.applyRenderOff(&settings)
            let renderer=try ForwardRenderer(settings:settings,archive:archive)
            if let archive { print("archive \(archive.url.lastPathComponent) loaded=\(archive.loaded)") }
            renderer.passTimer=try PassTimer(device:renderer.device)
            // `--full-blur`: every streak gathered from the scene itself, to compare.
            if arguments.contains("--full-blur") { renderer.motionBlur.usesHalfResolution=false }
            let resources=try SessionRenderResources(
                device:renderer.device,scenes:content.renderScenes,
                road:content.simulation.road.geometry,pits:content.simulation.road.pits,terrain:TerrainParameters(),
                materials:ModernDrivingRenderer.materialsDirectory(beside:track))
            // With `--substitutions`: which of the circuit's textures a generated set replaced.
            if arguments.contains("--substitutions"),let library=resources.materials {
                for (texture,set) in library.substitutions.sorted(by:{ $0.key<$1.key }) { print("substituted \(texture) -> \(set)") }
            }
            let lighting=ModernDrivingRenderer.lighting(from:content.graphics)
            renderer.roadPaint.set(content.gridSlots.map { RoadPaint.Box(centre:$0.world,yaw:$0.yaw) })
            let pose=try VehiclePresentation(content.simulation.visualSnapshot)
            let body=pose.body
            let centre=SIMD3(body[3].x,body[3].y,body[3].z),forward=simd_normalize(SIMD3(body[0].x,body[0].y,body[0].z))
            var camera=RenderCamera(eye:centre-forward*6+SIMD3(0,0,2),target:centre+forward*10,verticalFieldOfView:40 * .pi/180,near:1,far:4000)
            if arguments.contains("--chase") {
                // The game's own chase camera, settled as it is in the window.
                var rig=DrivingCameraRig()
                let world=try CameraWorld(bounds:content.simulation.road.bounds)
                let geometry=content.simulation.road.geometry
                var scene: SceneCamera?
                for _ in 0..<200 {
                    scene=try rig.view(preset:.chase,body:body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,world:world,
                                       roadCameraPosition:nil,yaw:content.simulation.visualSnapshot.body.orientation.z,trackHeading:0) { try geometry.height(at:$0,startingAt:0) }
                }
                if let scene {
                    camera=ModernDrivingRenderer.camera(from:scene)
                    print("chase camera eye=\(scene.eye) target=\(scene.target) fov=\(scene.fieldOfView) clip=\(scene.clippingRange) -> near=\(camera.near) far=\(camera.far)")
                }
            }
            let instances=resources.staticInstances()+ModernDrivingRenderer.vehicleInstances(pose,drawsDriver:true,drawsCar:true,castsShadow:true)
            renderer.resetsHistoryPerRender=false
            var frames: [Double]=[],passes: [String:[Double]]=[:],order: [String]=[]
            // With `--animate` time runs as it does in the window, so anything
            // that moves with it (wind in the trees, their shadows) is redrawn.
            let animate=arguments.contains("--animate")
            // With `--pace HZ` a frame is rendered once per interval and the
            // GPU idles in between, as it does behind a display.
            let pace=arguments.firstIndex(of:"--pace").flatMap { $0+1<arguments.count ? Double(arguments[$0+1]):nil }
            // With `--lap N` the frame is measured from N viewpoints spread
            // round the circuit, behind and above the centreline as the chase
            // camera sits, instead of from the start grid alone: what a lap
            // costs, not what the grid costs.
            var views: [RenderCamera]=[]
            if let n=arguments.firstIndex(of:"--lap").flatMap({ $0+1<arguments.count ? Int(arguments[$0+1]):nil }),n>0 {
                let geometry=content.simulation.road.geometry
                let main=geometry.segments.indices.filter { geometry.segments[$0].role == .main }
                let lapLength=main.reduce(Float(0)) { $0+geometry.segments[$1].length }
                for k in 0..<n {
                    let target=lapLength*Float(k)/Float(n)
                    guard let index=main.last(where:{ geometry.segments[$0].distanceFromStart<=target }) ?? main.first else { continue }
                    let local=TrackLocalPosition(segment:index,toStart:0)
                    let ground=geometry.localToGlobal(local,origin:.middle),heading=geometry.tangent(local)
                    let at=SIMD3(ground.x,ground.y,(try? geometry.height(at:ground,startingAt:index)) ?? 0)
                    let along=SIMD3(cos(heading),sin(heading),0)
                    // With `--turn DEGREES` each view looks that far to the left of
                    // the road (negative for the right): at what stands beside
                    // the track, which a view down the road sees only edge on.
                    let turn=(arguments.firstIndex(of:"--turn").flatMap { $0+1<arguments.count ? Float(arguments[$0+1]):nil } ?? 0) * .pi/180
                    let look=SIMD3(cos(heading+turn),sin(heading+turn),0)
                    views.append(RenderCamera(eye:at-along*6+SIMD3(0,0,2),target:at-along*6+look*16+SIMD3(0,0,turn == 0 ? 0:2),verticalFieldOfView:camera.verticalFieldOfView,near:camera.near,far:camera.far))
                }
            }
            let perView=18
            let speed=arguments.firstIndex(of:"--speed").flatMap { $0+1<arguments.count ? Float(arguments[$0+1]):nil } ?? 0
            let dump=arguments.firstIndex(of:"--dump").flatMap { $0+1<arguments.count ? URL(fileURLWithPath:arguments[$0+1],isDirectory:true):nil }
            if let dump { try FileManager.default.createDirectory(at:dump,withIntermediateDirectories:true) }
            let total=views.isEmpty ? (pace==nil ? 60:240):views.count*perView
            var next=ProcessInfo.processInfo.systemUptime
            for frame in 0..<total {
                if !views.isEmpty {
                    camera=views[frame/perView]
                    // `--speed MPS`: the viewpoint travels forward at that
                    // speed, so the frame has motion to blur as a drive does.
                    if speed != 0 {
                        let step=simd_normalize(camera.target-camera.eye)*(speed/60*Float(frame%perView))
                        camera.eye += step;camera.target += step
                    }
                    if frame%perView==0 { renderer.resetHistory() }
                }
                if let pace {
                    next += 1/pace
                    let wait=next-ProcessInfo.processInfo.systemUptime
                    if wait>0 { Thread.sleep(forTimeInterval:wait) } else { next=ProcessInfo.processInfo.systemUptime }
                }
                // `--uptime` starts time where the window's does: at the machine's uptime.
                if animate { renderer.animationTime=Double(frame)/60+(arguments.contains("--uptime") ? CACurrentMediaTime():1) }
                let pixels=try renderer.render(resources:resources.resources,instances:instances,camera:camera,lighting:lighting,width:width,height:height)
                // `--dump DIR`: the last frame of each viewpoint as a PNG, for
                // comparing the picture before and after a change to the shaders.
                if let dump,!views.isEmpty,frame%perView==perView-1 {
                    try writePNG(Data(pixels),width:width,height:height,output:dump.appendingPathComponent(String(format:"view-%02d.png",frame/perView)))
                }
                guard views.isEmpty ? frame>=total/3:frame%perView>=perView/3 else { continue }
                frames.append(renderer.lastGPUTime*1000)
                for sample in renderer.lastPassTimes {
                    if passes[sample.name]==nil { order.append(sample.name) }
                    passes[sample.name,default:[]].append(sample.seconds*1000)
                }
            }
            func median(_ values: [Double]) -> Double { let s=values.sorted();return s.isEmpty ? 0:s[s.count/2] }
            print(String(format:"frame-cost %@ %dx%d preset=%@ gpu=%.2f ms draws=%d triangles=%d",content.track.name,width,height,preset.rawValue,median(frames),renderer.lastDrawCount,renderer.lastTriangleCount))
            for name in order.sorted(by:{ median(passes[$0]!)>median(passes[$1]!) }) {
                print(String(format:"  %-30@ %6.2f ms",name as NSString,median(passes[name]!)))
            }
            exit(0)
        } catch { FileHandle.standardError.write(Data("torcs: \(error)\n".utf8));exit(2) }
    }
    static func render(_ subject: Subject,track: URL,car: URL,output: URL,width: Int,height: Int) throws {
        let content=try DrivingContent.load(track:track,car:car)
        let renderer=try ForwardRenderer()
        let resources=try SessionRenderResources(
            device:renderer.device,scenes:content.renderScenes,
            road:content.simulation.road.geometry,pits:content.simulation.road.pits,terrain:TerrainParameters(),
            materials:ModernDrivingRenderer.materialsDirectory(beside:track))
        let lighting=ModernDrivingRenderer.lighting(from:content.graphics)
        let pose=try VehiclePresentation(content.simulation.visualSnapshot)
        let body=pose.body
        let centre=SIMD3(body[3].x,body[3].y,body[3].z)
        let forward=simd_normalize(SIMD3(body[0].x,body[0].y,body[0].z))
        let right=simd_normalize(SIMD3(body[1].x,body[1].y,body[1].z))
        let camera: RenderCamera
        var instances=resources.staticInstances()
        switch subject {
        case .car:
            // Three-quarter front, low, the whole car in frame with air around it.
            let length=max(content.dimensions.x,3.5)
            camera=RenderCamera(eye:centre+forward*(length*1.05)+right*(length*0.82)+SIMD3(0,0,1.15),
                                target:centre+SIMD3(0,0,0.42),
                                verticalFieldOfView:30 * .pi/180,near:0.2,far:4000)
            instances += ModernDrivingRenderer.vehicleInstances(pose,drawsDriver:true,drawsCar:true,castsShadow:true)
        case .track:
            // From the back of the grid, a little above a driver's eye,
            // looking down the start straight.
            camera=RenderCamera(eye:centre-forward*26-right*1.5+SIMD3(0,0,3.4),
                                target:centre+forward*80+SIMD3(0,0,2.2),
                                verticalFieldOfView:52 * .pi/180,near:0.5,far:6000)
        }
        // The exposure meter and the temporal passes settle over a few frames.
        var pixels: [UInt8]=[]
        let resets=renderer.resetsHistoryPerRender
        renderer.resetsHistoryPerRender=false
        renderer.resetHistory()
        for _ in 0..<24 {
            pixels=try renderer.render(resources:resources.resources,instances:instances,camera:camera,
                                       lighting:lighting,width:width,height:height)
        }
        renderer.resetsHistoryPerRender=resets
        try writePNG(Data(pixels),width:width,height:height,output:output)
        print("preview \(subject.rawValue) \(output.path) \(width)x\(height)")
    }
}
