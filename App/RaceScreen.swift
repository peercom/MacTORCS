// SPDX-License-Identifier: GPL-2.0-only
// The driving screen: the renderer full-window, the HUD over it, and the
// pause menu, loading veil, error and results panels over that.
import SwiftUI
import TORCSRaceEngine
import TORCSPresentation

struct RaceScreen: View {
    let flow: GameFlow
    private var session: DrivingSession { flow.session }
    @AppStorage("renderRate") private var renderRate=60
    @AppStorage("hudStandings") private var showStandings=true
    private var pauseShown: Bool {
        session.paused && session.firstFrameDrawn && flow.sessionStarted && session.frame?.result==nil && session.message==nil && flow.screen == .driving
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let content=session.content {
                DrivingMetalView(session:session,content:content,rate:renderRate,camera:session.cameraPreset,zoom:session.cameraZoom,mirrors:session.mirrors)
                    .id("\(session.generation)").ignoresSafeArea()
                if let frame=session.frame,session.firstFrameDrawn,session.message==nil {
                    RaceHUD(session:session,frame:frame,showStandings:showStandings,track:flow.plan.track?.name ?? content.name,car:flow.plan.car?.name ?? "",redline:content.carParameters.section("Engine")?.number("revs limiter",unit:"rpm",default:9000) ?? 9000)
                        .allowsHitTesting(false)
                }
                if !session.firstFrameDrawn && session.message==nil {
                    ZStack { GameBackdrop(map:nil);LoadingScreen(flow:flow,caption:"Preparing the circuit") }.transition(.opacity)
                }
                if let message=session.message { errorPanel(message) }
                else if flow.screen == .results { ResultsScreen(flow:flow) }
                else if let overlay=flow.overlay {
                    ZStack {
                        Color.black.opacity(0.7).ignoresSafeArea()
                        switch overlay {
                        case .settings: SettingsScreen(flow:flow,embedded:true)
                        case .controls: ControlsScreen(flow:flow,embedded:true)
                        }
                    }
                } else if pauseShown { PauseMenu(flow:flow) }
            }
        }
        .animation(.easeOut(duration:0.25),value:session.firstFrameDrawn)
        .onChange(of:session.firstFrameDrawn) { _,drawn in if drawn { flow.sessionReady() } }
        .onAppear { session.startTimer() }
        .onDisappear { session.stop() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didResignActiveNotification)) { _ in session.suspend() }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didResignKeyNotification)) { _ in session.suspend() }
    }
    private func errorPanel(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment:.leading,spacing:16) {
                Text("SESSION STOPPED").font(GameTheme.display(28)).foregroundStyle(GameTheme.bad)
                Text(message).font(GameTheme.mono(13,weight:.regular)).foregroundStyle(GameTheme.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                HStack { Spacer();Button("Main Menu") { flow.quitToMenu() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width:640).gamePanel(strong:true)
        }
    }
}

