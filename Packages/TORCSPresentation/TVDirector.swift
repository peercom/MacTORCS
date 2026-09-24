// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of cGrCarCamRoadZoomTVD in TORCS 1.3.9 grcam.cpp.
// Copyright (C) 2000 Eric Espie; original GPL-2.0-or-later attribution retained.
import Foundation
import TORCSAssets

/// Original TV director selection. This is presentation state; it never writes
/// car dynamics or race standings. Supply cars in the current original race order.
public struct TVDirector: Sendable {
    public struct Settings: Sendable,Equatable {
        public let changeInterval,eventInterval,proximity: Float
        public init(changeInterval: Float=10,eventInterval: Float=1,proximity: Float=10) throws {
            guard changeInterval.isFinite,eventInterval.isFinite,proximity.isFinite else { throw ACError.invalid("Nonfinite TV director settings") }
            // Negative finite settings retain original behavior; proximity <= 0
            // disables proximity bonuses without evaluating a division by zero.
            self.changeInterval=changeInterval;self.eventInterval=eventInterval;self.proximity=proximity
        }
    }
    public struct Car: Sendable {
        public let index: Int,flags: UInt32,remainingLaps: Int
        public let distanceFromStart,toMiddle: Float
        public let pitRequested,collision: Bool
        public init(index: Int,flags: UInt32=0,remainingLaps: Int,distanceFromStart: Float,toMiddle: Float,pitRequested: Bool=false,collision: Bool=false) {
            self.index=index;self.flags=flags;self.remainingLaps=remainingLaps;self.distanceFromStart=distanceFromStart;self.toMiddle=toMiddle;self.pitRequested=pitRequested;self.collision=collision
        }
    }
    public struct Selection: Sendable,Equatable {
        public let carIndex,raceSlot: Int
        /// Original clears every car's presentation collision flag only when its
        /// stored race slot changes. Consumers must not clear simulation state.
        public let clearPresentationCollisions: Bool
    }
    struct Schedule: Sendable,Equatable { var priority: Double=0,viewable=false }
    private let settings: Settings
    private(set) var schedule: [Schedule]
    private(set) var current = -1,lastEventTime: Double=0,lastViewTime: Double=0
    public init(carCount: Int,settings: Settings) throws {
        guard (1...1024).contains(carCount) else { throw ACError.invalid("TV director supports 1–1024 cars") }
        self.settings=settings;schedule=Array(repeating:Schedule(),count:carCount)
    }
    /// Other-screen IDs contain only active screens excluding this director's
    /// screen. Duplicate IDs intentionally apply the original repeated penalty.
    /// Initial car affects only the first update; subsequent state is a race slot,
    /// not a stable car identity, including when standings reorder.
    public mutating func update(time: Double,cars: [Car],initialCar: Int?,trackLength: Float,trackWidth: Float,otherScreens: [Int]=[]) throws -> Selection {
        let count=schedule.count
        guard time.isFinite,cars.count==count,trackLength.isFinite,trackLength>0,trackWidth.isFinite,trackWidth>0,
              otherScreens.count<=3,otherScreens.allSatisfy({ (0..<count).contains($0) }),
              cars.allSatisfy({ (0..<count).contains($0.index) && $0.distanceFromStart.isFinite && $0.toMiddle.isFinite }),
              Set(cars.map(\.index)).count==count else { throw ACError.invalid("Invalid TV director frame") }
        // All validation precedes mutation. An absent/unlisted initial car falls
        // back to slot zero, as the original pointer search does.
        if current == -1 { current=cars.firstIndex { $0.index==initialCar } ?? 0 }
        let deltaEvent=time-lastEventTime,deltaView=time-lastViewTime
        var clear=false,event=false
        if deltaEvent>Double(settings.eventInterval) {
            for i in schedule.indices { schedule[i]=Schedule(priority:0,viewable:true) }
            for id in otherScreens { schedule[id].viewable=false;schedule[id].priority -= 10000 }
            for (i,car) in cars.enumerated() {
                let id=car.index,active=car.flags & 0xff == 0
                schedule[id].priority += Double(count-i)
                if !active { schedule[id].viewable=false }
                else if Double(car.distanceFromStart)>Double(trackLength)-200 && car.remainingLaps==0 {
                    schedule[id].priority += Double(5*count);event=true
                }
                if active {
                    let dist=Float(abs(Double(car.toMiddle))-Double(trackWidth)/2)
                    if dist>0 {
                        schedule[id].priority += Double(count)
                        if car.pitRequested { schedule[id].priority += Double(count);event=true }
                    }
                    for j in (i+1)..<count {
                        let other=cars[j]
                        var d=abs(other.distanceFromStart-car.distanceFromStart)
                        if other.flags & 0xff == 0 && d<settings.proximity {
                            d=settings.proximity-d
                            schedule[id].priority += Double(d*Float(count)/settings.proximity)
                            schedule[other.index].priority += Double(d*Float(count-1)/settings.proximity)
                            if i==0 { event=true }
                        }
                    }
                    if car.collision { schedule[id].priority += Double(count);event=true }
                } else if i==current { event=true }
            }
            if event || deltaView>Double(settings.changeInterval) {
                let old=current
                var chosen=0,priority: Double = -1_000_000
                for i in schedule.indices where schedule[i].priority>priority && schedule[i].viewable {
                    priority=schedule[i].priority;chosen=i
                }
                current=cars.firstIndex { $0.index==chosen }! // Dense validated IDs.
                if old != current { lastEventTime=time;lastViewTime=time;clear=true }
            }
        }
        return Selection(carIndex:cars[current].index,raceSlot:current,clearPresentationCollisions:clear)
    }
}
