// SPDX-License-Identifier: GPL-2.0-only
// A season's table, its tie-breaks, the reversed grid and what is kept
// between launches; and the player's lap records.
import XCTest
import TORCSRaceEngine

final class ChampionshipTests: XCTestCase {
    private func season(_ cars: Int = 4,rounds: Int = 3) throws -> Championship {
        try Championship(entrants:(0..<cars).map { .init(name:$0==0 ? "You":"Driver \($0)",car:"car\($0%2)") },
                         tracks:(0..<rounds).map { "track\($0)" },laps:5)
    }
    func testPointsTieBreaksAndTheReversedGrid() throws {
        var c=try season()
        XCTAssertEqual(c.nextRound,0);XCTAssertFalse(c.isComplete);XCTAssertNil(c.champion)
        // Before any race the table is the entry list, so the player starts last.
        XCTAssertEqual(c.standings.map(\.entrant),[0,1,2,3]);XCTAssertEqual(c.grid,[3,2,1,0])
        try c.record(round:0,classification:[2,0,1,3])
        XCTAssertEqual(c.standings.map(\.entrant),[2,0,1,3]);XCTAssertEqual(c.standings.map(\.points),[10,8,6,5])
        XCTAssertEqual(c.grid,[3,1,0,2],"the leader starts last")
        XCTAssertEqual(c.position(of:0),2)
        // 0 wins the second: 18 points each with 2, one win each; the better
        // best finish is equal too, so entry order settles it.
        try c.record(round:1,classification:[0,2,3,1])
        XCTAssertEqual(c.standings.prefix(2).map(\.points),[18,18]);XCTAssertEqual(c.standings.prefix(2).map(\.entrant),[0,2])
        XCTAssertEqual(c.standings.map(\.wins),[1,1,0,0])
        // Out of turn, or not a classification of the field: refused, nothing changes.
        let before=c
        XCTAssertThrowsError(try c.record(round:0,classification:[0,1,2,3]))
        XCTAssertThrowsError(try c.record(round:2,classification:[0,1,2]))
        XCTAssertThrowsError(try c.record(round:2,classification:[0,0,2,3]))
        XCTAssertEqual(c,before)
        try c.record(round:2,classification:[1,2,0,3])
        XCTAssertTrue(c.isComplete);XCTAssertNil(c.nextRound);XCTAssertEqual(c.roundsRun,3)
        // 2: 10+8+8=26, 0: 8+10+6=24, 1: 6+5+10=21, 3: 5+6+5=16.
        XCTAssertEqual(c.standings.map(\.points),[26,24,21,16]);XCTAssertEqual(c.champion,2)
        XCTAssertEqual(c.standings.first { $0.entrant==1 }?.bestFinish,1)
        print("CHAMPIONSHIP rounds=3 table=\(c.standings.map { "\($0.entrant):\($0.points)" })")
    }
    func testOnlyTheFirstEightScoreAndInvalidSeasonsAreRefused() throws {
        var c=try season(10,rounds:1)
        try c.record(round:0,classification:Array((0..<10).reversed()))
        XCTAssertEqual(c.standings.map(\.points),[10,8,6,5,4,3,2,1,0,0])
        XCTAssertEqual(c.standings.suffix(2).map(\.entrant),[1,0],"ninth and tenth score nothing; the better finish is ahead")
        XCTAssertThrowsError(try season(1));XCTAssertThrowsError(try season(17));XCTAssertThrowsError(try season(4,rounds:0))
        XCTAssertThrowsError(try Championship(entrants:[.init(name:"a",car:"x"),.init(name:"b",car:"x")],tracks:["t"],laps:0))
    }
    func testSeasonAndRecordsSurviveALaunch() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=try ChampionshipStore(directory:folder)
        XCTAssertNil(try store.load())
        var c=try season()
        try c.record(round:0,classification:[1,0,3,2])
        try store.save(c);XCTAssertEqual(try store.load(),c)
        try store.clear();XCTAssertNil(try store.load());try store.clear()
        // A file that claims a classification the field cannot have is refused.
        try Data(#"{"entrants":[{"name":"a","car":"x"},{"name":"b","car":"x"}],"laps":3,"rounds":[{"track":"t","classification":[0,0]}]}"#.utf8)
            .write(to:folder.appendingPathComponent("championship.json"))
        XCTAssertThrowsError(try store.load())

        var records=LapRecords()
        let day=Date(timeIntervalSince1970:1_800_000_000)
        XCTAssertTrue(records.submit(track:"aalborg",car:"155-DTM",time:91.5,date:day))
        XCTAssertFalse(records.submit(track:"aalborg",car:"155-DTM",time:92,date:day),"slower")
        XCTAssertTrue(records.submit(track:"aalborg",car:"155-DTM",time:90.25,date:day))
        XCTAssertTrue(records.submit(track:"aalborg",car:"p406",time:99,date:day))
        XCTAssertFalse(records.submit(track:"aalborg",car:"p406",time:0,date:day));XCTAssertFalse(records.submit(track:"",car:"p406",time:50,date:day))
        XCTAssertFalse(records.submit(track:"aalborg",car:"p406",time:.nan,date:day))
        XCTAssertEqual(records.best(track:"aalborg",car:"155-DTM")?.time,90.25)
        XCTAssertEqual(records.best(track:"aalborg",car:nil)?.car,"155-DTM","the fastest car's lap is the circuit's best")
        XCTAssertNil(records.best(track:"forza",car:nil));XCTAssertEqual(records.records.count,2)
        let recordStore=try LapRecordsStore(directory:folder)
        try recordStore.save(records);XCTAssertEqual(try recordStore.load(),records)
    }
}
