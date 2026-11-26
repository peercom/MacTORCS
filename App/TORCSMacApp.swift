// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import ImageIO
import TORCSRaceEngine
import MetalKit
import TORCSCore
import TORCSSimulation
import TORCSPresentation
import TORCSRender
import os

@MainActor final class BenchSession {
    var clock = FixedStepClock()
    var bench = ComponentBench()
    var previous = SimulationSnapshot(tick: 0, suspensionTravel: 0.2, suspensionForce: 3000, steeringAngle: 0, brakeTemperature: 0)
    var current = SimulationSnapshot(tick: 0, suspensionTravel: 0.2, suspensionForce: 3000, steeringAngle: 0, brakeTemperature: 0)
    var paused = false
    var left = false, right = false, braking = false
    var timer: Timer?
    var lastWallTime = ProcessInfo.processInfo.systemUptime
    let signposter = OSSignposter(subsystem: "org.torcs.mac", category: "Simulation")
    func start() {
        guard timer == nil else { return }
        lastWallTime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func update() {
        let wall = ProcessInfo.processInfo.systemUptime, elapsed = wall - lastWallTime
        lastWallTime = wall
        guard !paused else { return }
        // OS sleep/focus changes are explicit pauses, never thousands of catch-up steps.
        guard elapsed < 1 else { return }
        let interval = signposter.beginInterval("Simulation tick batch")
        clock.advance(elapsed: elapsed) { tick in
            previous = current
            current = bench.step(tick: tick, steeringCommand: (left ? 1 : 0) - (right ? 1 : 0), brakeCommand: braking ? 1 : 0)
        }
        signposter.endInterval("Simulation tick batch", interval)
    }
    func releaseInput() { left = false; right = false; braking = false }
}

@MainActor final class DrivingApplicationDelegate: NSObject,NSApplicationDelegate {
    var session: DrivingSession?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate:await session.prepareToQuit()) }
        return .terminateLater
    }
}

@main struct TORCSMacApp: App {
    @NSApplicationDelegateAdaptor(DrivingApplicationDelegate.self) private var applicationDelegate
    @State private var session = BenchSession()
    @State private var sceneSession = SceneInspectionSession()
    @State private var flow: GameFlow
    @Environment(\.openWindow) private var openWindow
    init() {
        GamePreview.runIfRequested()
        GamePreview.costIfRequested()
        if let index=CommandLine.arguments.firstIndex(of:"--modern-race-test") {
            do {
                guard CommandLine.arguments.count>=index+3 else { throw RenderError.unavailable("Usage: --modern-race-test session-directory new-output-directory [cars]") }
                let cars=CommandLine.arguments.count>index+3 ? Int(CommandLine.arguments[index+3]) ?? 3:3
                try ModernTrafficSmoke.race(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),
                    output:URL(fileURLWithPath:CommandLine.arguments[index+2]),cars:cars);exit(0)
            } catch { FileHandle.standardError.write(Data("torcs: \(error)\n".utf8));exit(2) }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--modern-traffic-test") {
            do {
                guard CommandLine.arguments.count>=index+3 else { throw RenderError.unavailable("Usage: --modern-traffic-test session-directory new-output-directory [cars]") }
                let cars=CommandLine.arguments.count>index+3 ? Int(CommandLine.arguments[index+3]) ?? 3:3
                try ModernTrafficSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),
                    output:URL(fileURLWithPath:CommandLine.arguments[index+2]),cars:cars);exit(0)
            } catch { FileHandle.standardError.write(Data("torcs: \(error)\n".utf8));exit(2) }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--modern-driving-test") {
            do {
                guard CommandLine.arguments.count==index+3 else { throw RenderError.unavailable("Usage: --modern-driving-test session-directory new-output-directory") }
                try ModernDrivingSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]));exit(0)
            } catch { FileHandle.standardError.write(Data(String(describing:error).utf8));exit(1) }
        }
        _flow=State(initialValue:GameFlow(session:DrivingSession()))
    }
    var body: some Scene {
        Window("TORCS",id:"game") {
            GameShell(flow:flow)
                .onAppear { applicationDelegate.session=flow.session }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width:1440,height:900)
        .commands {
            CommandGroup(replacing:.appSettings) {
                Button("Settings…") { flow.open(.settings) }.keyboardShortcut(",")
            }
            CommandGroup(after:.newItem) {
                Button("Add Content Folder…") { flow.addContentFolder() }.keyboardShortcut("o",modifiers:[.command,.shift])
            }
            CommandMenu("Game") {
                Button("Main Menu") { flow.quitToMenu() }.keyboardShortcut("m",modifiers:[.command,.shift])
                    .disabled(flow.screen == .menu)
                Button("Pause / Resume") { flow.session.togglePause() }
                    .keyboardShortcut("p",modifiers:[.command,.shift]).disabled(flow.session.content==nil)
                Button("Next Camera") { flow.session.cycleCamera() }.keyboardShortcut("v",modifiers:[.command]).disabled(flow.session.content==nil)
                Divider()
                Button("Controls…") { flow.open(.controls) }
            }
            CommandMenu("Developer") {
                Button("Open Compiled Scene…") { sceneSession.choose { openWindow(id:"scene-inspector") } }
                Button("Open Component Lab") { openWindow(id:"component-lab") }
                Button("Pause / Resume Component Lab") { session.paused.toggle() }
            }
        }
        Window("TORCS Scene Inspector",id:"scene-inspector") { SceneInspectorScreen(session:sceneSession) }
        Window("TORCS Mac — Component Lab",id:"component-lab") { BenchScreen(session:session).frame(minWidth:780,minHeight:520) }
    }
}

