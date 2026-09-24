// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSRaceEngine
import TORCSSimulation
import TORCSTelemetry
@testable import TORCSMetal

final class TVDirectorTests: XCTestCase {
    private func reference(_ count: Int,_ settings: TVDirector.Settings) throws -> UnsafeMutableRawPointer {
        try XCTUnwrap(ref_tv_create(Int32(count),[settings.changeInterval,settings.eventInterval,settings.proximity],1000,10))
    }
    @discardableResult private func compare(_ native: inout TVDirector,_ oracle: UnsafeMutableRawPointer,time: Double,cars: [TVDirector.Car],initial: Int?,screens: [Int]=[],file: StaticString=#filePath,line: UInt=#line) throws -> TVDirector.Selection {
        let input=cars.map { RefTVCar(index:Int32($0.index),flags:$0.flags,remainingLaps:Int32($0.remainingLaps),distanceFromStart:$0.distanceFromStart,toMiddle:$0.toMiddle,pitRequested:$0.pitRequested ? 1:0,collision:$0.collision ? 1:0) }
        var state=Array(repeating:Double(0),count:2+cars.count*2),selection=Array(repeating:Int32(0),count:3),collisions=Array(repeating:Int32(0),count:cars.count)
        var view=Array(repeating:Float(0),count:17)
        ref_tv_step(oracle,time,Int32(initial ?? -1),input,screens.map(Int32.init),Int32(screens.count),&state,&selection,&collisions,&view)
        let result=try native.update(time:time,cars:cars,initialCar:initial,trackLength:1000,trackWidth:10,otherScreens:screens)
        XCTAssertEqual(result.carIndex,Int(selection[0]),file:file,line:line);XCTAssertEqual(result.raceSlot,Int(selection[1]),file:file,line:line)
        XCTAssertEqual(result.clearPresentationCollisions,selection[2] != 0,file:file,line:line)
        XCTAssertEqual(native.lastEventTime,state[0],file:file,line:line);XCTAssertEqual(native.lastViewTime,state[1],file:file,line:line)
        for i in cars.indices {
            XCTAssertEqual(native.schedule[i].priority,state[2+i*2],"priority \(i)",file:file,line:line)
            XCTAssertEqual(native.schedule[i].viewable,state[3+i*2] != 0,file:file,line:line)
            let source=cars.first { $0.index==i }!
            XCTAssertEqual(collisions[i],!result.clearPresentationCollisions && source.collision ? 1:0,file:file,line:line)
        }
        return result
    }
    private func car(_ id: Int,_ distance: Float=0,flags: UInt32=0,laps: Int=1,middle: Float=0,pit: Bool=false,collision: Bool=false) -> TVDirector.Car {
        .init(index:id,flags:flags,remainingLaps:laps,distanceFromStart:distance,toMiddle:middle,pitRequested:pit,collision:collision)
    }
    func testOriginalMultiCarSequentialDirectorState() throws {
        let settings=try [TVDirector.Settings(),.init(changeInterval:3.25,eventInterval:0.125,proximity:31.75),.init(changeInterval:0,eventInterval:0,proximity:0),.init(changeInterval:-1,eventInterval:-0.5,proximity:-1)]
        var total=0,switches=0,unviewable=0,reorders=0
        for count in [1,2,3,8,32] { for config in settings {
            var native=try TVDirector(carCount:count,settings:config)
            let oracle=try reference(count,config);defer { ref_tv_destroy(oracle) }
            var time: Double=0,latched=Array(repeating:false,count:count)
            for step in 0..<1200 {
                if step%97==0 { time -= 4 } else { time += [Double(0),0.016,0.125,1,10.125][step%5] }
                var cars: [TVDirector.Car]=[]
                for rank in 0..<count {
                    let id=(rank*17+step/11)%count
                    if (step+id*19)%23==0 { latched[id]=true }
                    let flags: UInt32=step%71<3 ? 0xff:UInt32([0,0,0,0,0,0,1,2,4,8,16,32,64,128,256,512,1024,0,0][(step/13+id*2)%19])
                    let distance=Float((step*7+id*113)%1050)+Float(id%3)*0.125
                    let middle: Float=[-5,-Float(5).nextUp,0,5,Float(5).nextUp,12][(step+id)%6]
                    cars.append(car(id,distance,flags:flags,laps:(step/17+id)%4-1,middle:middle,pit:(step+id)%7==0,collision:latched[id]))
                }
                let screens=(0..<(step%4)).map { (step/3+$0)%count }
                let result=try compare(&native,oracle,time:time,cars:cars,initial:count-1,screens:screens)
                if result.clearPresentationCollisions { switches += 1;latched=Array(repeating:false,count:count) }
                if native.schedule.allSatisfy({ !$0.viewable }) { unviewable += 1 }
                if step>0 && step%11==0 { reorders += 1 }
                total += 1
            }
        } }
        XCTAssertGreaterThan(switches,100);XCTAssertGreaterThan(unviewable,100)
        print("TV_DIRECTOR updates=\(total) carCounts=1,2,3,8,32 settings=4 switches=\(switches) allUnviewable=\(unviewable) reorders=\(reorders) prioritiesClocksSelectionCollisionClear=exact")
    }
    func testOriginalStrictTimingAndEventBoundaries() throws {
        let settings=try TVDirector.Settings()
        var native=try TVDirector(carCount:2,settings:settings)
        let oracle=try reference(2,settings);defer { ref_tv_destroy(oracle) }
        let ordinary=[car(0,100),car(1,500)]
        XCTAssertEqual(try compare(&native,oracle,time:0,cars:ordinary,initial:1).carIndex,1)
        XCTAssertEqual(try compare(&native,oracle,time:10,cars:ordinary,initial:0).carIndex,1)
        XCTAssertEqual(try compare(&native,oracle,time:10.nextUp,cars:ordinary,initial:0).carIndex,0)
        XCTAssertEqual(native.lastViewTime,10.nextUp)
        let time=native.lastEventTime
        _=try compare(&native,oracle,time:time+1,cars:[car(0,100),car(1,900,laps:0,collision:true)],initial:1)
        XCTAssertEqual(native.current,0)
        let changed=try compare(&native,oracle,time:(time+1).nextUp,cars:[car(0,100),car(1,900,laps:0,collision:true)],initial:1)
        XCTAssertEqual(changed.carIndex,1);XCTAssertTrue(changed.clearPresentationCollisions)
        // Reordering changes identity without changing the retained race slot.
        let reordered=try compare(&native,oracle,time:time+1.1,cars:[car(1,900),car(0,100)],initial:1)
        XCTAssertEqual(reordered.carIndex,0);XCTAssertFalse(reordered.clearPresentationCollisions)
        print("TV_DIRECTOR_TIMING strictGreaterThan=1 timersOnlyAdvanceOnSlotSwitch=1 retainsRaceSlotAcrossReorder=1")
    }
    func testOriginalFinishProximityPitAndScreenRules() throws {
        let settings=try TVDirector.Settings()
        let cases: [[TVDirector.Car]]=[
            [car(0,800,laps:0),car(1,400)], [car(0,Float(800).nextUp,laps:0),car(1,400)],
            [car(0,990),car(1,1)], [car(0,100),car(1,110)], [car(0,100),car(1,Float(110).nextDown)],
            [car(0,100),car(1,500,middle:5,pit:true)], [car(0,100),car(1,500,middle:Float(5).nextUp,pit:true)],
            [car(0,100,flags:256),car(1,500,flags:1)], [car(1,100,flags:255),car(0,500,flags:255)],
            [car(0,100),car(1,500,collision:true)], [car(1,100,middle:6),car(0,500)]
        ]
        for cars in cases { for screens in [[],[0],[0,0],[0,1,0]] {
            var native=try TVDirector(carCount:2,settings:settings);let oracle=try reference(2,settings);defer { ref_tv_destroy(oracle) }
            for time: Double in [0,1,1.nextUp,5,10,10.nextUp,20,20,-1,100] { try compare(&native,oracle,time:time,cars:cars,initial:nil,screens:screens) }
        } }
        // No wrapping of proximity across the lap boundary; pit requests only
        // count outside global track width, not local segment width.
        var native=try TVDirector(carCount:2,settings:settings)
        _=try native.update(time:2,cars:cases[2],initialCar:1,trackLength:1000,trackWidth:10)
        XCTAssertEqual(native.schedule.map(\.priority),[2,1]);XCTAssertEqual(native.current,1)
        print("TV_DIRECTOR_RULES sequences=44 updates=440 strictFinishProximityEdges=1 noLapWrap=1 duplicateScreenPenalties=1 allHiddenFallback=1")
    }
    func testSelectedCarProjectionAgainstOriginalDirector() throws {
        let settings=try TVDirector.Settings(changeInterval:0.25,eventInterval:0.125,proximity:25)
        var camera=try TVCamera(carCount:8,settings:settings)
        let world=try CameraWorld(bounds:SIMD3(901.2,702.3,30)),oracle=try reference(8,settings)
        defer { ref_tv_destroy(oracle) }
        var changes=0,previous = -1,maximum: Float=0
        for step in 0..<2400 {
            let subjects=(0..<8).map { rank -> TVCamera.Subject in
                let id=(rank+step/17)%8
                let car=car(id,Float((step*3+id*31)%1000),laps:step%71<7 ? 0:1,middle:Float(id-4)*2,collision:(step+id)%13==0)
                return .init(car:car,position:SIMD3(car.distanceFromStart,car.toMiddle,0),roadCamera:nil)
            }
            let input=subjects.map { RefTVCar(index:Int32($0.car.index),flags:0,remainingLaps:Int32($0.car.remainingLaps),distanceFromStart:$0.car.distanceFromStart,toMiddle:$0.car.toMiddle,pitRequested:0,collision:$0.car.collision ? 1:0) }
            var state=Array(repeating:Double(0),count:18),selection=Array(repeating:Int32(0),count:3),collisions=Array(repeating:Int32(0),count:8),view=Array(repeating:Float(0),count:17)
            ref_tv_step(oracle,Double(step)/60,5,input,[],0,&state,&selection,&collisions,&view)
            let result=try camera.view(time:Double(step)/60,subjects:subjects,initialCar:5,world:world,trackLength:1000,trackWidth:10)
            XCTAssertEqual(result.selection.carIndex,Int(selection[0]));XCTAssertEqual(result.selection.raceSlot,Int(selection[1]))
            maximum=max(maximum,SurveyCameraTests().compare(result.camera,view,.tracksideZoom))
            XCTAssertEqual(result.camera.fieldOfView,view[9] * .pi/180)
            let expected=SceneCamera(eye:SIMD3(view[0],view[1],view[2]),target:SIMD3(view[3],view[4],view[5]),fieldOfView:view[9] * .pi/180,near:view[10],far:view[11])
            for aspect: Float in [1,1.5,2.1] {
                let a=result.camera.viewProjection(aspect:aspect),b=expected.viewProjection(aspect:aspect)
                for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(a[c][r],b[c][r]);maximum=max(maximum,abs(a[c][r]-b[c][r])) } }
            }
            if result.selection.carIndex != previous { changes += 1;previous=result.selection.carIndex }
        }
        XCTAssertGreaterThan(changes,30);XCTAssertEqual(maximum,0)
        // A rejected projection must not commit a car switch or clock update.
        let before=camera.director
        let bad=(0..<8).map { TVCamera.Subject(car:car($0),position:SIMD3(Float.greatestFiniteMagnitude,0,0),roadCamera:nil) }
        XCTAssertThrowsError(try camera.view(time:100,subjects:bad,initialCar:0,world:world,trackLength:1000,trackWidth:10))
        XCTAssertEqual(camera.director.current,before.current);XCTAssertEqual(camera.director.lastEventTime,before.lastEventTime);XCTAssertEqual(camera.director.schedule,before.schedule)
        print("TV_CAMERA updates=2400 selectedCarChanges=\(changes) maximumPoseProjectionError=\(maximum) projectionAspects=3 failedProjectionRollback=1")
    }
    func testSelectedRoadsideLocationsAndVariableZoom() throws {
        let settings=try TVDirector.Settings(changeInterval:0,eventInterval:0,proximity:10)
        var camera=try TVCamera(carCount:3,settings:settings)
        let bounds=SIMD3<Float>(901.2,702.3,30),world=try CameraWorld(bounds:bounds)
        for step in 0..<600 {
            let subjects=(0..<3).map { id -> TVCamera.Subject in
                let sample=car(id,Float(id*100),collision:id==step%3)
                let position=SIMD3(Float(100+step+id*200),Float(60+id*10),Float(step%30))
                let roadside=step<300 ? SIMD3(Float(id*35),Float(id*20),Float(5+id)):SIMD3(25,35,10)
                return .init(car:sample,position:position,roadCamera:roadside)
            }
            let zoom: Float=step<300 ? 9:[1.5,9,30,90,200][step%5]
            let result=try camera.view(time:Double(step+1),subjects:subjects,initialCar:2,world:world,trackLength:1000,trackWidth:10,zoom:zoom)
            let chosen=subjects[result.selection.raceSlot],p=chosen.position,eye=chosen.roadCamera!
            var original=Array(repeating:Float(0),count:step<300 ? 17:23)
            if step<300 { ref_camera_trackside([bounds.x,bounds.y,bounds.z],[p.x,p.y,p.z],[eye.x,eye.y,eye.z],1,&original) }
            else { ref_camera_zoom(7,0,zoom,[-1],[p.x,p.y,p.z],1,&original) }
            XCTAssertEqual(result.camera.eye,eye);XCTAssertEqual(result.camera.target,p)
            XCTAssertEqual(result.camera.fieldOfView,original[9] * .pi/180)
            _=SurveyCameraTests().compare(result.camera,Array(original.prefix(17)),.tracksideZoom)
        }
        print("TV_CAMERA_ROADS updates=600 selectedRoadLocations=3 zoomValues=5 inheritedRoadZoom=exact projectionAspects=3")
    }
    func testCollisionHistoryMatchesLegacyClearsAcrossDisplayCadences() throws {
        var updates=0,clears=0
        for stride in [1,4,8,17] {
            let settings=try TVDirector.Settings(changeInterval:0.5,eventInterval:0.01,proximity:10)
            var director=try TVDirector(carCount:3,settings:settings)
            let oracle=try reference(3,settings);defer { ref_tv_destroy(oracle) }
            var history=Array(repeating:PresentationCollisionHistory(),count:3)
            var authoritative=Array(repeating:UInt32(0),count:3),legacy=authoritative,acknowledged=Array(repeating:-1,count:3)
            for tick in 0..<3000 {
                var flags=Array(repeating:UInt32(0),count:3)
                for id in 0..<3 {
                    flags[id]=(tick+id*19)%201<3 ? 1:0
                    let reset=(tick+id*19)%201==0
                    let collision: UInt32=(tick+id*7)%29==0 ? 2:0
                    if reset { authoritative[id]=0;legacy[id]=0 }
                    if flags[id] & 0xff == 0 { authoritative[id] |= collision;legacy[id] |= collision }
                    try history[id].observe(tick:tick,flags:flags[id],accumulatedCollision:authoritative[id],stepCollision:collision)
                    XCTAssertEqual(history[id].pending(clearedThrough:acknowledged[id]),legacy[id] != 0)
                }
                if tick%stride==0 {
                    let cars=(0..<3).map { rank -> TVDirector.Car in
                        let id=(rank+tick/37)%3
                        return car(id,Float(id*200+100),flags:flags[id],collision:history[id].pending(clearedThrough:acknowledged[id]))
                    }
                    let untouched=authoritative
                    let result=try compare(&director,oracle,time:Double(tick)*0.002,cars:cars,initial:2)
                    if result.clearPresentationCollisions {
                        for id in 0..<3 { acknowledged[id]=history[id].observedTick;legacy[id]=0 }
                        clears += 1
                    }
                    XCTAssertEqual(authoritative,untouched);updates += 1
                }
            }
        }
        var history=PresentationCollisionHistory()
        try history.observe(tick:0,flags:1,accumulatedCollision:4,stepCollision:0)
        XCTAssertTrue(history.pending(clearedThrough:-1))
        let before=history
        XCTAssertThrowsError(try history.observe(tick:0,flags:0,accumulatedCollision:0,stepCollision:0))
        XCTAssertThrowsError(try history.observe(tick:-1,flags:0,accumulatedCollision:0,stepCollision:0))
        XCTAssertEqual(history,before)
        try history.observe(tick:1,flags:1,accumulatedCollision:4,stepCollision:4)
        XCTAssertFalse(history.pending(clearedThrough:0)) // Inactive stale publication cannot create a new event.
        print("TV_COLLISION_HISTORY physicsPublications=36000 displayUpdates=\(updates) clears=\(clears) displayCadences=4 legacyLatch=exact sourceFlagsUnchanged=1 staleInactiveSuppressed=1 invalidTickRollback=1")
    }
    func testCollisionClearsAreSharedAcrossTVScreens() throws {
        let settings=try TVDirector.Settings(changeInterval:0.2,eventInterval:0.01,proximity:10)
        var cameras=try [TVDirector(carCount:4,settings:settings),TVDirector(carCount:4,settings:settings)]
        let oracles=try [reference(4,settings),reference(4,settings)];defer { for p in oracles { ref_tv_destroy(p) } }
        var histories=Array(repeating:PresentationCollisionHistory(),count:4)
        var accumulated=Array(repeating:UInt32(0),count:4),legacy=accumulated,acknowledged=Array(repeating:-1,count:4)
        var selected=[0,1],clears=0,secondScreenClears=0
        for tick in 0..<2000 {
            for id in 0..<4 {
                let collision: UInt32=(tick+id*7)%31==0 ? 2:0
                accumulated[id] |= collision;legacy[id] |= collision
                try histories[id].observe(tick:tick,flags:0,accumulatedCollision:accumulated[id],stepCollision:collision)
            }
            if tick%5==0 { for screen in 0..<2 {
                let cars=(0..<4).map { rank -> TVDirector.Car in
                    let id=(rank+tick/37)%4
                    XCTAssertEqual(histories[id].pending(clearedThrough:acknowledged[id]),legacy[id] != 0)
                    return car(id,Float(id*100),collision:histories[id].pending(clearedThrough:acknowledged[id]))
                }
                let view=try compare(&cameras[screen],oracles[screen],time:Double(tick)*0.002,cars:cars,initial:screen,screens:[selected[1-screen]])
                selected[screen]=view.carIndex
                if view.clearPresentationCollisions {
                    for id in 0..<4 { acknowledged[id]=histories[id].observedTick;legacy[id]=0 }
                    clears += 1;if screen==1 { secondScreenClears += 1 }
                }
            } }
        }
        XCTAssertGreaterThan(clears,20);XCTAssertGreaterThan(secondScreenClears,0)
        print("TV_SHARED_SCREENS screens=2 physicsPublications=8000 directorUpdates=800 clears=\(clears) secondScreenClears=\(secondScreenClears) sharedAcknowledgements=exact")
    }
    func testDirectorAndCollisionObservationDoNotChangeNativePhysics() throws {
        let (content,definition)=try VehiclePresentationTests().setup();defer { withExtendedLifetime(content) {} }
        var observed=try SingleVehicleSimulation(definition:definition,road:ChassisTestContext.road())
        try observed.settle()
        var baseline=observed,history=PresentationCollisionHistory(),camera=try TVCamera(carCount:1,settings:TVDirector.Settings())
        let road=observed.road,world=try CameraWorld(bounds:road.bounds)
        var clearTick = -1,views=0,events=0
        func observe() throws {
            let life=observed.lifecycle
            try history.observe(tick:observed.tick,flags:life.flags,accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
        }
        try observe()
        for tick in 1...4000 {
            let command=DriverCommand(throttle:0.6,steering:0.04*sin(Float(tick)*0.0012),gear:1)
            try baseline.step(command:command);try observed.step(command:command);try observe()
            if tick%8==0 {
                let life=observed.lifecycle,p=life.trackPosition
                let pending=history.pending(clearedThrough:clearTick)
                if pending { events += 1 }
                let sample=car(0,road.geometry.distanceFromStart(p),flags:life.flags,laps:1,middle:p.toMiddle,collision:pending)
                let view=try camera.view(time:Double(tick)*0.002,subjects:[.init(car:sample,position:observed.visualSnapshot.body.position,roadCamera:road.camera(at:p.segment)?.position)],initialCar:0,world:world,trackLength:road.length,trackWidth:road.geometry.segments[0].width)
                XCTAssertEqual(view.selection.carIndex,0)
                // A presentation-only acknowledgement, as a manual screen change
                // would perform. It must never clear lifecycle/physics flags.
                if views%47==0 { clearTick=history.observedTick }
                views += 1
            }
            XCTAssertEqual(VehicleTelemetry.values(observed.vehicle,track:road.geometry),VehicleTelemetry.values(baseline.vehicle,track:road.geometry))
            XCTAssertEqual(observed.lifecycle.publishedCollision,baseline.lifecycle.publishedCollision)
            XCTAssertEqual(observed.lifecycle.publishedSimCollision,baseline.lifecycle.publishedSimCollision)
            XCTAssertEqual(observed.random.state,baseline.random.state);XCTAssertEqual(observed.random.draws,baseline.random.draws)
        }
        XCTAssertGreaterThan(events,0)
        print("TV_NATIVE_ISOLATION physicsTicks=4000 cameraViews=\(views) collisionViews=\(events) telemetryFields=142 randomAndPublishedCollisionUnchanged=1")
    }
    func testInvalidFramesLeaveDirectorUnchanged() throws {
        for value: Float in [.nan,.infinity,-.infinity] {
            XCTAssertThrowsError(try TVDirector.Settings(changeInterval:value));XCTAssertThrowsError(try TVDirector.Settings(eventInterval:value));XCTAssertThrowsError(try TVDirector.Settings(proximity:value))
        }
        let settings=try TVDirector.Settings()
        XCTAssertThrowsError(try TVDirector(carCount:0,settings:settings));XCTAssertThrowsError(try TVDirector(carCount:1025,settings:settings))
        var native=try TVDirector(carCount:2,settings:settings)
        let cars=[car(0),car(1,50)]
        _=try native.update(time:11,cars:cars,initialCar:1,trackLength:1000,trackWidth:10)
        let state=native
        for bad in [[car(0),car(0)],[car(-1),car(1)],[],[car(0,.nan),car(1)],[car(0,middle:.infinity),car(1)]] {
            XCTAssertThrowsError(try native.update(time:12,cars:bad,initialCar:0,trackLength:1000,trackWidth:10))
        }
        for screens in [[2],[-1],[0,0,0,0]] { XCTAssertThrowsError(try native.update(time:12,cars:cars,initialCar:0,trackLength:1000,trackWidth:10,otherScreens:screens)) }
        XCTAssertThrowsError(try native.update(time:.nan,cars:cars,initialCar:0,trackLength:1000,trackWidth:10))
        XCTAssertThrowsError(try native.update(time:12,cars:cars,initialCar:0,trackLength:0,trackWidth:10))
        XCTAssertThrowsError(try native.update(time:12,cars:cars,initialCar:0,trackLength:1000,trackWidth:-1))
        XCTAssertEqual(native.current,state.current);XCTAssertEqual(native.schedule,state.schedule);XCTAssertEqual(native.lastEventTime,state.lastEventTime);XCTAssertEqual(native.lastViewTime,state.lastViewTime)
        print("TV_DIRECTOR_VALIDATION boundedDenseIDs=1 malformedFrameRollback=1 simulationNeverMutated=1")
    }
}
