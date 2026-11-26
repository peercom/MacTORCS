// SPDX-License-Identifier: GPL-2.0-only
// A season: the same field over a list of circuits, points for the first
// eight home in each race, and a table that decides who starts where next.
import Foundation
import TORCSCore
import TORCSTrack

public struct Championship: Codable,Sendable,Equatable {
    public struct Entrant: Codable,Sendable,Equatable {
        public let name: String
        /// The car's library id.
        public let car: String
        public init(name: String,car: String) { self.name=name;self.car=car }
    }
    public struct Round: Codable,Sendable,Equatable {
        /// The circuit's library id.
        public let track: String
        /// Entrant indices in finishing order, winner first; nil until run.
        public var classification: [Int]?
        public init(track: String,classification: [Int]? = nil) { self.track=track;self.classification=classification }
    }
    public struct Standing: Sendable,Equatable {
        public let entrant,points,wins: Int
        /// The best finishing position so far, 1 for a win; 0 before any race.
        public let bestFinish: Int
    }
    /// Entrant 0 is the player.
    public let entrants: [Entrant]
    public private(set) var rounds: [Round]
    public let laps: Int
    /// Points for first to eighth.
    public static let points=[10,8,6,5,4,3,2,1]
    public init(entrants: [Entrant],tracks: [String],laps: Int) throws {
        guard (2...16).contains(entrants.count) else { throw TrackError.invalid("A championship holds 2…16 entrants") }
        guard !tracks.isEmpty,tracks.count<=64 else { throw TrackError.invalid("A championship holds 1…64 rounds") }
        guard (1...1000).contains(laps) else { throw TrackError.invalid("Championship races run 1…1000 laps") }
        self.entrants=entrants;rounds=tracks.map { Round(track:$0) };self.laps=laps
    }
    /// The round to run next, or nil when the season is over.
    public var nextRound: Int? { rounds.firstIndex { $0.classification==nil } }
    public var isComplete: Bool { nextRound==nil }
    public var roundsRun: Int { rounds.filter { $0.classification != nil }.count }
    /// The table: most points first; then most wins, then the better best
    /// finish, then entry order, so a tie is settled the same way every time.
    public var standings: [Standing] {
        var points=[Int](repeating:0,count:entrants.count),wins=points,best=points
        for round in rounds {
            guard let order=round.classification else { continue }
            for (place,entrant) in order.enumerated() where entrants.indices.contains(entrant) {
                if place<Self.points.count { points[entrant] += Self.points[place] }
                if place==0 { wins[entrant] += 1 }
                if best[entrant]==0 || place+1<best[entrant] { best[entrant]=place+1 }
            }
        }
        return entrants.indices.map { Standing(entrant:$0,points:points[$0],wins:wins[$0],bestFinish:best[$0]) }
            .sorted { a,b in
                if a.points != b.points { return a.points>b.points }
                if a.wins != b.wins { return a.wins>b.wins }
                let x=a.bestFinish==0 ? Int.max:a.bestFinish,y=b.bestFinish==0 ? Int.max:b.bestFinish
                if x != y { return x<y }
                return a.entrant<b.entrant
            }
    }
    public func position(of entrant: Int) -> Int { (standings.firstIndex { $0.entrant==entrant } ?? 0)+1 }
    /// The champion once every round has been run.
    public var champion: Int? { isComplete ? standings.first?.entrant:nil }
    /// The grid for the next race, from pole back: the table reversed, so the
    /// leader starts last. Before any race that puts the player at the back.
    public var grid: [Int] { standings.reversed().map(\.entrant) }
    /// Take a finished race. The classification names every entrant once,
    /// winner first, and belongs to the round that is next.
    public mutating func record(round: Int,classification: [Int]) throws {
        guard round==nextRound else { throw TrackError.invalid("Round \(round+1) is not the next round") }
        guard classification.sorted()==Array(entrants.indices) else { throw TrackError.invalid("A classification names every entrant once") }
        rounds[round].classification=classification
    }
}
public struct ChampionshipStore: Sendable {
    private let store: ConfigurationStore
    private var url: URL { store.directory.appendingPathComponent("championship.json") }
    public init(directory: URL? = nil) throws { store=try ConfigurationStore(directory:directory) }
    /// The season in progress, if there is one.
    public func load() throws -> Championship? {
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let saved=try JSONDecoder().decode(Championship.self,from:Data(contentsOf:url))
        // Rebuilt through the same checks a new season passes.
        var checked=try Championship(entrants:saved.entrants,tracks:saved.rounds.map(\.track),laps:saved.laps)
        for (index,round) in saved.rounds.enumerated() {
            guard let classification=round.classification else { break }
            try checked.record(round:index,classification:classification)
        }
        return checked
    }
    public func save(_ championship: Championship) throws { try store.save(championship,name:"championship.json") }
    public func clear() throws { if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
}
