// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import MetalKit
import TORCSCore
import TORCSSimulation
import TORCSMetal
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
        if CommandLine.arguments.contains("--metal-smoke-test") {
            do {
                let bench=BenchSession()
                let renderer=try BenchRenderer(view:MTKView()) {
                    (bench.previous,bench.current,Float(bench.clock.interpolation))
                }
                print("Metal offscreen smoke test passed, RGB checksum: \(try renderer.offscreenChecksum())")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Metal smoke test failed: \(error)\n".utf8));exit(1)
            }
        }
        for flag in ["--car-light-visual-test","--car-light-benchmark"] {
            if let index=CommandLine.arguments.firstIndex(of:flag) {
                do {
                    guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: light diagnostic session-directory new-output-directory") }
                    try CarLightVisualSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]),measure:flag == "--car-light-benchmark");exit(0)
                } catch { fputs("Car light diagnostic failed: \(error)\n",stderr);exit(1) }
            }
        }
        for flag in ["--brake-visual-test","--brake-visual-benchmark"] {
            if let index=CommandLine.arguments.firstIndex(of:flag) {
                do {
                    guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: \(flag) session-directory new-output-directory") }
                    try BrakeVisualSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]),measure:flag == "--brake-visual-benchmark");exit(0)
                } catch { FileHandle.standardError.write(Data("Brake visual test failed: \(error)\n".utf8));exit(1) }
            }
        }
        for flag in ["--traffic-visual-test","--traffic-shadow-benchmark"] {
            if let index=CommandLine.arguments.firstIndex(of:flag) {
                do {
                    guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: \(flag) session-directory new-output-directory") }
                    try TrafficVisualSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]),measure:flag == "--traffic-shadow-benchmark");exit(0)
                } catch { FileHandle.standardError.write(Data("Traffic visual test failed: \(error)\n".utf8));exit(1) }
            }
        }
        for flag in ["--vegetation-visual-test","--vegetation-benchmark"] {
            if let index=CommandLine.arguments.firstIndex(of:flag) {
                do {
                    guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: \(flag) session-directory new-output-directory") }
                    try VegetationVisualSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]),measure:flag == "--vegetation-benchmark");exit(0)
                } catch { FileHandle.standardError.write(Data("Vegetation visual test failed: \(error)\n".utf8));exit(1) }
            }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--tv-visual-test") {
            do {
                guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: --tv-visual-test session-directory new-output-directory") }
                try TVVisualSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]));exit(0)
            } catch { FileHandle.standardError.write(Data("TV visual test failed: \(error)\n".utf8));exit(1) }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--fly-visual-test") {
            do {
                guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: --fly-visual-test session-directory new-output-directory") }
                try FlyVisualSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]));exit(0)
            } catch { FileHandle.standardError.write(Data("Fly visual test failed: \(error)\n".utf8));exit(1) }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--driving-visual-test") {
            do {
                guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: --driving-visual-test session-directory new-output-directory") }
                try DrivingVisualSmoke.run(session:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]));exit(0)
            } catch { FileHandle.standardError.write(Data("Driving visual test failed: \(error)\n".utf8));exit(1) }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--vehicle-scene-smoke-test") {
            do {
                guard CommandLine.arguments.count==index+4 else { throw RendererError.unavailable("Usage: --vehicle-scene-smoke-test scenes-directory fixtures-directory output.png") }
                try VehicleSceneSmoke.run(scenes:URL(fileURLWithPath:CommandLine.arguments[index+1]),fixtures:URL(fileURLWithPath:CommandLine.arguments[index+2]),output:URL(fileURLWithPath:CommandLine.arguments[index+3]))
                exit(0)
            } catch { FileHandle.standardError.write(Data("Vehicle scene failed: \(error)\n".utf8));exit(1) }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--scene-smoke-test") {
            do {
                guard CommandLine.arguments.count==index+3 else { throw RendererError.unavailable("Usage: --scene-smoke-test scene-directory output.png") }
                try SceneSmoke.run(directory:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]))
                exit(0)
            } catch { FileHandle.standardError.write(Data("Scene smoke failed: \(error)\n".utf8));exit(1) }
        }
        // Run file-based diagnostics before AppKit routes file arguments to its
        // open-document lifecycle; that path need not create a WindowGroup view.
        if let index=CommandLine.arguments.firstIndex(of:"--texture-smoke-test") {
            do {
                let files=CommandLine.arguments.dropFirst(index+1).map { URL(fileURLWithPath:$0) }
                let bytes=try MetalTextureUpload.verifyCaches(files)
                print("Metal texture upload passed, files: \(files.count), RGBA bytes: \(bytes)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Texture smoke test failed: \(error)\n".utf8));exit(1)
            }
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
                    .accessibilityLabel("Animated suspension component inspection")
                if let error { Text(error).padding().background(.regularMaterial).padding() }
                else { Text("Forced suspension travel • interpolated immutable snapshots")
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

struct MetalBench: NSViewRepresentable {
    let session: BenchSession
    let rate: Int
    @Binding var error: String?
    final class Coordinator { var renderer: BenchRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> InputMetalView {
        let view = InputMetalView(); view.session = session; view.preferredFramesPerSecond = rate
        do {
            context.coordinator.renderer = try BenchRenderer(view: view) {
                (session.previous, session.current, Float(session.clock.interpolation))
            }
        } catch {
            let message = "Metal initialization failed: \(error)"
            DispatchQueue.main.async { self.error = message }
            Logger(subsystem: "org.torcs.mac", category: "Renderer").error("\(message)")
        }
        return view
    }
    func updateNSView(_ view: InputMetalView, context: Context) { view.preferredFramesPerSecond = rate }
}
