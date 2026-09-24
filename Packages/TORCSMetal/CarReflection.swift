// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS grcar/grvtxtable texture transforms.
// Copyright (C) 2000 Eric Espie, 2001 Christophe Guionneau; upstream GPL-2.0-or-later.
import Foundation
import simd
import TORCSAssets
import TORCSTrack

/// Per-car presentation state. Distance is local lap distance, not total mileage.
/// Original UV1 scrolls with distance; UV2 rotates about (0,0), not its center.
public struct CarTrackShadowMapping: Sendable {
    let trackBounds: ACLoaderBounds
    let scale: SIMD2<Float>
    public init(trackBounds: ACLoaderBounds,carBounds: ACLoaderBounds) throws {
        try trackBounds.validate();try carBounds.validate()
        let width=Double(trackBounds.maximumX)-Double(trackBounds.minimumX)
        let height=Double(trackBounds.maximumY)-Double(trackBounds.minimumY)
        guard width>0,height>0 else { throw ACError.invalid("Degenerate track shadow bounds") }
        scale=SIMD2(Float((Double(carBounds.maximumX)-Double(carBounds.minimumX))/width),Float((Double(carBounds.maximumY)-Double(carBounds.minimumY))/height))
        guard scale.x.isFinite,scale.y.isFinite else { throw ACError.invalid("Track shadow scale overflow") }
        self.trackBounds=trackBounds
    }
    func offset(_ position: SIMD2<Float>) throws -> SIMD2<Float> {
        let b=trackBounds
        let value=SIMD2(Float((Double(position.x)-Double(b.minimumX))/(Double(b.maximumX)-Double(b.minimumX))),Float((Double(position.y)-Double(b.minimumY))/(Double(b.maximumY)-Double(b.minimumY))))
        guard value.x.isFinite,value.y.isFinite else { throw ACError.invalid("Invalid track shadow position") }
        return value
    }
}

public struct CarReflection: Sendable {
    let coordinates: SIMD4<Float> // translation, cos(yaw), sin(yaw), enabled
    let shadowLinear,shadowOffset: SIMD4<Float>
    public init(distanceFromStart: Float,yaw: Float,position: SIMD2<Float> = .zero,trackShadow: CarTrackShadowMapping? = nil) throws {
        guard distanceFromStart.isFinite,yaw.isFinite else { throw ACError.invalid("Invalid car reflection state") }
        // Preserve TORCS RAD2DEG's double expression followed by PLIB's float
        // degrees-to-radians and C++ float sin/cos. Do not simplify the round trip.
        let degrees=Float(Double(yaw)*(180/Double.pi))
        let radians=degrees*(Float(Double.pi)/180)
        guard radians.isFinite else { throw ACError.invalid("Reflection angle overflow") }
        let c=cos(radians),s=sin(radians)
        coordinates=SIMD4(distanceFromStart/50,c,s,1)
        if let trackShadow {
            let scale=trackShadow.scale,offset=try trackShadow.offset(position)
            // Original texture matrix T * R * S, not S * R * T.
            shadowLinear=SIMD4(c*scale.x,s*scale.x,-s*scale.y,c*scale.y)
            shadowOffset=SIMD4(offset.x,offset.y,0,1)
        } else { shadowLinear = .zero;shadowOffset = .zero }
    }
    public init(body: simd_float4x4,yaw: Float,track: TrackGeometry,startingAt segment: Int,trackShadow: CarTrackShadowMapping? = nil) throws {
        let p=body[3],local=try track.globalToLocal(SIMD2(p.x,p.y),startingAt:segment)
        try self.init(distanceFromStart:track.distanceFromStart(local),yaw:yaw,position:SIMD2(p.x,p.y),trackShadow:trackShadow)
    }
}
