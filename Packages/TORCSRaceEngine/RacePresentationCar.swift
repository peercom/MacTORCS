// SPDX-License-Identifier: GPL-2.0-only
import TORCSSimulation
import TORCSTrack

/// One published car. Arrays of these records are supplied in race order;
/// presentation never sorts or changes the authoritative standings.
public struct RacePresentationCar: Sendable {
    public let index,remainingLaps: Int
    public let visual: VehicleVisualSnapshot
    public let trackPosition: TrackLocalPosition
    public let pitRequested: Bool
    public let collisions: PresentationCollisionHistory
    public init(index: Int,visual: VehicleVisualSnapshot,trackPosition: TrackLocalPosition,remainingLaps: Int,pitRequested: Bool,collisions: PresentationCollisionHistory) {
        self.index=index;self.visual=visual;self.trackPosition=trackPosition;self.remainingLaps=remainingLaps;self.pitRequested=pitRequested;self.collisions=collisions
    }
}