struct RaceHUD: View {
    let session: DrivingSession
    let frame: DrivingFrame
    let showStandings: Bool
    let track,car: String
    let redline: Float
    private var mine: RaceStanding? { frame.standings.first { $0.car==frame.viewer } }
    private var lapText: String {
        if frame.result != nil { return "\(frame.completedLaps.count) / \(frame.timing.targetLaps)" }
        if frame.phase == .prestart || frame.timing.laps==0 { return "— / \(frame.timing.targetLaps)" }
        return "\(min(frame.timing.laps,frame.timing.targetLaps)) / \(frame.timing.targetLaps)"
    }
    private var centreMessage: (String,Color)? {
        if frame.result != nil { return ("SESSION OVER",GameTheme.text) }
        if session.paused { return nil }
        if frame.raceTime<0.8 { return frame.phase == .prestart ? (frame.raceTime < -1 ? ("READY",GameTheme.warn):("SET",GameTheme.warn)):("GO!",GameTheme.good) }
        if let mine,mine.penalties>0 { return ("\(mine.penalties) PENALT\(mine.penalties==1 ? "Y":"IES") TO SERVE",GameTheme.bad) }
        if !frame.timing.commitBestLapTime,frame.timing.laps>0 { return ("LAP INVALID",GameTheme.bad) }
        if frame.behind { return ("CATCHING UP",GameTheme.warn) }
        return nil
    }
    var body: some View {
        ZStack {
            VStack {
                HStack(alignment:.top) {
                    // Session, lap and position.
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:8) {
                            Text(RaceFormat.kind(frame.configuration.kind).uppercased()).font(GameTheme.label(11,weight:.black)).tracking(1.5)
                                .padding(.vertical,4).padding(.horizontal,8).background(Capsule().fill(GameTheme.accent)).foregroundStyle(.white)
                            Text("\(track)\(car.isEmpty ? "":" · \(car)")").font(GameTheme.label(12,weight:.semibold)).foregroundStyle(GameTheme.textSecondary)
                        }
                        HStack(alignment:.firstTextBaseline,spacing:18) {
                            VStack(alignment:.leading,spacing:0) {
                                Text("LAP").font(GameTheme.label(10,weight:.bold)).foregroundStyle(GameTheme.textSecondary).tracking(1.5)
                                Text(lapText).font(GameTheme.mono(26,weight:.bold)).foregroundStyle(GameTheme.text)
                            }
                            if let mine {
                                VStack(alignment:.leading,spacing:0) {
                                    Text("POSITION").font(GameTheme.label(10,weight:.bold)).foregroundStyle(GameTheme.textSecondary).tracking(1.5)
                                    Text("P\(mine.position)").font(GameTheme.mono(26,weight:.bold)).foregroundStyle(GameTheme.text)
                                        + Text(" / \(frame.standings.count)").font(GameTheme.mono(16)).foregroundStyle(GameTheme.textSecondary)
                                }
                            }
                        }
                    }.padding(14).gamePanel(strong:true)
                    Spacer()
                    // Timing.
                    VStack(alignment:.trailing,spacing:4) {
                        timeRow("CURRENT",frame.phase == .prestart ? 0:frame.timing.currentLapTime,large:true)
                        timeRow("LAST",frame.timing.lastLapTime)
                        timeRow("BEST",frame.timing.bestLapTime,tint:GameTheme.good)
                        if let mine,mine.penaltyTime>0 { Text(String(format:"Penalty +%.2f s",mine.penaltyTime)).font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.warn) }
                    }.padding(14).gamePanel(strong:true)
                }
                Spacer()
                HStack(alignment:.bottom) {
                    if showStandings,!frame.standings.isEmpty { StandingsPanel(frame:frame) }
                    Spacer()
                    SpeedGauge(speed:frame.speed,rpm:frame.rpm,redline:redline,gear:frame.gear,requestedGear:session.requestedGear,fuel:frame.fuel,damage:frame.damage)
                }
            }.padding(20)
            if let (text,tint)=centreMessage {
                Text(text).font(GameTheme.display(text.count>6 ? 34:64)).foregroundStyle(tint)
                    .shadow(color:.black.opacity(0.7),radius:12)
                    .padding(.horizontal,28).padding(.vertical,12)
                    .background(RoundedRectangle(cornerRadius:16,style:.continuous).fill(.black.opacity(0.45)))
                    .offset(y:-120)
                    .transition(.scale.combined(with:.opacity))
            }
            if session.recording {
                HStack(spacing:6) { Circle().fill(GameTheme.bad).frame(width:8,height:8);Text("REC").font(GameTheme.label(11,weight:.black)).tracking(1) }
                    .foregroundStyle(GameTheme.text).padding(8).gamePanel(strong:true).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top).padding(.top,20)
            }
        }
    }
    private func timeRow(_ label: String,_ seconds: Double,large: Bool = false,tint: Color = GameTheme.text) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Text(label).font(GameTheme.label(10,weight:.bold)).foregroundStyle(GameTheme.textSecondary).tracking(1.5)
            Text(RaceFormat.lap(seconds)).font(GameTheme.mono(large ? 26:16,weight:.bold)).foregroundStyle(seconds>0 ? tint:GameTheme.textSecondary)
        }
    }
}

