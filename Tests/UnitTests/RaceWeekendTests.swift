// SPDX-License-Identifier: GPL-2.0-only
// The session sequence: one qualifying session per driver, then a grid built
// from the starting order the original selects.
import XCTest
import TORCSRaceEngine
import TORCSTrack

final class RaceWeekendTests: XCTestCase {
    func testQualifyingRunsOneDriverAtATime() throws {
        var weekend=try RaceWeekend(cars:4,startingOrder: .lastRace)
        XCTAssertEqual(weekend.qualifying,0,"the first driver qualifies first")
        XCTAssertFalse(weekend.qualifyingComplete)
        // A grid cannot be built before every driver has run.
        XCTAssertThrowsError(try weekend.grid())
        // Out-of-turn recording is refused rather than silently reordered.
        XCTAssertThrowsError(try weekend.recordQualifying(car:2,bestLapTime:88))
        let times: [Float]=[90.5,88.25,0,89]
        for car in 0..<4 {
            XCTAssertEqual(weekend.qualifying,car)
            try weekend.recordQualifying(car:car,bestLapTime:times[car])
        }
        XCTAssertTrue(weekend.qualifyingComplete)
        XCTAssertNil(weekend.qualifying)
        XCTAssertThrowsError(try weekend.recordQualifying(car:0,bestLapTime:87),"qualifying is over")
        // Fastest first; the driver who set no time is last.
        XCTAssertEqual(weekend.ranking.map(\.index),[1,3,0,2])
        XCTAssertEqual(weekend.ranking.last?.bestLapTime,0)
        XCTAssertEqual(try weekend.grid(),[1,3,0,2],"the grid follows the ranking")
        print("NATIVE_WEEKEND cars=4 ranking=\(weekend.ranking.map(\.index)) grid=\(try weekend.grid())")
    }
    func testDriversListNeedsNoQualifying() throws {
        let weekend=try RaceWeekend(cars:3)
        XCTAssertTrue(weekend.qualifyingComplete,"the drivers list order needs no qualifying")
        XCTAssertEqual(try weekend.grid(),[0,1,2])
        print("NATIVE_WEEKEND_LIST grid=\(try weekend.grid())")
    }
    func testReversedOrderPutsTheFastestLast() throws {
        var weekend=try RaceWeekend(cars:3,startingOrder: .lastRaceReversed)
        for (car,time) in [(0,Float(91)),(1,89),(2,90)] { try weekend.recordQualifying(car:car,bestLapTime:time) }
        XCTAssertEqual(weekend.ranking.map(\.index),[1,2,0])
        XCTAssertEqual(try weekend.grid(),[0,2,1],"the fastest qualifier starts last")
        print("NATIVE_WEEKEND_REVERSED grid=\(try weekend.grid())")
    }
    func testWeekendRejectsInvalidInput() throws {
        XCTAssertThrowsError(try RaceWeekend(cars:0))
        XCTAssertThrowsError(try RaceWeekend(cars:17))
        var weekend=try RaceWeekend(cars:2,startingOrder: .lastRace)
        XCTAssertThrowsError(try weekend.recordQualifying(car:0,bestLapTime:.nan))
        XCTAssertThrowsError(try weekend.recordQualifying(car:0,bestLapTime:-1))
        print("NATIVE_WEEKEND_BOUNDARIES rejected=4")
    }
}
