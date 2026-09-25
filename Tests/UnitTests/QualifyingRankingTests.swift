// SPDX-License-Identifier: GPL-2.0-only
// The native qualifying ranking compared against the verbatim original excerpt,
// and the starting order the original selects for a race.
import XCTest
import TORCSRaceEngine
import TORCSTrack
import CReference
import TORCSReferenceSupport

final class QualifyingRankingTests: XCTestCase {
    private func compare(_ runs: [(name: String,bestLapTime: Float,index: Int)],
                         fixtures: URL,label: String) throws -> [QualifyingRun] {
        let original=try ReferenceQualifying.rank(runs,fixtures:fixtures)
        let native=QualifyingRanking.rank(runs.map { QualifyingRun(name:$0.name,bestLapTime:$0.bestLapTime,index:$0.index) })
        XCTAssertEqual(native.count,original.count,"\(label) ranked count")
        for (slot,entry) in native.enumerated() {
            XCTAssertEqual(entry.name,original[slot].name,"\(label) name at \(slot+1)")
            XCTAssertEqual(entry.bestLapTime,original[slot].bestLapTime,"\(label) time at \(slot+1)")
            XCTAssertEqual(entry.index,original[slot].index,"\(label) index at \(slot+1)")
        }
        return native
    }
    func testQualifyingRankingMatchesOriginal() throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let content=try ReferenceContent(fixtures:fixtures)
        defer { withExtendedLifetime(content) {} }
        var cases=0
        // Ordinary ordering, arriving fastest first and fastest last.
        _=try compare([("a",90.5,0),("b",89.25,1),("c",91,2)],fixtures:content.directory,label:"mixed")
        _=try compare([("a",88,0),("b",89,1),("c",90,2)],fixtures:content.directory,label:"descending")
        _=try compare([("a",92,0),("b",91,1),("c",90,2)],fixtures:content.directory,label:"ascending")
        cases += 3
        // A driver who set no time is worse than any time, whenever it arrives.
        let none=try compare([("a",90,0),("b",0,1),("c",89,2)],fixtures:content.directory,label:"no time")
        XCTAssertEqual(none.last?.name,"b","a driver without a time ranks last")
        _=try compare([("a",0,0),("b",90,1)],fixtures:content.directory,label:"no time first")
        _=try compare([("a",0,0),("b",0,1)],fixtures:content.directory,label:"no times at all")
        cases += 3
        // Equal times keep the earlier qualifier ahead, and the original compares
        // at millisecond resolution, so a sub-millisecond difference is a tie.
        let tie=try compare([("a",90.0,0),("b",90.0,1)],fixtures:content.directory,label:"tie")
        XCTAssertEqual(tie.map(\.name),["a","b"],"an equal time keeps the earlier qualifier ahead")
        _=try compare([("a",90.0004,0),("b",90.0,1)],fixtures:content.directory,label:"sub-millisecond")
        _=try compare([("a",90.001,0),("b",90.0,1)],fixtures:content.directory,label:"one millisecond")
        cases += 3
        // A longer field, inserted in an arbitrary order.
        _=try compare([("a",95.5,0),("b",88.125,1),("c",91.75,2),("d",0,3),("e",88.124,4),("f",92,5)],
                      fixtures:content.directory,label:"field")
        cases += 1
        print("NATIVE_QUALIFYING_RANK cases=\(cases) matched=1")
    }
    func testStoredTimesAreRoundedToMilliseconds() throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let content=try ReferenceContent(fixtures:fixtures)
        defer { withExtendedLifetime(content) {} }
        // The original stores round(best*1000)/1000, so a ranked time is not the
        // raw lap time it was given.
        let ranked=try compare([("a",90.00049,0),("b",91.00051,1)],fixtures:content.directory,label:"rounding")
        XCTAssertEqual(ranked[0].bestLapTime,90.0,accuracy:1e-6)
        XCTAssertEqual(ranked[1].bestLapTime,91.001,accuracy:1e-6)
        print("NATIVE_QUALIFYING_ROUNDING stored=\(ranked.map(\.bestLapTime))")
    }
    func testStartingOrderFollowsTheOriginalAttribute() throws {
        // The original's final branch is an else, so an unknown value is the
        // drivers list.
        XCTAssertEqual(StartingOrder(attribute:"drivers list"), .driversList)
        XCTAssertEqual(StartingOrder(attribute:"last race"), .lastRace)
        XCTAssertEqual(StartingOrder(attribute:"last race reversed"), .lastRaceReversed)
        XCTAssertEqual(StartingOrder(attribute:"something else"), .driversList)
        let previous=[QualifyingRun(name:"c",bestLapTime:88,index:2),
                      QualifyingRun(name:"a",bestLapTime:89,index:0),
                      QualifyingRun(name:"b",bestLapTime:90,index:1)]
        XCTAssertEqual(try StartingOrder.driversList.grid(entries:3,previous:previous),[0,1,2])
        XCTAssertEqual(try StartingOrder.lastRace.grid(entries:3,previous:previous),[2,0,1])
        XCTAssertEqual(try StartingOrder.lastRaceReversed.grid(entries:3,previous:previous),[1,0,2])
        // The original caps the field at the race's maximum driver count.
        XCTAssertEqual(try StartingOrder.driversList.grid(entries:5,previous:[],maximumCars:2),[0,1])
        // A previous session that does not cover the field is reported rather
        // than silently producing a short or duplicated grid.
        XCTAssertThrowsError(try StartingOrder.lastRace.grid(entries:4,previous:previous))
        XCTAssertThrowsError(try StartingOrder.lastRace.grid(entries:3,previous:Array(previous.prefix(2))))
        print("NATIVE_STARTING_ORDER values=\(StartingOrder.allCases.map(\.rawValue))")
    }
}
