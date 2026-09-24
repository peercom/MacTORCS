// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of cGrCarCamBehind in TORCS 1.3.9 grcam.cpp.
// Copyright (C) 2000 Eric Espie; upstream GPL-2.0-or-later.
import simd
import TORCSAssets

public enum DrivingCameraPreset: String,CaseIterable,Sendable {
    case chase="Chase",near="Near chase",far="Far chase",low="Low chase",bonnet="Bonnet",road="Road"
    case trackAligned="Track chase",reverse="Reverse"
    case side1="Side 1",side2="Side 2",side3="Side 3",side4="Side 4"
    case side5="Side 5",side6="Side 6",side7="Side 7",side8="Side 8"
    case overhead1="Overhead 1",overhead2="Overhead 2",overhead3="Overhead 3",overhead4="Overhead 4"
    case driver="Driver",circuit="Circuit center"
    case panorama1="Panorama 1",panorama2="Panorama 2",panorama3="Panorama 3",panorama4="Panorama 4",panorama5="Panorama 5"
    case trackside="Trackside",tracksideZoom="Trackside zoom",fly="Fly",television="TV director"
    public var isTrackside: Bool { self == .trackside || self == .tracksideZoom }
    public var drawsDriver: Bool { self != .driver }
    public var allowsMirror: Bool { self == .driver || self == .bonnet || self == .road }
    public var isSurvey: Bool { [.circuit,.panorama1,.panorama2,.panorama3,.panorama4,.panorama5].contains(self) }
    public var drawsCar: Bool { self != .road }
    public var isChase: Bool { [.chase,.near,.far,.low].contains(self) }
    public var family: String {
        switch self {
        case .trackside,.tracksideZoom,.fly,.television: "Trackside views"
        case .circuit,.panorama1,.panorama2,.panorama3,.panorama4,.panorama5: "Circuit views"
        case .side1,.side2,.side3,.side4,.side5,.side6,.side7,.side8: "Side views"
        case .overhead1,.overhead2,.overhead3,.overhead4: "Overhead views"
        default: "Driving views"
        }
    }
    public var distance: Float { switch self { case .near:10;case .far:20;case .low:8;default:6 } }
    public var height: Float { self == .low ? 0.5:2 }
}

