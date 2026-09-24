// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of cGrCarCamRoadZoomTVD/cGrCarCamRoadZoom, TORCS 1.3.9.
// Copyright (C) 2000 Eric Espie; original GPL-2.0-or-later attribution retained.
import simd
import TORCSAssets

/// Original director plus its selected car's F9-style roadside projection.
/// The application must supply presentation collision latches, not mutate physics
/// when Selection requests that those latches be cleared.
public struct TVCamera: Sendable {
    public struct Subject: Sendable {
        public let car: TVDirector.Car,position: SIMD3<Float>,roadCamera: SIMD3<Float>?
        public init(car: TVDirector.Car,position: SIMD3<Float>,roadCamera: SIMD3<Float>?) {
            self.car=car;self.position=position;self.roadCamera=roadCamera
        }
    }
    public struct View: Sendable {
        public let selection: TVDirector.Selection,camera: SceneCamera
    }
    private(set) var director: TVDirector
    public init(carCount: Int,settings: TVDirector.Settings) throws { director=try TVDirector(carCount:carCount,settings:settings) }
    public mutating func view(time: Double,subjects: [Subject],initialCar: Int?,world: CameraWorld,trackLength: Float,trackWidth: Float,otherScreens: [Int]=[],zoom: Float=9) throws -> View {
        func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
        guard zoom.isFinite,zoom>0,subjects.allSatisfy({ finite($0.position) && ($0.roadCamera.map(finite) ?? true) }) else { throw ACError.invalid("Invalid TV camera placement or zoom") }
        var next=director
        let selection=try next.update(time:time,cars:subjects.map(\.car),initialCar:initialCar,trackLength:trackLength,trackWidth:trackWidth,otherScreens:otherScreens)
        let subject=subjects[selection.raceSlot]
        let camera=world.tracksideCamera(zoomed:true,position:subject.roadCamera,carPosition:subject.position,zoomValue:zoom)
        let matrix=camera.viewProjection(aspect:1)
        guard camera.fieldOfView.isFinite,camera.fieldOfView>0,(1/tan(camera.fieldOfView/2)).isFinite,
              (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }) else { throw ACError.invalid("TV camera projection overflow") }
        director=next;return View(selection:selection,camera:camera)
    }
}