/// One window, every screen: the backdrop, then whichever screen the flow is
/// on. The driving screen stays mounted through the results so the renderer
/// is not rebuilt for the sheet over it.
struct GameShell: View {
    let flow: GameFlow
    var body: some View {
        content
            .task { await ScreenshotSupport.runIfRequested(flow:flow) { AnyView(content) } }
    }
    private var content: some View {
        ZStack {
            if flow.screen == .driving || flow.screen == .results { RaceScreen(flow:flow) }
            else {
                GameBackdrop(map:flow.plan.track?.map)
                switch flow.screen {
                case .menu: MainMenuScreen(flow:flow)
                case .trackSelect: TrackSelectScreen(flow:flow)
                case .carSelect: CarSelectScreen(flow:flow)
                case .options: SessionOptionsScreen(flow:flow)
                case .loading: LoadingScreen(flow:flow)
                case .settings: SettingsScreen(flow:flow)
                case .controls: ControlsScreen(flow:flow)
                case .about: AboutScreen(flow:flow)
                case .championship: ChampionshipScreen(flow:flow)
                case .championshipSetup: ChampionshipSetupScreen(flow:flow)
                case .driving,.results: EmptyView()
                }
            }
        }
        .frame(minWidth:1100,minHeight:700)
        .preferredColorScheme(.dark)
        .tint(GameTheme.accent)
        .animation(.easeInOut(duration:0.2),value:flow.screen)
    }
}