/// Owns the independent per-view relaxation state used by the original camera lists.
/// Only the selected camera advances, once per graphics update.
public struct DrivingCameraRig: Sendable {
    private var chase=Dictionary(uniqueKeysWithValues:DrivingCameraPreset.allCases.filter(\.isChase).map { preset in
        var camera=DrivingCamera();camera.preset=preset;return (preset,camera)
    })
    private var trackYaw:Float=0
    public init() {}
    public mutating func view(preset:DrivingCameraPreset,body:simd_float4x4,bonnetPosition:SIMD3<Float>,driverPosition:SIMD3<Float>? = nil,world:CameraWorld? = nil,roadCameraPosition:SIMD3<Float>? = nil,zoomValue:Float? = nil,yaw:Float,trackHeading:Float,groundHeight:(SIMD2<Float>) throws -> Float) throws -> SceneCamera {
        if let zoomValue { try preset.validateZoom(zoomValue) }
        var camera=try baseView(preset:preset,body:body,bonnetPosition:bonnetPosition,driverPosition:driverPosition,world:world,roadCameraPosition:roadCameraPosition,yaw:yaw,trackHeading:trackHeading,groundHeight:groundHeight)
        if let zoomValue {
            var degrees=zoomValue
            if preset.distanceScaledZoom {
                let eye=camera.eye,dx=body[3].x-eye.x,dy=body[3].y-eye.y,dz=body[3].z-eye.z
                let distance=sqrt(dx*dx+dy*dy+dz*dz)
                degrees=Float(Double(atan2(zoomValue,distance))*(180/Double.pi))
            }
            let radians=degrees * .pi/180
            guard radians>0,radians.isFinite,(1/tan(radians/2)).isFinite else { throw ACError.invalid("Camera zoom produces a degenerate projection") }
            camera.fieldOfView=radians
        }
        return camera
    }
    private mutating func baseView(preset:DrivingCameraPreset,body:simd_float4x4,bonnetPosition:SIMD3<Float>,driverPosition:SIMD3<Float>? = nil,world:CameraWorld? = nil,roadCameraPosition:SIMD3<Float>? = nil,yaw:Float,trackHeading:Float,groundHeight:(SIMD2<Float>) throws -> Float) throws -> SceneCamera {
        guard preset != .fly else { throw ACError.invalid("Fly camera requires DrivingFlyCamera with time and assembled scenery") }
        guard preset != .television else { throw ACError.invalid("TV director requires TVPresentation with a complete race frame") }
        let position=SIMD3(body[3].x,body[3].y,body[3].z)
        if preset == .driver {
            guard let driverPosition else { throw ACError.invalid("Driver camera needs a configured seating position") }
            let eye=body*SIMD4(driverPosition,1),target=body*SIMD4(driverPosition+SIMD3(30,0,0),1)
            return SceneCamera(eye:SIMD3(eye.x,eye.y,eye.z),target:SIMD3(target.x,target.y,target.z),fieldOfView:67.5 * .pi/180,near:0.1,far:600,fogRange:SIMD2(300,600))
        }
        if preset.isTrackside {
            guard let world else { throw ACError.invalid("Trackside cameras need track world dimensions") }
            return world.tracksideCamera(zoomed: preset == .tracksideZoom, position: roadCameraPosition, carPosition: position)
        }
        if preset.isSurvey {
            guard let world else { throw ACError.invalid("Circuit cameras need track world dimensions") }
            return world.camera(preset:preset,carPosition:position)
        }
        if preset.isChase { return try chase[preset]!.update(position:position,yaw:yaw,groundHeight:groundHeight) }
        if preset == .bonnet || preset == .road { return DrivingCamera.bonnet(body:body,position:bonnetPosition) }
        var eye=position,up=SIMD3<Float>(0,0,1),fov:Float=40,near:Float=1
        switch preset {
        case .trackAligned:
            let difference=trackYaw-trackHeading
            if abs(Double(difference))>abs(Double(difference)+2 * .pi) { trackYaw=Float(Double(trackYaw)+2 * .pi) }
            else if abs(Double(difference))>abs(Double(difference)-2 * .pi) { trackYaw=Float(Double(trackYaw)-2 * .pi) }
            let angle=Float(Double(trackYaw)+5*Double(trackHeading-trackYaw)*0.01)
            trackYaw=angle
            let point=SIMD2(position.x-30*cos(angle),position.y-30*sin(angle))
            eye=SIMD3(point.x,point.y,try groundHeight(point)+5)
        case .reverse:
            let point=SIMD2(position.x+8*cos(yaw),position.y+8*sin(yaw))
            eye=SIMD3(point.x,point.y,try groundHeight(point)+0.5);near=0.5
        case .side1,.side2,.side3,.side4,.side5,.side6,.side7,.side8:
            let sides:[DrivingCameraPreset]=[.side1,.side2,.side3,.side4,.side5,.side6,.side7,.side8]
            let index=sides.firstIndex(of:preset)!,scale:Float=index<4 ? 1:2
            let offsets:[SIMD3<Float>]=[SIMD3(0,-20,3),SIMD3(0,20,3),SIMD3(-20,0,3),SIMD3(20,0,3)]
            eye=position+offsets[index%4]*scale;fov=30
        case .overhead1,.overhead2,.overhead3,.overhead4:
            let index=[DrivingCameraPreset.overhead1,.overhead2,.overhead3,.overhead4].firstIndex(of:preset)!
            let heights:[Float]=[200,250,350,400]
            let axes:[SIMD3<Float>]=[SIMD3(0,1,0),SIMD3(0,-1,0),SIMD3(1,0,0),SIMD3(-1,0,0)]
            eye.z += heights[index];up=axes[index];fov=67.5;near=index==0 ? 100:200
        default: break // Bonnet, road and the four chase presets returned above.
        }
        return SceneCamera(eye:eye,target:position,fieldOfView:fov * .pi/180,near:near,far:1000,up:up,fogRange:SIMD2(500,1000))
    }
}

/// Original F2/F3 chase camera. Its original relaxation is per graphics
/// update, not elapsed-time based. Keep that behavior explicit and testable.
public struct DrivingCamera: Sendable {
    private var previousYaw: Float=0
    public var preset: DrivingCameraPreset = .chase
    public init() {}
    public mutating func update(position: SIMD3<Float>,yaw: Float,groundHeight: (SIMD2<Float>) throws -> Float) rethrows -> SceneCamera {
        let difference=previousYaw-yaw
        if abs(Double(difference))>abs(Double(difference)+2 * .pi) { previousYaw=Float(Double(previousYaw)+2 * .pi) }
        else if abs(Double(difference))>abs(Double(difference)-2 * .pi) { previousYaw=Float(Double(previousYaw)-2 * .pi) }
        let angle=Float(Double(previousYaw)+10*Double(yaw-previousYaw)*0.01)
        previousYaw=angle
        let c=cos(angle),s=sin(angle)
        let xy=SIMD2(position.x-preset.distance*c,position.y-preset.distance*s)
        let eye=SIMD3(xy.x,xy.y,try groundHeight(xy)+preset.height)
        let target=SIMD3(position.x+(10-preset.distance)*c,position.y+(10-preset.distance)*s,position.z)
        return SceneCamera(eye:eye,target:target,near:preset == .low ? 0.5:1,fogRange:SIMD2(300,600))
    }
}

// Original cGrCarCamInsideFixedCar: body roll follows the bonnet camera.
extension DrivingCamera {
    public static func bonnet(body: simd_float4x4,position: SIMD3<Float>) -> SceneCamera {
        let eye=body*SIMD4(position,1),target=body*SIMD4(position+SIMD3(30,0,0),1)
        return SceneCamera(eye:SIMD3(eye.x,eye.y,eye.z),target:SIMD3(target.x,target.y,target.z),
            fieldOfView:67.5 * .pi/180,near:0.3,far:600,up:SIMD3(body[2].x,body[2].y,body[2].z),fogRange:SIMD2(300,600))
    }
}