/// The live classification, as the original's crossing-time gaps: they move
/// as cars complete laps.
struct StandingsPanel: View {
    let frame: DrivingFrame
    private var rows: [RaceStanding] {
        let top=Array(frame.standings.prefix(8))
        if let mine=frame.standings.first(where:{ $0.car==frame.viewer }),!top.contains(where:{ $0.car==mine.car }) { return top+[mine] }
        return top
    }
    private func gap(_ s: RaceStanding) -> String {
        if s.position==1 { return "LEADER" }
        if s.lapsBehindLeader>0 { return "+\(s.lapsBehindLeader) LAP\(s.lapsBehindLeader==1 ? "":"S")" }
        return s.behindLeader>0 ? String(format:"+%.3f",s.behindLeader):"—"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:3) {
            ForEach(rows,id:\.car) { s in
                let mine=s.car==frame.viewer
                HStack(spacing:10) {
                    Text("\(s.position)").font(GameTheme.mono(13,weight:.bold)).frame(width:22,alignment:.trailing).foregroundStyle(mine ? .black:GameTheme.text)
                    Text(mine ? "YOU":RaceWeekend.defaultName(s.car).uppercased()).font(GameTheme.label(13,weight:.bold)).frame(width:54,alignment:.leading).foregroundStyle(mine ? .black:GameTheme.text)
                    Text(gap(s)).font(GameTheme.mono(12)).frame(width:78,alignment:.trailing).foregroundStyle(mine ? .black.opacity(0.7):GameTheme.textSecondary)
                    if s.inPits { tag("PIT",GameTheme.warn) }
                    if s.penalties>0 { tag("PEN",GameTheme.bad) }
                    if s.eliminated { tag("OUT",GameTheme.bad) } else if s.finished { tag("FIN",GameTheme.good) }
                }.padding(.vertical,4).padding(.horizontal,8)
                    .background(RoundedRectangle(cornerRadius:6).fill(mine ? GameTheme.accent:Color.white.opacity(0.04)))
            }
        }.padding(8).gamePanel(strong:true)
    }
    private func tag(_ text: String,_ tint: Color) -> some View {
        Text(text).font(GameTheme.label(9,weight:.black)).foregroundStyle(.white).padding(.vertical,2).padding(.horizontal,5).background(Capsule().fill(tint))
    }
}

struct SpeedGauge: View {
    let speed,rpm,redline: Float
    let gear,requestedGear: Int
    let fuel: Float
    let damage: Int32
    private var gearText: String { gear<0 ? "R":gear==0 ? "N":"\(gear)" }
    var body: some View {
        ZStack {
            Canvas { context,size in
                let centre=CGPoint(x:size.width/2,y:size.height/2),radius=min(size.width,size.height)/2-10
                let startAngle=Angle.degrees(135),endAngle=Angle.degrees(405)
                var track=Path();track.addArc(center:centre,radius:radius,startAngle:startAngle,endAngle:endAngle,clockwise:false)
                context.stroke(track,with:.color(.white.opacity(0.12)),style:StrokeStyle(lineWidth:10,lineCap:.round))
                let fraction=CGFloat(min(max(rpm/max(redline,1),0),1))
                var arc=Path();arc.addArc(center:centre,radius:radius,startAngle:startAngle,endAngle:startAngle+Angle.degrees(270*fraction),clockwise:false)
                let tint: Color = fraction>0.92 ? GameTheme.bad:fraction>0.8 ? GameTheme.warn:GameTheme.accent
                context.stroke(arc,with:.color(tint),style:StrokeStyle(lineWidth:10,lineCap:.round))
                // Redline mark at 90 percent.
                let mark=startAngle+Angle.degrees(270*0.9)
                var tick=Path()
                tick.move(to:CGPoint(x:centre.x+cos(mark.radians)*(radius-9),y:centre.y+sin(mark.radians)*(radius-9)))
                tick.addLine(to:CGPoint(x:centre.x+cos(mark.radians)*(radius+9),y:centre.y+sin(mark.radians)*(radius+9)))
                context.stroke(tick,with:.color(GameTheme.bad),lineWidth:3)
            }
            VStack(spacing:0) {
                Text("\(Int((speed*3.6).rounded()))").font(GameTheme.mono(46,weight:.black)).foregroundStyle(GameTheme.text).monospacedDigit()
                Text("KM/H").font(GameTheme.label(10,weight:.bold)).foregroundStyle(GameTheme.textSecondary).tracking(2)
                HStack(spacing:6) {
                    Text(gearText).font(GameTheme.mono(30,weight:.black)).foregroundStyle(GameTheme.accent)
                    if requestedGear != gear { Text("→\(requestedGear<0 ? "R":requestedGear==0 ? "N":"\(requestedGear)")").font(GameTheme.mono(14)).foregroundStyle(GameTheme.textSecondary) }
                }.padding(.top,4)
                Text("\(Int(rpm)) rpm").font(GameTheme.mono(11)).foregroundStyle(GameTheme.textSecondary)
            }
            VStack(spacing:4) {
                bar("FUEL",value:Double(min(max(fuel/100,0),1)),tint:GameTheme.good)
                bar("DAMAGE",value:Double(min(max(Double(damage)/10000,0),1)),tint:GameTheme.bad)
            }.frame(width:120).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom).padding(.bottom,2)
        }.frame(width:210,height:210).padding(6).background(Circle().fill(.black.opacity(0.35)))
    }
    private func bar(_ label: String,value: Double,tint: Color) -> some View {
        HStack(spacing:6) {
            Text(label).font(GameTheme.label(8,weight:.black)).foregroundStyle(GameTheme.textSecondary).frame(width:40,alignment:.trailing)
            GeometryReader { g in
                ZStack(alignment:.leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(tint).frame(width:g.size.width*value)
                }
            }.frame(height:5)
        }
    }
}