/// `--render-icon PATH`: the application icon as a 1024-pixel PNG, for
/// Scripts/build-app.sh to turn into the icon set.
///
/// `--autoplay SECONDS`: start a training session on the first pairing in
/// the library through the real window path, drive nothing, and quit with
/// status 0 once the session has started and its clock has run, or 1 if it
/// has not within the time given. `--autoplay-race` adds opponents.
///
/// `--screenshot PATH [--size WxH] [--backdrop PNG]`: render the shell to a
/// PNG once the content scan is done, then quit. For `--screen hud` the
/// session's first frame is loaded and the HUD and pause menu are drawn over
/// the backdrop image, since the renderer itself cannot be drawn this way.
@MainActor enum ScreenshotSupport {
    /// `--autoplay-season`: a one-round, one-lap championship with the robot
    /// policy driving the player's car as well, through the real window: the
    /// race runs to its finish, the results come up, the round goes into the
    /// table and the season is saved. Status 0 when all of that happened.
    static func autoplaySeason(flow: GameFlow,seconds: Double) async {
        guard flow.championship==nil else { FileHandle.standardError.write(Data("autoplay: a championship is in progress; not replacing it\n".utf8));exit(1) }
        flow.openChampionship()
        guard let car=flow.plan.car else { FileHandle.standardError.write(Data("autoplay: no car\n".utf8));exit(1) }
        flow.selectCar(car)
        flow.seasonRounds=1;flow.plan.laps=1;flow.plan.opponents=2;flow.plan.difficulty = .hard
        flow.startSeason()
        guard let season=flow.championship else { FileHandle.standardError.write(Data("autoplay: season not created: \(flow.message ?? "")\n".utf8));exit(1) }
        print("autoplay: season entrants=\(season.entrants.map { "\($0.name)/\($0.car)" }) round1=\(season.rounds[0].track) grid=\(season.grid)")
        flow.session.autopilot=true
        flow.startSeasonRound()
        let deadline=Date().addingTimeInterval(seconds)
        while Date()<deadline {
            try? await Task.sleep(for:.milliseconds(200))
            if flow.session.paused,flow.sessionStarted,flow.session.frame?.result==nil { flow.session.togglePause() }
            if flow.screen == .results,let done=flow.championship {
                let race=flow.session.lastRaceResult
                print("autoplay: results reason=\(race.map { "\($0.reason)" } ?? "none") classification=\(race?.classification.map { flow.session.driverName($0) } ?? []) elapsed=\(String(format:"%.1f",race?.elapsed ?? 0))")
                print("autoplay: table=\(done.standings.map { "\(done.entrants[$0.entrant].name):\($0.points)" }) complete=\(done.isComplete) champion=\(done.champion.map { done.entrants[$0].name } ?? "none") frameRate=\(flow.session.frameRate)")
                let recorded=done.roundsRun==1
                flow.showSeason()
                print("autoplay: season screen=\(flow.screen)")
                flow.abandonSeason()
                exit(recorded ? 0:1)
            }
            if let message=flow.session.message { FileHandle.standardError.write(Data("autoplay: \(message)\n".utf8));flow.abandonSeason();exit(1) }
        }
        FileHandle.standardError.write(Data("autoplay: season timed out screen=\(flow.screen) time=\(flow.session.frame?.time ?? -1) laps=\(flow.session.frame?.standings.map(\.laps) ?? [])\n".utf8))
        flow.abandonSeason();exit(1)
    }
    static func autoplay(flow: GameFlow,seconds: Double) async {
        while flow.scanning { try? await Task.sleep(for:.milliseconds(50)) }
        guard flow.ready else { FileHandle.standardError.write(Data("autoplay: no content\n".utf8));exit(1) }
        if !CommandLine.arguments.contains("--sound") { GameAudio.shared.volume=0 }
        if CommandLine.arguments.contains("--autoplay-season") { await autoplaySeason(flow:flow,seconds:seconds);return }
        // A check, not a performance: silent unless asked for sound.
        if !CommandLine.arguments.contains("--sound") { GameAudio.shared.volume=0 }
        flow.choose(CommandLine.arguments.contains("--autoplay-race") ? .race:.practice)
        flow.plan.laps=2;flow.plan.opponents=2
        if let index=CommandLine.arguments.firstIndex(of:"--autoplay-cars"),index+1<CommandLine.arguments.count,let cars=Int(CommandLine.arguments[index+1]) { flow.plan.opponents=max(0,cars-1) }
        let measure=CommandLine.arguments.firstIndex(of:"--autoplay-measure").flatMap { $0+1<CommandLine.arguments.count ? Double(CommandLine.arguments[$0+1]):nil } ?? 0
        if let index=CommandLine.arguments.firstIndex(of:"--window"),index+1<CommandLine.arguments.count {
            let parts=CommandLine.arguments[index+1].split(separator:"x").compactMap { Double($0) }
            if parts.count==2,let window=NSApp.windows.first(where:{ $0.contentView != nil && $0.isVisible }) {
                window.setContentSize(NSSize(width:parts[0],height:parts[1]))
            }
        }
        if CommandLine.arguments.contains("--fullscreen"),let window=NSApp.windows.first(where:{ $0.contentView != nil && $0.isVisible }),
           !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            try? await Task.sleep(for:.seconds(2))
        }
        flow.startSession()
        let deadline=Date().addingTimeInterval(seconds)
        var started: Date?
        while Date()<deadline {
            try? await Task.sleep(for:.milliseconds(100))
            if let message=flow.session.message ?? flow.message { FileHandle.standardError.write(Data("autoplay: \(message)\n".utf8));exit(1) }
            // A measurement outlasts a lost focus: the session is sent on again.
            if measure>0,flow.sessionStarted,flow.session.paused,flow.session.frame?.result==nil { flow.session.togglePause() }
            if flow.sessionStarted,started==nil { started=Date();print("autoplay: started after \(String(format:"%.1f",Date().timeIntervalSince(deadline)+seconds)) s, screen=\(flow.screen)") }
            if let frame=flow.session.frame,frame.time>2+measure,!flow.session.paused {
                if FrameLog.enabled { print(FrameLog.report()) }
                if ProcessInfo.processInfo.environment["TORCS_PASS_LOG"] != nil { print(FrameLog.passReport()) }
                if measure>0 { print("autoplay: frameRate=\(flow.session.frameRate) drawMilliseconds=\(String(format:"%.2f",flow.session.drawMilliseconds)) gpuMilliseconds=\(String(format:"%.2f",flow.session.gpuMilliseconds)) scale=\(flow.session.renderScale) quality=\(flow.session.qualityMode)/\(flow.session.renderPreset.rawValue)@\(flow.session.qualityLevel.renderScale) cars=\(frame.field.count) models=\(flow.session.content?.models.count ?? 0)") }
                print("autoplay: ok screen=\(flow.screen) time=\(String(format:"%.2f",frame.time)) raceTime=\(String(format:"%.2f",frame.raceTime)) phase=\(frame.phase) field=\(frame.field.count) standings=\(frame.standings.count) firstFrame=\(flow.session.firstFrameDrawn)")
                print("autoplay: \(GameAudio.shared.status)")
                flow.session.togglePause()
                print("autoplay: paused=\(flow.session.paused)")
                flow.quitToMenu()
                print("autoplay: menu screen=\(flow.screen) content=\(flow.session.content==nil ? "unloaded":"loaded")")
                exit(0)
            }
        }
        FileHandle.standardError.write(Data("autoplay: timed out screen=\(flow.screen) started=\(flow.sessionStarted) firstFrame=\(flow.session.firstFrameDrawn) paused=\(flow.session.paused) time=\(flow.session.frame?.time ?? -1)\n".utf8))
        exit(1)
    }
    static func runIfRequested(flow: GameFlow,content: @escaping @MainActor ()->AnyView) async {
        let arguments=CommandLine.arguments
        if let index=arguments.firstIndex(of:"--autoplay"),index+1<arguments.count,let seconds=Double(arguments[index+1]) {
            await autoplay(flow:flow,seconds:seconds);return
        }
        if let index=arguments.firstIndex(of:"--render-icon"),index+1<arguments.count {
            let renderer=ImageRenderer(content:AppIconArt().environment(\.colorScheme,.dark));renderer.scale=1
            guard let image=renderer.cgImage,let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:arguments[index+1]) as CFURL,"public.png" as CFString,1,nil) else { exit(2) }
            CGImageDestinationAddImage(destination,image,nil);exit(CGImageDestinationFinalize(destination) ? 0:2)
        }
        guard let index=arguments.firstIndex(of:"--screenshot"),index+1<arguments.count else { return }
        let output=URL(fileURLWithPath:arguments[index+1])
        var size=CGSize(width:1440,height:900)
        if let s=arguments.firstIndex(of:"--size"),s+1<arguments.count {
            let parts=arguments[s+1].split(separator:"x").compactMap { Double($0) }
            if parts.count==2 { size=CGSize(width:parts[0],height:parts[1]) }
        }
        let backdrop=arguments.firstIndex(of:"--backdrop").flatMap { $0+1<arguments.count ? NSImage(contentsOfFile:arguments[$0+1]):nil }
        while flow.scanning { try? await Task.sleep(for:.milliseconds(50)) }
        let screen=arguments.firstIndex(of:"--screen").flatMap { $0+1<arguments.count ? arguments[$0+1]:nil }
        let view: AnyView
        if screen=="pausemenu" {
            view=AnyView(ZStack { GameBackdrop(map:nil);PauseMenu(flow:flow) }.frame(width:size.width,height:size.height))
        } else if screen=="hud",let track=flow.plan.track,let car=flow.plan.car {
            flow.session.selectedSessionKind=flow.plan.kind;flow.session.selectedLaps=flow.plan.laps;flow.session.selectedCars=flow.plan.cars
            flow.session.weekend=(try? RaceWeekend(cars:flow.plan.cars)) ?? flow.session.weekend
            guard await flow.session.load(track:track.directory,car:car.directory),let frame=flow.session.frame,let loaded=flow.session.content else {
                FileHandle.standardError.write(Data("torcs: \(flow.session.message ?? "no frame")\n".utf8));exit(2)
            }
            let paused=arguments.contains("--paused")
            view=AnyView(ZStack {
                if let backdrop { Image(nsImage:backdrop).resizable().aspectRatio(contentMode:.fill) } else { GameBackdrop(map:nil) }
                RaceHUD(session:flow.session,frame:frame,showStandings:true,track:track.name,car:car.name,
                        redline:loaded.carParameters.section("Engine")?.number("revs limiter",unit:"rpm",default:9000) ?? 9000)
                if paused { PauseMenu(flow:flow) }
            }.frame(width:size.width,height:size.height).clipped())
        } else {
            view=AnyView(content().frame(width:size.width,height:size.height))
        }
        let renderer=ImageRenderer(content:view.preferredColorScheme(.dark).environment(\.colorScheme,.dark))
        renderer.scale=2
        guard let image=renderer.cgImage,let destination=CGImageDestinationCreateWithURL(output as CFURL,"public.png" as CFString,1,nil) else {
            FileHandle.standardError.write(Data("torcs: screenshot could not be rendered\n".utf8));exit(2)
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { exit(2) }
        print("screenshot \(output.path) \(image.width)x\(image.height)")
        exit(0)
    }
}

