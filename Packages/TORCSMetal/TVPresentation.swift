// SPDX-License-Identifier: GPL-2.0-only
// Original grscreen/grcam screen order and collision acknowledgement semantics.
// Copyright (C) 2000-2013 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import TORCSAssets
import TORCSRaceEngine
import TORCSTrack

/// One presentation owner for up to four screens. Reads immutable race frames;
/// shared clear cursors never write simulation flags. Cameras retain their state
/// while another preset is selected. A new race requires a new owner.
public struct TVPresentation: Sendable {
    private struct Screen: Sendable { var active=false,car=0 }
    private var screens=Array(repeating:Screen(),count:4)
    private(set) var cameras: [TVCamera]
    private(set) var clearedThrough: [Int]
    private(set) var lastFrameTick = -1
    public init(carCount: Int,settings: TVDirector.Settings) throws {
        cameras=try (0..<4).map { _ in try TVCamera(carCount:carCount,settings:settings) }
        clearedThrough=Array(repeating:-1,count:carCount)
    }
    public mutating func activate(screen: Int,car: Int) throws {
        try validateScreen(screen)
        guard clearedThrough.indices.contains(car) else { throw ACError.invalid("Invalid initial TV screen car") }
        screens[screen].active=true;screens[screen].car=car
    }
    public mutating func setActive(_ active: Bool,screen: Int) throws { try validateScreen(screen);screens[screen].active=active }
    public func selectedCar(screen: Int) -> Int? { screens.indices.contains(screen) ? screens[screen].car:nil }
    /// Original manual car changes acknowledge only that car, without resetting
    /// an already initialized TV director's retained race slot.
    public mutating func selectCar(_ car: Int,screen: Int,frame: [RacePresentationCar]) throws {
        try validateScreen(screen);let tick=try validate(frame)
        guard let subject=frame.first(where: { $0.index==car }) else { throw ACError.invalid("Unknown presentation car") }
        screens[screen].car=car;clearedThrough[car]=subject.collisions.observedTick;lastFrameTick=tick
    }
    public mutating func view(screen: Int,time: Double,frame: [RacePresentationCar],road: TrackRoad,world: CameraWorld,zoom: Float=9) throws -> TVCamera.View {
        try validateScreen(screen)
        guard screens[screen].active else { throw ACError.invalid("Inactive TV screen") }
        let tick=try validate(frame)
        let subjects=try frame.map { car -> TVCamera.Subject in
            let p=car.trackPosition
            guard road.geometry.segments.indices.contains(p.segment),p.toStart.isFinite,p.toMiddle.isFinite else { throw ACError.invalid("Invalid TV track position") }
            let sample=TVDirector.Car(index:car.index,flags:car.visual.flags,remainingLaps:car.remainingLaps,distanceFromStart:road.geometry.distanceFromStart(p),toMiddle:p.toMiddle,pitRequested:car.pitRequested,collision:car.collisions.pending(clearedThrough:clearedThrough[car.index]))
            return TVCamera.Subject(car:sample,position:car.visual.body.position,roadCamera:road.camera(at:p.segment)?.position)
        }
        let other=screens.indices.filter { $0 != screen && screens[$0].active }.map { screens[$0].car }
        var camera=cameras[screen]
        let result=try camera.view(time:time,subjects:subjects,initialCar:screens[screen].car,world:world,trackLength:road.length,trackWidth:road.width,otherScreens:other,zoom:zoom)
        // No throwing operations after commit begins.
        cameras[screen]=camera;screens[screen].car=result.selection.carIndex;lastFrameTick=tick
        if result.selection.clearPresentationCollisions { for car in frame { clearedThrough[car.index]=car.collisions.observedTick } }
        return result
    }
    private func validateScreen(_ screen: Int) throws {
        guard screens.indices.contains(screen) else { throw ACError.invalid("TV screen index outside original four-screen limit") }
    }
    private func validate(_ frame: [RacePresentationCar]) throws -> Int {
        guard frame.count==clearedThrough.count,let tick=frame.first?.visual.tick,tick>=0,tick>=lastFrameTick,
              frame.allSatisfy({ clearedThrough.indices.contains($0.index) && $0.visual.tick==tick && $0.collisions.observedTick==tick }),
              Set(frame.map(\.index)).count==frame.count else { throw ACError.invalid("Incomplete, mixed or stale TV presentation frame") }
        return tick
    }
}
