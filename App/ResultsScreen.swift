// SPDX-License-Identifier: GPL-2.0-only
// After a session: the classification or the lap sheet, the opponents
// qualifying, and where to go next.
import SwiftUI
import TORCSRaceEngine

struct ResultsScreen: View {
    let flow: GameFlow
    private var session: DrivingSession { flow.session }
    private var result: DrivingSessionResult? { session.hudFrame?.result ?? session.lastResult }
    private var race: RaceResult? { session.hudFrame?.raceResult ?? session.lastRaceResult }
    private var kind: RaceSessionKind { result?.configuration.kind ?? flow.plan.kind }
    private var status: String {
        switch result?.reason { case .completed:"Completed";case .retired:"Retired";case .endedEarly:"Ended early";case nil:"" }
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.firstTextBaseline) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(kind == .race ? "RACE RESULT":kind == .qualifying ? "QUALIFYING":"TRAINING").font(GameTheme.display(36)).foregroundStyle(GameTheme.text)
                        Text("\(status) · \(flow.plan.track?.name ?? "") · \(flow.plan.car?.name ?? "") · \(result?.laps.count ?? 0) of \(result?.configuration.laps ?? flow.plan.laps) laps")
                            .font(GameTheme.label(14,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                    }
                    Spacer()
                    if let result {
                        VStack(alignment:.trailing,spacing:2) {
                            Text(flow.newRecord ? "NEW PERSONAL BEST":"BEST LAP").font(GameTheme.label(10,weight:.bold)).foregroundStyle(flow.newRecord ? GameTheme.accent:GameTheme.textSecondary).tracking(1.5)
                            Text(result.bestLap.map { RaceFormat.lap($0) } ?? "no valid lap").font(GameTheme.mono(28,weight:.bold)).foregroundStyle(result.bestLap==nil ? GameTheme.textSecondary:GameTheme.good)
                        }
                    }
                }
                if let race,kind == .race { classification(race) }
                else if let result { laps(result) }
                if kind == .qualifying { qualifyingStatus }
                if let message=flow.message { Text(message).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.bad) }
                HStack(spacing:12) {
                    if let result { Button("Save Results…") { session.exportResults(result) }.buttonStyle(SecondaryButtonStyle()) }
                    if let message=session.captureMessage { Text(message).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary) }
                    Spacer()
                    Button("Main Menu") { flow.quitToMenu() }.buttonStyle(SecondaryButtonStyle())
                    if flow.championshipRound != nil {
                        // A round that counted goes to the table; one ended early can be run again.
                        if result?.reason == .endedEarly { Button("Restart Round") { flow.restartSession() }.buttonStyle(SecondaryButtonStyle()) }
                        Button("Championship  ›") { flow.showSeason() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    } else {
                    Button("Change Setup") { flow.changeSetup() }.buttonStyle(SecondaryButtonStyle())
                    switch kind {
                    case .practice: Button("Drive Again") { flow.restartSession() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    case .qualifying:
                        Button("Qualify Again") { flow.restartSession() }.buttonStyle(SecondaryButtonStyle())
                        Button(flow.qualifyingDone ? "Set Up the Race  ›":"Waiting for the field…") { flow.proceedToRace() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!flow.qualifyingDone)
                    case .race: Button("Race Again") { flow.restartSession() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    }
                    }
                }
            }.padding(28).frame(width:920).gamePanel(strong:true)
        }
    }
    private func header(_ columns: [(String,CGFloat,Alignment)]) -> some View {
        HStack(spacing:12) {
            ForEach(columns,id:\.0) { c in Text(c.0.uppercased()).frame(width:c.1,alignment:c.2) }
            Spacer()
        }.font(GameTheme.label(10,weight:.bold)).foregroundStyle(GameTheme.textSecondary).padding(.horizontal,10)
    }
    private func classification(_ race: RaceResult) -> some View {
        VStack(spacing:4) {
            header([("Pos",36,.leading),("Driver",120,.leading),("Car",150,.leading),("Laps",40,.leading),("Gap",100,.trailing),("Best lap",100,.trailing),("Penalty",70,.trailing)])
            ScrollView(showsIndicators:false) {
                VStack(spacing:3) {
                    ForEach(race.classification,id:\.self) { car in
                        let e=race.cars[car],mine=car==session.hudFrame?.viewer ?? 0
                        HStack(spacing:12) {
                            Text("P\(e.position)").frame(width:36,alignment:.leading).font(GameTheme.mono(14,weight:.bold))
                            Text(session.driverName(car)).lineLimit(1).frame(width:120,alignment:.leading).font(GameTheme.label(14,weight:.bold))
                            Text(session.content?.models[session.model(of:car)].name ?? "").lineLimit(1).frame(width:150,alignment:.leading).font(GameTheme.label(12,weight:.medium)).opacity(0.8)
                            Text("\(e.laps)").frame(width:40,alignment:.leading).font(GameTheme.mono(14))
                            Text(e.position==1 ? RaceFormat.lap(e.totalTime):e.lapsBehindLeader>0 ? "+\(e.lapsBehindLeader) lap\(e.lapsBehindLeader==1 ? "":"s")":RaceFormat.gap(e.behindLeader)).frame(width:100,alignment:.trailing).font(GameTheme.mono(14))
                            Text(e.bestLap>0 ? RaceFormat.lap(e.bestLap):"—").frame(width:100,alignment:.trailing).font(GameTheme.mono(14))
                            Text(e.penaltyTime>0 ? String(format:"+%.2f s",e.penaltyTime):"—").frame(width:70,alignment:.trailing).font(GameTheme.mono(14)).foregroundStyle(e.penaltyTime>0 ? GameTheme.warn:GameTheme.textSecondary)
                            if e.eliminated { Text("OUT").font(GameTheme.label(10,weight:.black)).foregroundStyle(GameTheme.bad) }
                            else if !e.finished { Text("UNCLASSIFIED").font(GameTheme.label(10,weight:.black)).foregroundStyle(GameTheme.textSecondary) }
                            Spacer()
                        }.foregroundStyle(mine ? .black:GameTheme.text).padding(.vertical,6).padding(.horizontal,10)
                            .background(RoundedRectangle(cornerRadius:8).fill(mine ? GameTheme.accent:Color.white.opacity(0.05)))
                    }
                }
            }.frame(maxHeight:300)
        }
    }
    private func laps(_ result: DrivingSessionResult) -> some View {
        VStack(spacing:4) {
            header([("Lap",50,.leading),("Time",120,.trailing),("Status",80,.leading),("Top speed",100,.trailing)])
            if result.laps.isEmpty { Text("No lap completed.").font(GameTheme.label(14,weight:.medium)).foregroundStyle(GameTheme.textSecondary).padding(10) }
            ScrollView(showsIndicators:false) {
                VStack(spacing:3) {
                    ForEach(result.laps,id:\.number) { lap in
                        let best=result.bestLap==lap.time && lap.valid
                        HStack(spacing:12) {
                            Text("\(lap.number)").frame(width:50,alignment:.leading).font(GameTheme.mono(14,weight:.bold))
                            Text(RaceFormat.lap(lap.time)).frame(width:120,alignment:.trailing).font(GameTheme.mono(14)).foregroundStyle(best ? GameTheme.good:GameTheme.text)
                            Text(lap.valid ? "Valid":"Invalid").frame(width:80,alignment:.leading).font(GameTheme.label(13,weight:.semibold)).foregroundStyle(lap.valid ? GameTheme.textSecondary:GameTheme.bad)
                            Text(String(format:"%.0f km/h",lap.topSpeed*3.6)).frame(width:100,alignment:.trailing).font(GameTheme.mono(14))
                            Spacer()
                        }.foregroundStyle(GameTheme.text).padding(.vertical,6).padding(.horizontal,10)
                            .background(RoundedRectangle(cornerRadius:8).fill(Color.white.opacity(0.05)))
                    }
                }
            }.frame(maxHeight:220)
            HStack {
                Text(String(format:"Session time %@ · fuel %.0f l · damage %d",RaceFormat.lap(result.elapsed),result.fuel,result.damage))
                Spacer()
            }.font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary).padding(.horizontal,10)
        }
    }
    @ViewBuilder private var qualifyingStatus: some View {
        let weekend=session.weekend
        VStack(alignment:.leading,spacing:10) {
            if let car=flow.qualifyingCar {
                HStack(spacing:12) {
                    ProgressView(value:flow.qualifyingFraction).frame(width:200)
                    Text("\(session.driverName(car)) is qualifying… \(weekend.ranking.count) of \(weekend.cars) drivers have run")
                        .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                }
            } else if flow.qualifyingDone {
                Text("THE GRID").font(GameTheme.label(11,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
            }
            if !weekend.ranking.isEmpty {
                let columns=Array(repeating:GridItem(.flexible(),spacing:8),count:3)
                LazyVGrid(columns:columns,spacing:6) {
                    ForEach(Array(weekend.ranking.enumerated()),id:\.offset) { slot,run in
                        let mine=run.index==0
                        HStack(spacing:8) {
                            Text("P\(slot+1)").font(GameTheme.mono(13,weight:.bold)).frame(width:30,alignment:.leading)
                            Text(mine ? "You":run.name).font(GameTheme.label(13,weight:.bold)).lineLimit(1)
                            Spacer()
                            Text(run.bestLapTime>0 ? RaceFormat.lap(Double(run.bestLapTime)):"no time").font(GameTheme.mono(12))
                        }.foregroundStyle(mine ? .black:GameTheme.text).padding(.vertical,5).padding(.horizontal,8)
                            .background(RoundedRectangle(cornerRadius:6).fill(mine ? GameTheme.accent:Color.white.opacity(0.05)))
                    }
                }
            }
            if weekend.cars>1 {
                Text("Opponents' times are their fastest laps: the BT policy rides the curbs, which the original's lap rule would invalidate on every lap.")
                    .font(GameTheme.label(11,weight:.medium)).foregroundStyle(GameTheme.textSecondary.opacity(0.8))
            }
        }
    }
}