struct BenchScreen: View {
    let session: BenchSession
    @State private var error: String?
    @AppStorage("renderRate") private var renderRate = 60
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 18) {
                Label("TORCS Mac", systemImage: "steeringwheel").font(.title2.bold())
                Text("COMPONENT LAB").font(.caption).foregroundStyle(.secondary)
                Text("Suspension, brakes & steering").font(.headline)
                Text("Native Swift components tested against TORCS 1.3.9. This inspection scene is not a drivable car.")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Simulation", value: String(format: "%.3f s", session.clock.time))
                        LabeledContent("Fixed step", value: "2 ms / 500 Hz")
                        LabeledContent("Travel", value: String(format: "%.4f m", session.current.suspensionTravel))
                        LabeledContent("Spring force", value: String(format: "%.0f N", session.current.suspensionForce))
                        LabeledContent("Steering", value: String(format: "%.3f rad", session.current.steeringAngle))
                        LabeledContent("Brake heat", value: String(format: "%.3f", session.current.brakeTemperature))
                        Text(session.paused ? "Paused" : "Running").foregroundStyle(session.paused ? .secondary : .primary)
                    }.font(.system(.caption, design: .monospaced))
                }
                Spacer()
                Text("Click the scene to focus.\n← → steering • Space brake\n⌘P pause / resume")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(minWidth: 270, idealWidth: 300, maxWidth: 360)
            ZStack(alignment: .bottomLeading) {
                MetalBench(session: session, rate: renderRate, error: $error)
                    .accessibilityLabel("Suspension bench input surface")
                if let error { Text(error).padding().background(.regularMaterial).padding() }
                else { Text("Forced suspension travel • readouts at left; the animated view retired with the classic renderer")
                    .font(.caption).padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6)).padding() }
            }
        }
        .onAppear { session.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in session.releaseInput() }
    }
}

