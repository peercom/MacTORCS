// SPDX-License-Identifier: GPL-2.0-only
// A season: setting one up, and the table between its rounds.
import SwiftUI
import TORCSRaceEngine

struct ChampionshipSetupScreen: View {
    let flow: GameFlow
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeader(title:"New championship",subtitle:flow.plan.car.map { "In the \($0.name)" },crumbs:["Championship","Car","Season"],back:{ flow.back() })
            HStack(alignment:.top,spacing:28) {
                VStack(alignment:.leading,spacing:22) {
                    option("Rounds",detail:"One race on each circuit, from the shortest to the longest.") {
                        HStack(spacing:8) {
                            ForEach([3,5,8,flow.library.tracks.count].filter { $0<=flow.library.tracks.count }.reduce(into:[Int]()) { if !$0.contains($1) { $0.append($1) } },id:\.self) { n in
                                Button(n==flow.library.tracks.count ? "All \(n)":"\(n)") { flow.seasonRounds=n }.buttonStyle(ChipStyle(selected:flow.seasonRounds==n))
                            }
                        }
                    }
                    option("Laps a race",detail:"Every round runs the same distance in laps.") {
                        HStack(spacing:8) {
                            ForEach([3,5,10],id:\.self) { n in Button("\(n)") { flow.plan.laps=n }.buttonStyle(ChipStyle(selected:flow.plan.laps==n)) }
                            NumberStepper(value:Binding(get:{ flow.plan.laps },set:{ flow.plan.laps=$0 }),range:1...100).padding(.leading,8)
                        }
                    }
                    option("Opponents",detail:"The same drivers all season. Points go to the first eight home: 10, 8, 6, 5, 4, 3, 2, 1.") {
                        HStack(spacing:8) {
                            ForEach([3,5,7,9],id:\.self) { n in Button("\(n)") { flow.plan.opponents=n }.buttonStyle(ChipStyle(selected:flow.plan.opponents==n)) }
                            NumberStepper(value:Binding(get:{ flow.plan.opponents },set:{ flow.plan.opponents=$0 }),range:1...15).padding(.leading,8)
                        }
                    }
                    option("Opponent cars",detail:rivalDetail) {
                        HStack(spacing:8) {
                            ForEach(GameFlow.Rivals.allCases) { r in Button(r.rawValue) { flow.plan.rivals=r }.buttonStyle(ChipStyle(selected:flow.plan.rivals==r)) }
                        }
                    }
                    option("Difficulty",detail:flow.plan.difficulty.summary+".") {
                        HStack(spacing:8) {
                            ForEach(GameFlow.Difficulty.allCases) { d in Button(d.rawValue) { flow.plan.difficulty=d }.buttonStyle(ChipStyle(selected:flow.plan.difficulty==d)) }
                        }
                    }
                    Text("Each race starts in the reverse of the table: the leader at the back. In the first round that is you.")
                        .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                    if let message=flow.message { Text(message).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.bad) }
                    Spacer(minLength:0)
                }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).gamePanel()
                VStack(alignment:.leading,spacing:10) {
                    Text("THE CALENDAR").font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
                    ForEach(Array(flow.seasonTracks.prefix(9).enumerated()),id:\.offset) { index,track in
                        HStack(spacing:12) {
                            Text("\(index+1)").font(GameTheme.mono(13,weight:.bold)).foregroundStyle(GameTheme.textSecondary).frame(width:20,alignment:.trailing)
                            TrackMapView(map:track.map,lineWidth:2,color:GameTheme.text.opacity(0.8),showStart:false).frame(width:44,height:34)
                            Text(track.name).font(GameTheme.label(14,weight:.semibold)).foregroundStyle(GameTheme.text).lineLimit(1)
                            Spacer()
                            Text(RaceFormat.distance(track.length)).font(GameTheme.mono(12)).foregroundStyle(GameTheme.textSecondary)
                        }
                    }
                    if flow.seasonTracks.count>9 { Text("and \(flow.seasonTracks.count-9) more").font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary) }
                    Spacer(minLength:0)
                    Button("Start Season") { flow.startSeason() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .disabled(flow.plan.car==nil || flow.seasonTracks.isEmpty || flow.plan.opponents<1).frame(maxWidth:.infinity)
                }.padding(22).frame(width:400).frame(maxHeight:.infinity).gamePanel(strong:true)
            }
        }.padding(48)
        .onAppear { if flow.plan.opponents<1 { flow.plan.opponents=5 } }
    }
    private var rivalDetail: String {
        let rivals=flow.rivalCars
        if flow.plan.rivals == .sameCar || rivals.isEmpty { return "Everyone drives the car you chose." }
        let list=rivals.map(\.name).joined(separator:", ")
        return flow.plan.rivals == .sameClass && flow.aloneInClass ? "Alone in its class here, so the nearest cars race instead: \(list).":"Against \(list)."
    }
    private func option<Content: View>(_ title: String,detail: String,@ViewBuilder content: ()->Content) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title.uppercased()).font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
            content()
            Text(detail).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary).lineLimit(2)
        }
    }
}

