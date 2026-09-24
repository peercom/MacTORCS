// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSMetal
import TORCSRaceEngine
import TORCSAssets
import simd
import CryptoKit

@MainActor enum MirrorSmoke {
    static func run(content:DrivingContent,renderer:SceneRenderer,output:URL) throws -> [String:Any] {
        let pose=try VehiclePresentation(content.simulation.visualSnapshot)
        let mapping:CarTrackShadowMapping?
        if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds { mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car) } else { mapping=nil }
        let reflection=try CarReflection(body:pose.body,yaw:content.simulation.visualSnapshot.body.orientation.z,track:content.simulation.road.geometry,startingAt:0,trackShadow:mapping)
        let shadow=try CarShadow(dimensions:content.dimensions).project(body:pose.body) { try content.simulation.road.geometry.height(at:$0,startingAt:0) }
        renderer.enhancedFiltering=false;renderer.carReflectionsEnabled=true;renderer.carTrackShadowsEnabled=true
        defer { renderer.mirror=nil }
        let width=960,height=640
        var images:[String:String]=[:],modes:[[String:Any]]=[],repeatCount=0
        func save(_ data:Data,_ name:String,_ w:Int,_ h:Int) throws {
            try SceneSmoke.writePNG(data,width:w,height:h,output:output.appendingPathComponent(name+".png"))
            images[name]=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        }
        for preset in DrivingCameraPreset.allCases.filter(\.allowsMirror) {
            var rig=DrivingCameraRig()
            renderer.camera=try rig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,yaw:0,trackHeading:0) { _ in 0 }
            try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+(preset.drawsCar ? pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,drawDriver:preset.drawsDriver):[]))
            try renderer.setShadow(preset.drawsCar ? shadow:[],normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
            let mirror=RearViewMirror(body:pose.body,bonnetPosition:content.bonnetPosition,hiddenInstances:preset.drawsCar ? Set(1...5):[])
            var times=Array(repeating:[Double](),count:2),frames=Array(repeating:Data(),count:2)
            for iteration in 0..<70 { for mode in 0..<2 {
                renderer.mirror=mode==1 ? mirror:nil
                let frame=try renderer.render(width:width,height:height)
                if iteration>=10 { times[mode].append(renderer.lastGPUTime*1000) }
                if iteration==69 { frames[mode]=frame }
            } }
            let name=preset.rawValue.lowercased()
            for mode in 0..<2 {
                let label=mode==0 ? "off":"on",sorted=times[mode].sorted()
                try save(frames[mode],"mirror-\(name)-\(label)",width,height)
                modes.append(["view":name,"mirror":label,"samples":60,"gpuMedianMS":sorted[30],"gpuP95MS":sorted[57]])
            }
            guard frames[0] != frames[1] else { throw RendererError.unavailable("Mirror did not change \(name) view") }
            for _ in 0..<5 { let pixels=try renderer.render(width:width,height:height);try SceneSmoke.verifyRasterRepeat(frames[1],pixels);repeatCount += 1 }
            if preset == .driver {
                let odd=try renderer.render(width:961,height:641)
                try save(odd,"mirror-driver-odd-size",961,641)
                try SceneSmoke.verifyRasterRepeat(odd,renderer.render(width:961,height:641));repeatCount += 1
                let restored=try renderer.render(width:width,height:height)
                guard restored==frames[1] else { throw RendererError.unavailable("Mirror resize did not restore the same image") }
            }
        }
        print("MIRROR_VISUAL views=3 repeats=\(repeatCount) resizeRestore=1 modes=\(modes)")
        return ["imagesRGBA_SHA256":images,"modes":modes,"repeatCount":repeatCount,"resizeRestoreExact":true,"note":"960x640 stationary single-car scene; interleaved GPU command samples, not gameplay FPS. Odd-size driver image is 961x641."]
    }
}