@MainActor final class InputMetalView: MTKView {
    var session: BenchSession?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) { set(event, pressed: true) }
    override func keyUp(with event: NSEvent) { set(event, pressed: false) }
    override func resignFirstResponder() -> Bool { session?.releaseInput(); return super.resignFirstResponder() }
    private func set(_ event: NSEvent, pressed: Bool) {
        switch event.keyCode {
        case 123: session?.left = pressed
        case 124: session?.right = pressed
        case 49: session?.braking = pressed
        default: if pressed { super.keyDown(with: event) } else { super.keyUp(with: event) }
        }
    }
}

/// The suspension bench's input surface. Its animated component view went
/// with the classic renderer; the physics readouts beside it are the bench.
struct MetalBench: NSViewRepresentable {
    let session: BenchSession
    let rate: Int
    @Binding var error: String?
    func makeNSView(context: Context) -> InputMetalView {
        let view = InputMetalView(); view.session = session; view.preferredFramesPerSecond = rate
        view.clearColor = MTLClearColor(red: 0.16, green: 0.22, blue: 0.29, alpha: 1)
        view.device = MTLCreateSystemDefaultDevice()
        return view
    }
    func updateNSView(_ view: InputMetalView, context: Context) { view.preferredFramesPerSecond = rate }
}
