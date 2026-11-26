// SPDX-License-Identifier: GPL-2.0-only
// Putting a session together: the circuit, the car, then the options, and
// the loading screen that follows.
import SwiftUI
import TORCSRaceEngine
import TORCSPresentation

/// A list row's frame: lit and edged when selected.
private struct CardLook: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content.padding(10)
            .background(RoundedRectangle(cornerRadius:12,style:.continuous).fill(selected ? Color.white.opacity(0.10):GameTheme.panel))
            .overlay(RoundedRectangle(cornerRadius:12,style:.continuous).stroke(selected ? GameTheme.accent.opacity(0.8):GameTheme.stroke,lineWidth:selected ? 1.5:1))
    }
}

struct TrackSelectScreen: View {
    let flow: GameFlow
    @State private var selection: String?
    private var selected: TrackDescriptor? { flow.library.track(selection) }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeader(title:"Choose a circuit",subtitle:"\(flow.library.tracks.count) circuits",crumbs:[RaceFormat.kind(flow.plan.kind),"Circuit","Car","Options"],back:{ flow.back() })
            HStack(alignment:.top,spacing:28) {
                KeyboardList(items:flow.library.tracks,selection:$selection,activate:{ flow.selectTrack($0) }) { track,selected in
                    HStack(spacing:14) {
                        TrackMapView(map:track.map,lineWidth:2.5,color:selected ? GameTheme.accent:GameTheme.text.opacity(0.7),showStart:false).frame(width:70,height:56)
                        VStack(alignment:.leading,spacing:3) {
                            Text(track.name).font(GameTheme.label(18,weight:.bold)).foregroundStyle(GameTheme.text)
                            Text("\(track.categoryTitle) · \(RaceFormat.distance(track.length)) · \(track.corners) corners")
                                .font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                        }
                        Spacer()
                        if let best=flow.records.best(track:track.id,car:nil) {
                            Text(RaceFormat.lap(best.time)).font(GameTheme.mono(12)).foregroundStyle(GameTheme.good)
                        }
                    }.modifier(CardLook(selected:selected))
                }.frame(width:460)
                if let track=selected {
                    VStack(alignment:.leading,spacing:14) {
                        ZStack {
                            PreviewImage(url:track.preview) { Color.black.opacity(0.25) }
                                .frame(maxWidth:.infinity).frame(height:330).clipped()
                                .overlay(LinearGradient(colors:[.black.opacity(0.15),.black.opacity(0.72)],startPoint:.top,endPoint:.bottom))
                            TrackMapView(map:track.map,lineWidth:5).frame(height:270).padding(24)
                                .shadow(color:.black.opacity(0.8),radius:10)
                        }.clipShape(RoundedRectangle(cornerRadius:12,style:.continuous))
                        Text(track.name).font(GameTheme.display(34)).foregroundStyle(GameTheme.text)
                        HStack(spacing:10) {
                            StatChip(label:"Length",value:RaceFormat.distance(track.length))
                            StatChip(label:"Corners",value:"\(track.corners)")
                            StatChip(label:"Width",value:String(format:"%.0f m",track.width))
                            StatChip(label:"Type",value:track.categoryTitle)
                            if let best=flow.records.best(track:track.id,car:nil) { StatChip(label:"Your best",value:RaceFormat.lap(best.time)) }
                        }
                        if !track.author.isEmpty { Text("By \(track.author)").font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary) }
                        if !track.summary.isEmpty { Text(track.summary).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary).lineLimit(3) }
                        Spacer(minLength:0)
                        HStack { Spacer();Button("Choose Car  ›") { flow.selectTrack(track) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
                    }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity).gamePanel(strong:true)
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
    private var cars: [CarDescriptor] { flow.library.cars }
    private var selected: CarDescriptor? { flow.library.car(selection) }
    private func glyph(_ size: CGFloat) -> some View {
        ZStack { Color.black.opacity(0.25);Image(systemName:"car.side.fill").font(.system(size:size,weight:.ultraLight)).foregroundStyle(GameTheme.text.opacity(0.6)) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeader(title:"Choose a car",subtitle:flow.choosingSeasonCar ? "\(cars.count) cars · yours for the season":flow.plan.track.map { "\(cars.count) cars · on \($0.name)" },
                         crumbs:flow.choosingSeasonCar ? ["Championship","Car","Season"]:[RaceFormat.kind(flow.plan.kind),"Circuit","Car","Options"],back:{ flow.back() })
            HStack(alignment:.top,spacing:28) {
                KeyboardList(items:cars,selection:$selection,activate:{ flow.selectCar($0) }) { car,selected in
                    HStack(spacing:14) {
                        PreviewImage(url:car.preview) { glyph(22) }.frame(width:96,height:54).clipShape(RoundedRectangle(cornerRadius:8,style:.continuous))
                        VStack(alignment:.leading,spacing:3) {
                            Text(car.name).font(GameTheme.label(17,weight:.bold)).foregroundStyle(GameTheme.text).lineLimit(1)
                            Text("\(car.categoryTitle) · \(car.horsepower) hp · \(Int(car.mass)) kg").font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                    }.modifier(CardLook(selected:selected))
                }.frame(width:460)
                if let car=selected {
                    let best=cars.map(\.power).max() ?? 1,heaviest=cars.map(\.mass).max() ?? 1
                    let ratio=cars.map(\.powerToWeight).max() ?? 1,revs=cars.map(\.revsLimiter).max() ?? 1
                    VStack(alignment:.leading,spacing:14) {
                        PreviewImage(url:car.preview) { glyph(130) }
                            .frame(maxWidth:.infinity).frame(height:330).clipped()
                            .clipShape(RoundedRectangle(cornerRadius:12,style:.continuous))
                        HStack(alignment:.firstTextBaseline) {
                            Text(car.name).font(GameTheme.display(32)).foregroundStyle(GameTheme.text).lineLimit(1).minimumScaleFactor(0.6)
                            Spacer()
                            Text(car.categoryTitle.uppercased()).font(GameTheme.label(11,weight:.black)).tracking(1.2).foregroundStyle(.white)
                                .padding(.vertical,5).padding(.horizontal,10).background(Capsule().fill(GameTheme.accent))
                        }
                        HStack(spacing:22) {
                            VStack(spacing:12) {
                                StatBar(label:"Power",value:"\(car.horsepower) hp",fraction:Double(car.power/max(best,1)))
                                StatBar(label:"Power to weight",value:String(format:"%.0f hp/t",car.powerToWeight/745.7*1000),fraction:Double(car.powerToWeight/max(ratio,1e-3)))
                            }
                            VStack(spacing:12) {
                                StatBar(label:"Weight",value:"\(Int(car.mass)) kg",fraction:Double(car.mass/max(heaviest,1)))
                                StatBar(label:"Rev limit",value:"\(Int(car.revsLimiter)) rpm",fraction:Double(car.revsLimiter/max(revs,1)))
                            }
                        }
                        HStack(spacing:10) {
                            if !car.drivetrain.isEmpty { StatChip(label:"Drive",value:car.drivetrain) }
                            StatChip(label:"Gearbox",value:"\(car.gears)-speed")
                            if let track=flow.plan.track,let record=flow.records.best(track:track.id,car:car.id) {
                                StatChip(label:"Your best here",value:RaceFormat.lap(record.time))
                            }
                        }
                        Spacer(minLength:0)
                        HStack { Spacer();Button(flow.choosingSeasonCar ? "Season Options  ›":"Session Options  ›") { flow.selectCar(car) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
                    }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity).gamePanel(strong:true)
                } else {
                    ContentUnavailableView("No cars",systemImage:"car.side",description:Text("Add a content folder in Settings.")).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }.padding(48)
        .onAppear { selection=flow.plan.car?.id ?? cars.first?.id }
    }
}

struct SessionOptionsScreen: View {
    let flow: GameFlow
    private var kind: RaceSessionKind { flow.plan.kind }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeader(title:"\(RaceFormat.kind(kind)) options",crumbs:[RaceFormat.kind(kind),"Circuit","Car","Options"],back:{ flow.back() })
            HStack(alignment:.top,spacing:28) {
                VStack(alignment:.leading,spacing:kind == .race ? 14:20) {
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
                        option("Opponent cars",detail:rivalDetail) {
                            HStack(spacing:8) {
                                ForEach(GameFlow.Rivals.allCases) { r in
                                    Button(r.rawValue) { flow.plan.rivals=r }.buttonStyle(ChipStyle(selected:flow.plan.rivals==r))
                                }
                            }
                        }
                        option("Difficulty",detail:flow.plan.difficulty.summary+".") {
                            HStack(spacing:8) {
                                ForEach(GameFlow.Difficulty.allCases) { d in
                                    Button(d.rawValue) { flow.plan.difficulty=d }.buttonStyle(ChipStyle(selected:flow.plan.difficulty==d))
                                }
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
                    Spacer(minLength:0)
                }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).gamePanel()
                VStack(alignment:.leading,spacing:12) {
                    ZStack {
                        PreviewImage(url:flow.plan.car?.preview) { Color.black.opacity(0.25) }.frame(maxWidth:.infinity).frame(height:170).clipped()
                    }.clipShape(RoundedRectangle(cornerRadius:10,style:.continuous))
                    HStack(spacing:12) {
                        if let track=flow.plan.track { TrackMapView(map:track.map,lineWidth:3).frame(width:86,height:70) }
                        VStack(alignment:.leading,spacing:2) {
                            Text(flow.plan.track?.name ?? "—").font(GameTheme.display(24)).foregroundStyle(GameTheme.text).lineLimit(1).minimumScaleFactor(0.6)
                            Text(flow.plan.car?.name ?? "—").font(GameTheme.label(15,weight:.semibold)).foregroundStyle(GameTheme.textSecondary).lineLimit(1)
                        }
                    }
                    Divider().overlay(GameTheme.stroke)
                    summaryRow("Mode",RaceFormat.kind(kind))
                    summaryRow("Laps","\(flow.plan.laps)")
                    if kind != .practice { summaryRow("Field","\(flow.plan.cars) car\(flow.plan.cars==1 ? "":"s")") }
                    if kind == .race { summaryRow("Grid",flow.plan.order == .driversList ? "You on pole":flow.plan.order == .lastRace ? "Qualifying order":"Qualifying reversed") }
                    summaryRow("Conditions",flow.plan.conditions.rawValue)
                    if let track=flow.plan.track,let car=flow.plan.car,let record=flow.records.best(track:track.id,car:car.id) {
                        summaryRow("Your best lap",RaceFormat.lap(record.time))
                    }
                    if let message=flow.message { Text(message).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.bad).textSelection(.enabled) }
                    Spacer(minLength:0)
                    Button(kind == .race ? "Start Race":kind == .qualifying ? "Start Qualifying":"Start Training") { flow.startSession() }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!flow.ready)
                        .frame(maxWidth:.infinity)
                }.padding(20).frame(width:380).frame(maxHeight:.infinity).gamePanel(strong:true)
            }
        }.padding(48)
    }
    private var rivalDetail: String {
        let rivals=flow.rivalCars
        if flow.plan.opponents==0 { return "No opponents." }
        if flow.plan.rivals == .sameCar || rivals.isEmpty {
            return flow.plan.rivals == .sameCar ? "Everyone drives the car you chose.":"No other car fits; everyone drives yours."
        }
        let list=rivals.map(\.name).joined(separator:", ")
        if flow.plan.rivals == .sameClass,flow.aloneInClass { return "Alone in its class here, so the nearest cars race instead: \(list)." }
        return "Against \(list)."
    }
    private func option<Content: View>(_ title: String,detail: String,@ViewBuilder content: ()->Content) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title.uppercased()).font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
            content()
            Text(detail).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary).lineLimit(2)
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
