// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSSimulation
import TORCSTrack
import simd
import CryptoKit

@MainActor enum CarTrackShadowSmoke {
    /// Find a shaded road location, then settle native physics there. The normal
    /// start position may be in full sunlight and cannot prove visible shading.
    static func run(content:DrivingContent,renderer:SceneRenderer,mapping:CarTrackShadowMapping?,output:URL) throws -> [String:Any]? {
        guard let mapping,let bounds=content.trackLoaderBounds,let image=content.trackShadow?.pyramid.levels.first else { return nil }
        let geometry=content.simulation.road.geometry,rgba=image.rgba8
        var darkest=Double.infinity,distance:Float=0,samples=0
        for index in geometry.mainSegments {
            let segment=geometry.segments[index],count=max(1,Int(ceil(segment.length/2)))
            for sample in 0..<count {
                let local=TrackLocalPosition(segment:index,toStart:segment.extent*(Float(sample)+0.5)/Float(count))
                let point=geometry.localToGlobal(local,origin:.middle)
                let u=(Double(point.x)-Double(bounds.minimumX))/(Double(bounds.maximumX)-Double(bounds.minimumX))
                let v=(Double(point.y)-Double(bounds.minimumY))/(Double(bounds.maximumY)-Double(bounds.minimumY))
                let x=Int(floor((u-floor(u))*Double(image.width))),y=Int(floor((v-floor(v))*Double(image.height)))
                var brightness=0
                for dy in -1...1 { for dx in -1...1 {
                    let offset=(((y+dy+image.height)%image.height)*image.width+(x+dx+image.width)%image.width)*4
                    brightness += Int(rgba[offset])+Int(rgba[offset+1])+Int(rgba[offset+2])
                } }
                let average=Double(brightness)/27;samples += 1
                if average<darkest { darkest=average;distance=geometry.distanceFromStart(local) }
            }
        }
        var simulation=try SingleVehicleSimulation(definition:content.simulation.vehicle.definition,road:content.simulation.road,startDistance:distance)
        try simulation.settle()
        let pose=try VehiclePresentation(simulation.visualSnapshot),body=pose.body
        let reflection=try CarReflection(body:body,yaw:simulation.visualSnapshot.body.orientation.z,track:geometry,startingAt:0,trackShadow:mapping)
        try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection))
        let eye=body*SIMD4<Float>(-4,-6,4,1),target=body*SIMD4<Float>(0,0,0.5,1)
        renderer.camera=SceneCamera(eye:SIMD3(eye.x,eye.y,eye.z),target:SIMD3(target.x,target.y,target.z),far:1000,fogRange:SIMD2(500,1000))
        try renderer.setShadow(CarShadow(dimensions:content.dimensions).project(body:body) { try geometry.height(at:$0,startingAt:0) },normal:SIMD3(body[2].x,body[2].y,body[2].z))
        renderer.enhancedFiltering=false;renderer.carReflectionsEnabled=true
        var captures:[Data]=[],hashes:[String:String]=[:]
        for enabled in [false,true] {
            renderer.carTrackShadowsEnabled=enabled
            let pixels=try renderer.render(),name="projection-witness-"+(enabled ? "enabled":"disabled")
            try SceneSmoke.writePNG(pixels,width:960,height:640,output:output.appendingPathComponent(name+".png"))
            captures.append(pixels);hashes[name]=SHA256.hash(data:pixels).map { String(format:"%02x",$0) }.joined()
        }
        let repeated=try renderer.render();try SceneSmoke.verifyRasterRepeat(captures[1],repeated)
        let changed=zip(captures[0],captures[1]).reduce(0){ $0+($1.0 == $1.1 ? 0:1) }
        guard changed>0 else { throw RendererError.unavailable("Track shadow projection did not affect the selected shaded-road render") }
        print("CAR_TRACK_SHADOW_WITNESS distance=\(distance) changedChannels=\(changed) roadSamples=\(samples) sampledBrightness=\(darkest)")
        return ["distanceFromStart":distance,"roadSamples":samples,"sampledBrightness":darkest,"changedChannels":changed,"imagesRGBA_SHA256":hashes,"note":"Native vehicle settled at a sampled shaded road location; isolated projection on/off render, not a completed driving lap."]
    }
}
