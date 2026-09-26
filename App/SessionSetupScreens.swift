// SPDX-License-Identifier: GPL-2.0-only
// Putting a session together: the circuit, the car, then the options, and
// the loading screen that follows.
import SwiftUI
import TORCSRaceEngine
import TORCSPresentation

struct TrackSelectScreen: View {
    let flow: GameFlow
    @State private var selection: String?
    private var selected: TrackDescriptor? { flow.library.tracks.first { $0.id==selection } }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeader(title:"Choose a circuit",crumbs:[RaceFormat.kind(flow.plan.kind),"Circuit","Car","Options"],back:{ flow.back() })
            HStack(alignment:.top,spacing:28) {
                KeyboardList(items:flow.library.tracks,selection:$selection,activate:{ flow.selectTrack($0) }) { track,selected in
                    HStack(spacing:16) {
                        TrackMapView(map:track.map,lineWidth:2.5,color:selected ? GameTheme.accent:GameTheme.text.opacity(0.7),showStart:false).frame(width:76,height:64)
                        VStack(alignment:.leading,spacing:3) {
                            Text(track.name).font(GameTheme.label(19,weight:.bold)).foregroundStyle(GameTheme.text)
                            Text("\(track.categoryTitle) · \(RaceFormat.distance(track.length)) · \(flow.library.cars(on:track).count) car\(flow.library.cars(on:track).count==1 ? "":"s")")
                                .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                        }
                        Spacer()
                    }.padding(12).background(RoundedRectangle(cornerRadius:12,style:.continuous).fill(selected ? Color.white.opacity(0.10):GameTheme.panel))
                        .overlay(RoundedRectangle(cornerRadius:12,style:.continuous).stroke(selected ? GameTheme.accent.opacity(0.8):GameTheme.stroke,lineWidth:selected ? 1.5:1))
                }.frame(width:480)
                if let track=selected {
                    VStack(alignment:.leading,spacing:16) {
                        TrackMapView(map:track.map,lineWidth:5).frame(maxWidth:.infinity).frame(height:340)
                        Text(track.name).font(GameTheme.display(34)).foregroundStyle(GameTheme.text)
                        HStack(spacing:10) {
                            StatChip(label:"Length",value:RaceFormat.distance(track.length))
                            StatChip(label:"Width",value:String(format:"%.0f m",track.width))
                            StatChip(label:"Type",value:track.categoryTitle)
                        }
                        if !track.author.isEmpty { Text("By \(track.author)").font(GameTheme.label(14,weight:.medium)).foregroundStyle(GameTheme.textSecondary) }
                        if !track.summary.isEmpty { Text(track.summary).font(GameTheme.label(14,weight:.medium)).foregroundStyle(GameTheme.textSecondary).fixedSize(horizontal:false,vertical:true) }
                        Spacer()
                        HStack { Spacer();Button("Choose Car  ›") { flow.selectTrack(track) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
                    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).gamePanel(strong:true)
                } else {
                    ContentUnavailableView("No circuits",systemImage:"road.lanes",description:Text("Add a content folder in Settings.")).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }.padding(48)
        .onAppear { selection=flow.plan.track?.id ?? flow.library.tracks.first?.id }
    }
}

struct CarSelectScreen: View {
    let flow: GameFlow
    @State private var selection: String?
    private var cars: [CarDescriptor] { flow.plan.track.map { flow.library.cars(on:$0) } ?? [] }
    private var selected: CarDescriptor? { cars.first { $0.id==selection } }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeader(title:"Choose a car",subtitle:flow.plan.track.map { "On \($0.name)" },crumbs:[RaceFormat.kind(flow.plan.kind),"Circuit","Car","Options"],back:{ flow.back() })
            HStack(alignment:.top,spacing:28) {
                KeyboardList(items:cars,selection:$selection,activate:{ flow.selectCar($0) }) { car,selected in
                    HStack(spacing:16) {
                        Image(systemName:"car.side.fill").font(.system(size:26,weight:.regular)).foregroundStyle(selected ? GameTheme.accent:GameTheme.text.opacity(0.7)).frame(width:60)
                        VStack(alignment:.leading,spacing:3) {
                            Text(car.name).font(GameTheme.label(19,weight:.bold)).foregroundStyle(GameTheme.text)
                            Text("\(car.category) · \(Int(car.mass)) kg · \(car.gears)-speed").font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                        }
                        Spacer()
                    }.padding(12).background(RoundedRectangle(cornerRadius:12,style:.continuous).fill(selected ? Color.white.opacity(0.10):GameTheme.panel))
                        .overlay(RoundedRectangle(cornerRadius:12,style:.continuous).stroke(selected ? GameTheme.accent.opacity(0.8):GameTheme.stroke,lineWidth:selected ? 1.5:1))
                }.frame(width:480)
                if let car=selected {
                    VStack(alignment:.leading,spacing:16) {
                        HStack { Spacer();Image(systemName:"car.side.fill").font(.system(size:150,weight:.ultraLight)).foregroundStyle(GameTheme.text.opacity(0.85));Spacer() }.frame(height:300)
                        Text(car.name).font(GameTheme.display(34)).foregroundStyle(GameTheme.text)
                        HStack(spacing:10) {
                            StatChip(label:"Class",value:car.category)
                            StatChip(label:"Mass",value:"\(Int(car.mass)) kg")
                            StatChip(label:"Gearbox",value:"\(car.gears)-speed")
                            if car.revsLimiter>0 { StatChip(label:"Rev limit",value:"\(Int(car.revsLimiter)) rpm") }
                        }
                        if let entry=flow.plan.track.flatMap({ flow.library.entry(track:$0.id,car:car.id) }) {
                            Text(entry.hasMaterials ? "Enhanced materials":"Original artwork").font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                        }
                        Spacer()
                        HStack { Spacer();Button("Session Options  ›") { flow.selectCar(car) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
                    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).gamePanel(strong:true)
                } else {
                    ContentUnavailableView("No cars on this circuit",systemImage:"car.side",description:Text("Prepare a session with a car on this track.")).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }.padding(48)
        .onAppear { selection=cars.contains { $0.id==flow.plan.car?.id } ? flow.plan.car?.id:cars.first?.id }
    }
}

struct SessionOptionsScreen: View {
    let flow: GameFlow
    @State private var lapsText=""
    private var kind: RaceSessionKind { flow.plan.kind }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeader(title:"\(RaceFormat.kind(kind)) options",crumbs:[RaceFormat.kind(kind),"Circuit","Car","Options"],back:{ flow.back() })
            HStack(alignment:.top,spacing:28) {
                VStack(alignment:.leading,spacing:26) {
                    option("Laps",detail:kind == .qualifying ? "Every driver gets this many laps to set a time.":"The distance of the session.") {
                        HStack(spacing:8) {
                            ForEach([1,3,5,10,20],id:\.self) { n in
                                Button("\(n)") { flow.plan.laps=n }.buttonStyle(ChipStyle(selected:flow.plan.laps==n))
                            }
                            NumberStepper(value:Binding(get:{ flow.plan.laps },set:{ flow.plan.laps=$0 }),range:1...100).padding(.leading,8)
                        }
                    }
                    if kind != .practice {
                        option("Opponents",detail:"Cars driven by the original BT policy, with its opponent handling.") {
                            HStack(spacing:8) {
                                ForEach([0,3,5,9,15],id:\.self) { n in
                                    Button("\(n)") { flow.plan.opponents=n }.buttonStyle(ChipStyle(selected:flow.plan.opponents==n))
                                }
                                NumberStepper(value:Binding(get:{ flow.plan.opponents },set:{ flow.plan.opponents=$0 }),range:0...15).padding(.leading,8)
                            }
                        }
                    }
                    if kind == .race {
                        option("Starting grid",detail:flow.qualifyingOrderAvailable ? "A qualifying order is set for this circuit, car and field.":"Qualify on this circuit with this field to start from the qualifying order.") {
                            HStack(spacing:8) {
                                Button("You on pole") { flow.plan.order = .driversList }.buttonStyle(ChipStyle(selected:flow.plan.order == .driversList))
                                Button("Qualifying order") { flow.plan.order = .lastRace }.buttonStyle(ChipStyle(selected:flow.plan.order == .lastRace)).disabled(!flow.qualifyingOrderAvailable)
                                Button("Qualifying reversed") { flow.plan.order = .lastRaceReversed }.buttonStyle(ChipStyle(selected:flow.plan.order == .lastRaceReversed)).disabled(!flow.qualifyingOrderAvailable)
                            }
                        }
                    }
                    option("Conditions",detail:flow.plan.conditions.summary+". Visual only: grip is unchanged.") {
                        HStack(spacing:8) {
                            ForEach(GameFlow.Conditions.allCases) { c in
                                Button(c.rawValue) { flow.plan.conditions=c }.buttonStyle(ChipStyle(selected:flow.plan.conditions==c))
                            }
                        }
                    }
                    option("Camera",detail:"The view the session starts in. V steps through the driving views while driving.") {
                        ArrowChooser(options:DrivingCameraPreset.allCases,selection:Binding(get:{ flow.session.cameraPreset },set:{ flow.session.selectCamera($0) }),title:{ "\($0.rawValue) · \($0.family)" },width:300)
                    }
                    Text(kind == .race ? "The field lines up on the original starting grid. Corner cutting adds a time penalty, and the pit rules apply."
                         : kind == .qualifying ? "You run first. Then each opponent's run is simulated and the grid is set from the ranking."
                         : "Wall hits and corner cutting invalidate a lap. Telemetry can be recorded from the pause menu.")
                        .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).gamePanel()
                VStack(alignment:.leading,spacing:14) {
                    if let track=flow.plan.track { TrackMapView(map:track.map,lineWidth:4).frame(height:220) }
                    Text(flow.plan.track?.name ?? "—").font(GameTheme.display(28)).foregroundStyle(GameTheme.text)
                    Text(flow.plan.car?.name ?? "—").font(GameTheme.label(17,weight:.semibold)).foregroundStyle(GameTheme.textSecondary)
                    Divider().overlay(GameTheme.stroke)
                    summaryRow("Mode",RaceFormat.kind(kind))
                    summaryRow("Laps","\(flow.plan.laps)")
                    if kind != .practice { summaryRow("Field","\(flow.plan.cars) car\(flow.plan.cars==1 ? "":"s")") }
                    if kind == .race { summaryRow("Grid",flow.plan.order == .driversList ? "You on pole":flow.plan.order == .lastRace ? "Qualifying order":"Qualifying reversed") }
                    summaryRow("Conditions",flow.plan.conditions.rawValue)
                    if let message=flow.message { Text(message).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.bad).textSelection(.enabled) }
                    Spacer()
                    Button(kind == .race ? "Start Race":kind == .qualifying ? "Start Qualifying":"Start Training") { flow.startSession() }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(flow.entry==nil)
                        .frame(maxWidth:.infinity)
                }.padding(24).frame(width:360).frame(maxHeight:.infinity).gamePanel(strong:true)
            }
        }.padding(48)
    }
    private func option<Content: View>(_ title: String,detail: String,@ViewBuilder content: ()->Content) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title.uppercased()).font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
            content()
            Text(detail).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
        }
    }
    private func summaryRow(_ label: String,_ value: String) -> some View {
        HStack { Text(label).foregroundStyle(GameTheme.textSecondary);Spacer();Text(value).foregroundStyle(GameTheme.text) }.font(GameTheme.label(14,weight:.semibold))
    }
}

/// The circuit draws itself while the content loads.
struct LoadingScreen: View {
    let flow: GameFlow
    var caption="Loading"
    @State private var progress: CGFloat = 0
    var body: some View {
        VStack(spacing:22) {
            if let track=flow.plan.track {
                TrackMapView(map:track.map,lineWidth:5,progress:progress,showStart:progress>=1).frame(width:420,height:340)
                    .onAppear { withAnimation(.easeInOut(duration:2.2).repeatForever(autoreverses:false)) { progress=1 } }
            }
            Text(flow.plan.track?.name ?? "").font(GameTheme.display(34)).foregroundStyle(GameTheme.text)
            Text(flow.plan.car?.name ?? "").font(GameTheme.label(18,weight:.semibold)).foregroundStyle(GameTheme.textSecondary)
            HStack(spacing:10) { ProgressView().controlSize(.small);Text(caption+"…").font(GameTheme.label(14,weight:.medium)).foregroundStyle(GameTheme.textSecondary) }
            Text("ESC pauses · V steps the camera · the session pauses when the window loses focus")
                .font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary.opacity(0.7)).padding(.top,20)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
