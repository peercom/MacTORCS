// SPDX-License-Identifier: GPL-2.0-only
// Per-car shadow anchors and visibility follow TORCS 1.3.9 grcar/grscreen.
// Copyright (C) 2000 Eric Espie; upstream GPL-2.0-or-later.
import simd

/// One projected six-vertex strip. Texture resources are loaded separately;
/// updating car positions does not decode images or allocate GPU textures.
public struct SceneShadow: Sendable {
    public let carIndex,resource: Int
    public let vertices: [ShadowVertex]
    public let normal: SIMD3<Float>
    public init(carIndex: Int,resource: Int,vertices: [ShadowVertex],normal: SIMD3<Float> = SIMD3(0,0,1)) {
        self.carIndex=carIndex;self.resource=resource;self.vertices=vertices;self.normal=normal
    }
}

/// Original grDrawCar hides only the current car's shadow when the view's
/// draw-current flag is false. Other cars remain visible, including in mirrors.
public struct ShadowView: Sendable {
    public let currentCar: Int?
    public let drawsCurrentCar: Bool
    public init(currentCar: Int? = nil,drawsCurrentCar: Bool=true) {
        self.currentCar=currentCar;self.drawsCurrentCar=drawsCurrentCar
    }
    public func isVisible(carIndex: Int) -> Bool { carIndex != currentCar || drawsCurrentCar }
}
