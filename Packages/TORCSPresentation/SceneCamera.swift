// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS grcam camera conventions. Copyright (C) 2000 Eric Espie; upstream GPL-2.0-or-later.
import simd

/// A camera in TORCS world coordinates, Z up: an orbit about a target, or a
/// fixed eye. Every driving preset resolves to one of these; the renderer
/// converts it to its own camera.
public struct SceneCamera: Sendable {
    public var target: SIMD3<Float>,distance: Float,yaw: Float,pitch: Float
    public var up=SIMD3<Float>(0,0,1)
    public var fogRange: SIMD2<Float>?
    public var drawsBackground=true
    private var fixedEye: SIMD3<Float>?
    public internal(set) var fieldOfView: Float = .pi/4
    private var clipping: SIMD2<Float>?
    public init(eye: SIMD3<Float>,target: SIMD3<Float>,fieldOfView: Float = 40 * .pi/180,near: Float = 1,far: Float = 600,up: SIMD3<Float> = SIMD3(0,0,1),fogRange: SIMD2<Float>? = nil) {
        self.target=target;distance=simd_length(eye-target);yaw=0;pitch=0
        fixedEye=eye;self.up=up;self.fogRange=fogRange;self.fieldOfView=fieldOfView;clipping=SIMD2(near,far)
    }
    public var eye: SIMD3<Float> { fixedEye ?? (target+distance*SIMD3(cos(yaw)*cos(pitch),sin(yaw)*cos(pitch),sin(pitch))) }
    public func view() -> simd_float4x4 {
        let z=normalize(eye-target),x=normalize(cross(up,z)),y=cross(z,x)
        return simd_float4x4(SIMD4(x.x,y.x,z.x,0),SIMD4(x.y,y.y,z.y,0),SIMD4(x.z,y.z,z.z,0),SIMD4(-dot(x,eye),-dot(y,eye),-dot(z,eye),1))
    }
    public func viewProjection(aspect: Float) -> simd_float4x4 {
        let y: Float=1/tan(fieldOfView/2),near=clipping?.x ?? max(0.01,distance/10_000),far=clipping?.y ?? max(100,distance*10)
        let projection=simd_float4x4(SIMD4(y/aspect,0,0,0),SIMD4(0,y,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,near*far/(near-far),0))
        return projection*view()
    }
    /// Near and far planes. Public so an alternative renderer can build an
    /// equivalent projection; the classic path keeps its own matrix.
    public var clippingRange: SIMD2<Float> { clipping ?? SIMD2(max(0.01,distance/10_000),max(100,distance*10)) }
}

extension SceneCamera {
    /// An orbit framing a bounding box, for inspection.
    public init(framing minimum: SIMD3<Float>, _ maximum: SIMD3<Float>) {
        target = (minimum + maximum) * 0.5
        distance = max(1, simd_length(maximum - minimum) * 1.2)
        yaw = -Float.pi / 3; pitch = 0.45
    }
}