struct PauseMenu: View {
    let flow: GameFlow
    private var session: DrivingSession { flow.session }
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment:.leading,spacing:8) {
                Text("PAUSED").font(GameTheme.display(40)).foregroundStyle(GameTheme.text).padding(.bottom,2)
                Text("\(flow.plan.track?.name ?? "") · \(flow.plan.car?.name ?? "")").font(GameTheme.label(14,weight:.medium)).foregroundStyle(GameTheme.textSecondary).padding(.bottom,14)
                Button("Resume") { flow.resume() }.buttonStyle(MenuRowStyle()).keyboardShortcut(.cancelAction)
                Button("Restart Session") { flow.restartSession() }.buttonStyle(MenuRowStyle()).disabled(session.sessionBusy || session.captureBusy)
                HStack(spacing:10) {
                    Text("Camera").font(GameTheme.label(22,weight:.bold)).foregroundStyle(GameTheme.textSecondary).padding(.leading,18)
                    Spacer()
                    ArrowChooser(options:DrivingCameraPreset.allCases,selection:Binding(get:{ session.cameraPreset },set:{ session.selectCamera($0) }),title:{ $0.rawValue },width:200)
                    zoomButton("plus.magnifyingglass") { session.adjustCameraZoom(.zoomIn) }
                    zoomButton("minus.magnifyingglass") { session.adjustCameraZoom(.zoomOut) }
                    zoomButton("arrow.counterclockwise") { session.adjustCameraZoom(.reset) }
                }.padding(.vertical,6).padding(.trailing,12)
                Button("Settings") { flow.open(.settings) }.buttonStyle(MenuRowStyle())
                Button("Controls") { flow.open(.controls) }.buttonStyle(MenuRowStyle())
                if session.frame?.configuration.kind != .race {
                    Button(session.recording ? "Finish Telemetry Recording":"Record Telemetry…") {
                        if session.recording { session.finishRecording() } else { session.chooseCapture() }
                    }.buttonStyle(MenuRowStyle()).disabled(session.captureBusy || session.sessionBusy)
                }
                if (session.frame?.time ?? 0)>0 {
                    Button("End Session") { flow.endSession() }.buttonStyle(MenuRowStyle()).disabled(session.sessionBusy || session.captureBusy)
                }
                Button("Quit to Main Menu") { flow.quitToMenu() }.buttonStyle(MenuRowStyle())
                if let message=session.captureMessage ?? session.cameraMessage ?? session.inputMessage {
                    Text(message).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.warn).padding(.top,8)
                }
                Text("ESC resumes · click the track to focus if keys stop responding").font(GameTheme.label(11,weight:.medium)).foregroundStyle(GameTheme.textSecondary.opacity(0.7)).padding(.top,10)
            }.padding(28).frame(width:560).gamePanel(strong:true)
        }
    }
    private func zoomButton(_ symbol: String,action: @escaping ()->Void) -> some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:12,weight:.bold)).frame(width:28,height:28) }
            .buttonStyle(.plain).foregroundStyle(GameTheme.text).background(Circle().fill(Color.white.opacity(0.09)))
    }
}
