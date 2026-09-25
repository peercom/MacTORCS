// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
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
    @State private var drivingSession = DrivingSession()
    @Environment(\.openWindow) private var openWindow
    init() {
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
    }
    var body: some Scene {
        Window("TORCS Driving",id:"driving") {
            DrivingScreen(session:drivingSession)
                .onAppear { applicationDelegate.session=drivingSession }
        }
        .defaultSize(width:1200,height:800)
        .commands {
            CommandGroup(after:.newItem) {
                Button("Open Driving Session…") {
                    drivingSession.choose { openWindow(id:"driving") }
                }.keyboardShortcut("o",modifiers:[.command,.shift])
                Button("Open Compiled Scene…") {
                    sceneSession.choose { openWindow(id:"scene-inspector") }
                }.keyboardShortcut("o")
            }
            CommandMenu("Simulation") {
                Button("Pause / Resume Driving") { drivingSession.togglePause() }
                    .keyboardShortcut("p",modifiers:[.command,.shift]).disabled(drivingSession.content==nil)
                Button("Pause / Resume Component Lab") { session.paused.toggle() }.keyboardShortcut("p")
                Divider()
                Button("Open Component Lab") { openWindow(id:"component-lab") }
            }
        }
        Window("TORCS Scene Inspector",id:"scene-inspector") { SceneInspectorScreen(session:sceneSession) }
        Window("TORCS Mac — Component Lab",id:"component-lab") { BenchScreen(session:session).frame(minWidth:780,minHeight:520) }
        Settings { SettingsScreen(drivingSession:drivingSession) }
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

struct SettingsScreen: View {
    let drivingSession:DrivingSession
    @State private var showControls=false
    @AppStorage("renderRate") private var renderRate = 60
    var body: some View {
        Form {
            Picker("Render rate", selection: $renderRate) { Text("60 Hz").tag(60); Text("120 Hz").tag(120) }
            Text("Physics remains at 500 Hz. The display determines the available presentation rate.").font(.caption).foregroundStyle(.secondary)
            Button("Driving Controls…") { drivingSession.suspend();showControls=true }
        }.padding(24).frame(width: 420)
            .sheet(isPresented:$showControls) { DrivingControlsEditor(session:drivingSession) }
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
