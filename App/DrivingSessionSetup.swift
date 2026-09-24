// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import TORCSRaceEngine

struct DrivingSessionSetup: View {
    let session: DrivingSession
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RaceSessionKind = .practice
    @State private var laps=5
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("New Session").font(.title2)
            Text(session.content?.name ?? "").foregroundStyle(.secondary)
            Picker("Session",selection:$kind) {
                Text("Practice").tag(RaceSessionKind.practice)
                Text("Qualifying").tag(RaceSessionKind.qualifying)
            }.pickerStyle(.segmented)
            Text(kind == .practice ? "Drive timed laps and review each lap afterward.":"Set your best valid lap in a solo qualifying run.")
            Stepper("Laps: \(laps)",value:$laps,in:1...100).monospacedDigit()
            Text("The car starts fresh. Wall hits and corner cutting invalidate lap times. A two-second countdown precedes driving.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel",role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Prepare Session") {
                    session.selectedSessionKind=kind;session.selectedLaps=laps;session.restart();dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:430)
        .onAppear { kind=session.selectedSessionKind;laps=session.selectedLaps }
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
