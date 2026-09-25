// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import TORCSRaceEngine

struct DrivingSessionSetup: View {
    let session: DrivingSession
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RaceSessionKind = .practice
    @State private var laps=5
    @State private var cars=3
    @State private var order: StartingOrder = .driversList
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("New Session").font(.title2)
            Text(session.content?.name ?? "").foregroundStyle(.secondary)
            Picker("Session",selection:$kind) {
                Text("Practice").tag(RaceSessionKind.practice)
                Text("Qualifying").tag(RaceSessionKind.qualifying)
                Text("Race").tag(RaceSessionKind.race)
            }.pickerStyle(.segmented)
            Text(description)
            Stepper("Laps: \(laps)",value:$laps,in:1...100).monospacedDigit()
            if kind == .race {
                Stepper("Cars: \(cars)",value:$cars,in:1...16).monospacedDigit()
                Picker("Grid",selection:$order) {
                    Text("Drivers list").tag(StartingOrder.driversList)
                    Text("Qualifying order").tag(StartingOrder.lastRace)
                    Text("Qualifying reversed").tag(StartingOrder.lastRaceReversed)
                }
                if order != .driversList,!session.weekend.qualifyingComplete {
                    Text("Every driver must qualify before a grid can be built from the ranking.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("You start on pole; the rest of the grid is driven by the original BT policy. "
                     + "Telemetry recording is available in practice and qualifying only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(kind == .race
                 ? "The field lines up on the original starting grid. Corner cutting adds a time penalty instead of invalidating the lap, and the pit rules apply."
                 : "The car starts fresh. Wall hits and corner cutting invalidate lap times. A two-second countdown precedes driving.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel",role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Prepare Session") {
                    session.selectedSessionKind=kind;session.selectedLaps=laps;session.selectedCars=cars
                    // A changed field size or grid order starts the weekend over,
                    // because a ranking only describes the field that set it.
                    if session.weekend.cars != cars || session.weekend.startingOrder != order {
                        session.weekend=(try? RaceWeekend(cars:cars,startingOrder:order)) ?? session.weekend
                        session.weekendMessage=nil
                    }
                    session.restart();dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(kind == .race && order != .driversList && !session.weekend.qualifyingComplete
                              && session.weekend.cars==cars && session.weekend.startingOrder==order)
            }
        }.padding(24).frame(width:430)
        .onAppear { kind=session.selectedSessionKind;laps=session.selectedLaps;cars=session.selectedCars
                    order=session.weekend.startingOrder }
    }
    private var description: String {
        switch kind {
        case .practice:return "Drive timed laps and review each lap afterward."
        case .qualifying:return "Set your best valid lap in a solo qualifying run."
        case .race:return "Race the field over a set distance, with the original rules and pit stops."
        }
    }
}

/// A finished race: every car in its finishing order, with the original's gaps
/// and penalties.
struct RaceClassificationView: View {
    let race: RaceResult
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("Classification").font(.headline)
            ForEach(race.classification,id:\.self) { car in
                let entry=race.cars[car]
                HStack(spacing:12) {
                    Text("P\(entry.position)").frame(width:34,alignment:.leading)
                    Text(RaceWeekend.defaultName(car)).frame(width:66,alignment:.leading)
                    Text("\(entry.laps) lap\(entry.laps==1 ? "":"s")").frame(width:62,alignment:.leading)
                    Text(entry.position==1 ? String(format:"%.3f s",entry.totalTime)
                         :entry.lapsBehindLeader>0 ? "+\(entry.lapsBehindLeader) lap\(entry.lapsBehindLeader==1 ? "":"s")"
                         :String(format:"+%.3f s",entry.behindLeader)).frame(width:104,alignment:.leading)
                    Text(entry.bestLap>0 ? String(format:"Best %.3f",entry.bestLap):"Best —")
                        .frame(width:104,alignment:.leading)
                    if entry.penaltyTime>0 { Text(String(format:"+%.2f pen",entry.penaltyTime)).foregroundStyle(.orange) }
                    if entry.eliminated { Text("Out").foregroundStyle(.red) }
                    else if !entry.finished { Text("Unclassified").foregroundStyle(.secondary) }
                    Spacer()
                }.font(.callout).monospacedDigit()
            }
        }
    }
}

struct DrivingResultsView: View {
    let session: DrivingSession
    let result: DrivingSessionResult
    @Environment(\.dismiss) private var dismiss
    private var status: String {
        switch result.reason {
        case .completed:return "Completed"
        case .retired:return "Retired"
        case .endedEarly:return "Ended early"
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(result.configuration.kind == .qualifying ? "Qualifying Results":"Practice Results").font(.title2)
            Text("\(status) · \(result.laps.count) / \(result.configuration.laps) laps")
            HStack {
                Text(result.bestLap.map { String(format:"Best valid lap: %.3f s",$0) } ?? "No valid timed lap")
                Spacer()
                Text(String(format:"Session: %.3f s",result.elapsed))
            }.monospacedDigit()
            Table(result.laps) {
                TableColumn("Lap") { Text("\($0.number)") }.width(45)
                TableColumn("Time") { Text(String(format:"%.3f s",$0.time)) }
                TableColumn("Status") { Text($0.valid ? "Valid":"Invalid") }
                TableColumn("Top speed") { Text(String(format:"%.0f km/h",$0.topSpeed*3.6)) }
            }.frame(minHeight:180,maxHeight:300).monospacedDigit()
            HStack {
                Button("Save Results…") { session.exportResults(result) }
                Spacer()
                Button("Drive Again") {
                    session.selectedSessionKind=result.configuration.kind;session.selectedLaps=result.configuration.laps
                    session.restart();dismiss()
                }.disabled(session.sessionBusy || session.captureBusy)
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:580)
    }
}

extension CompletedLap: Identifiable {
    public var id: Int { number }
}