/// The season between races: the table, the calendar, and the next round.
struct ChampionshipScreen: View {
    let flow: GameFlow
    @State private var confirmingAbandon=false
    var body: some View {
        if let season=flow.championship {
            VStack(alignment:.leading,spacing:24) {
                ScreenHeader(title:"Championship",subtitle:season.isComplete ? "The season is over":"Round \(season.roundsRun+1) of \(season.rounds.count) next",back:{ flow.back() })
                HStack(alignment:.top,spacing:28) {
                    table(season).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                    VStack(alignment:.leading,spacing:14) {
                        if let round=season.nextRound { next(season,round) } else { finished(season) }
                        calendar(season)
                        Spacer(minLength:0)
                        HStack {
                            if confirmingAbandon {
                                Text("Give up this season?").font(GameTheme.label(13,weight:.semibold)).foregroundStyle(GameTheme.warn)
                                Button("Yes, abandon") { flow.abandonSeason() }.buttonStyle(SecondaryButtonStyle())
                                Button("Keep") { confirmingAbandon=false }.buttonStyle(SecondaryButtonStyle())
                            } else if season.isComplete {
                                Button("New Season") { flow.abandonSeason();flow.openChampionship() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            } else {
                                Button("Abandon Season") { confirmingAbandon=true }.buttonStyle(SecondaryButtonStyle())
                                Spacer()
                                Button("Start Round \(season.roundsRun+1)  ›") { flow.startSeasonRound() }.buttonStyle(PrimaryButtonStyle())
                                    .keyboardShortcut(.defaultAction).disabled(flow.seasonProblem != nil)
                            }
                        }
                    }.padding(22).frame(width:470).frame(maxHeight:.infinity).gamePanel(strong:true)
                }
            }.padding(48)
        } else {
            VStack(spacing:16) {
                Text("No championship in progress").font(GameTheme.display(26)).foregroundStyle(GameTheme.text)
                Button("Main Menu") { flow.back() }.buttonStyle(PrimaryButtonStyle())
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private func table(_ season: Championship) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:12) {
                Text("POS").frame(width:36,alignment:.leading);Text("DRIVER").frame(width:170,alignment:.leading)
                Text("CAR").frame(maxWidth:.infinity,alignment:.leading);Text("WINS").frame(width:50,alignment:.trailing);Text("POINTS").frame(width:64,alignment:.trailing)
            }.font(GameTheme.label(10,weight:.bold)).foregroundStyle(GameTheme.textSecondary).padding(.horizontal,12)
            ForEach(Array(season.standings.enumerated()),id:\.element.entrant) { place,standing in
                let mine=standing.entrant==0
                HStack(spacing:12) {
                    Text("\(place+1)").font(GameTheme.mono(15,weight:.bold)).frame(width:36,alignment:.leading)
                    Text(season.entrants[standing.entrant].name).font(GameTheme.label(15,weight:.bold)).lineLimit(1).frame(width:170,alignment:.leading)
                    Text(flow.library.car(season.entrants[standing.entrant].car)?.name ?? season.entrants[standing.entrant].car)
                        .font(GameTheme.label(13,weight:.medium)).lineLimit(1).opacity(0.8).frame(maxWidth:.infinity,alignment:.leading)
                    Text("\(standing.wins)").font(GameTheme.mono(14)).frame(width:50,alignment:.trailing)
                    Text("\(standing.points)").font(GameTheme.mono(17,weight:.bold)).frame(width:64,alignment:.trailing)
                }.foregroundStyle(mine ? .black:GameTheme.text).padding(.vertical,8).padding(.horizontal,12)
                    .background(RoundedRectangle(cornerRadius:8).fill(mine ? GameTheme.accent:Color.white.opacity(place==0 && season.roundsRun>0 ? 0.10:0.05)))
            }
        }.padding(18).gamePanel()
    }
    private func next(_ season: Championship,_ round: Int) -> some View {
        let track=flow.library.track(season.rounds[round].track)
        let slot=(season.grid.firstIndex(of:0) ?? 0)+1
        return VStack(alignment:.leading,spacing:10) {
            Text("ROUND \(round+1) OF \(season.rounds.count)").font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
            ZStack(alignment:.bottomTrailing) {
                PreviewImage(url:track?.preview) { Color.black.opacity(0.25) }.frame(maxWidth:.infinity).frame(height:180).clipped()
                if let track {
                    TrackMapView(map:track.map,lineWidth:3).frame(width:120,height:96).padding(8)
                        .background(RoundedRectangle(cornerRadius:10,style:.continuous).fill(.black.opacity(0.6))).padding(8)
                }
            }.clipShape(RoundedRectangle(cornerRadius:10,style:.continuous))
            Text(track?.name ?? season.rounds[round].track).font(GameTheme.display(26)).foregroundStyle(GameTheme.text).lineLimit(1)
            HStack(spacing:10) {
                StatChip(label:"Laps",value:"\(season.laps)")
                if let track { StatChip(label:"Length",value:RaceFormat.distance(track.length)) }
                StatChip(label:"You start",value:"P\(slot) of \(season.entrants.count)")
                StatChip(label:"Table",value:"P\(season.position(of:0))")
            }
            if let problem=flow.seasonProblem ?? flow.message { Text(problem).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.bad) }
        }
    }
    private func finished(_ season: Championship) -> some View {
        let champion=season.champion ?? 0
        return VStack(alignment:.leading,spacing:8) {
            Text("CHAMPION").font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
            Text(champion==0 ? "You":season.entrants[champion].name).font(GameTheme.display(40)).foregroundStyle(GameTheme.text)
            Text(champion==0 ? "The title is yours, with \(season.standings[0].points) points and \(season.standings[0].wins) win\(season.standings[0].wins==1 ? "":"s")."
                 : "You finished P\(season.position(of:0)) with \(season.standings.first { $0.entrant==0 }?.points ?? 0) points.")
                .font(GameTheme.label(15,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
        }
    }
    private func calendar(_ season: Championship) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text("THE CALENDAR").font(GameTheme.label(11,weight:.bold)).foregroundStyle(GameTheme.textSecondary).tracking(1.5).padding(.top,6)
            ForEach(Array(season.rounds.enumerated()).prefix(10),id:\.offset) { index,round in
                HStack(spacing:10) {
                    Text("\(index+1)").font(GameTheme.mono(12,weight:.bold)).foregroundStyle(GameTheme.textSecondary).frame(width:18,alignment:.trailing)
                    Text(flow.library.track(round.track)?.name ?? round.track).font(GameTheme.label(13,weight:.semibold)).foregroundStyle(GameTheme.text).lineLimit(1)
                    Spacer()
                    if let winner=round.classification?.first {
                        Text(winner==0 ? "You won":season.entrants[winner].name).font(GameTheme.label(12,weight:.medium)).foregroundStyle(winner==0 ? GameTheme.accent:GameTheme.textSecondary)
                    } else if index==season.nextRound {
                        Text("NEXT").font(GameTheme.label(10,weight:.black)).foregroundStyle(GameTheme.accent)
                    }
                }
            }
        }
    }
}
