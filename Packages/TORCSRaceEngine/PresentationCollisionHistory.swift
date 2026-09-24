// SPDX-License-Identifier: GPL-2.0-only
// Separates TORCS simuv2's published collision accumulation from grcam/grscreen's
// presentation acknowledgements. Original code Copyright (C) Eric Espie and
// Bernhard Wymann, GPL-2.0-or-later; native immutable publication is GPL-2.0-only.
import TORCSAssets

/// Observe every simulation publication on the simulation owner, then copy into
/// immutable render snapshots. The presentation owner shares clear cursors across
/// its screens, matching original screen-to-screen acknowledgements.
/// This preserves collisions between display frames without clearing physics.
public struct PresentationCollisionHistory: Sendable,Equatable {
    public private(set) var observedTick = -1,lastCollisionTick = -1,lastResetTick = -1
    public init() {}
    public mutating func observe(tick: Int,flags: UInt32,accumulatedCollision: UInt32,stepCollision: UInt32) throws {
        guard tick>=0,tick>observedTick else { throw ACError.invalid("Collision history requires increasing simulation ticks") }
        if accumulatedCollision==0 { lastResetTick=tick }
        else if observedTick<0 || (flags & 0xff == 0 && stepCollision != 0) { lastCollisionTick=tick }
        observedTick=tick
    }
    /// Set the shared presentation clearedThrough cursor to observedTick when the original
    /// screen/director would clear that car's published collision flag.
    public func pending(clearedThrough: Int) -> Bool { lastCollisionTick>max(lastResetTick,clearedThrough) }
}
