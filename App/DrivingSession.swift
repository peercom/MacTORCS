// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import MetalKit
import Observation
import TORCSSimulation
import TORCSRaceEngine
import TORCSTelemetry
import TORCSPresentation
import TORCSRender
import TORCSInput
import os

private actor DrivingWorker {
    /// A window session is either the single-car practice runtime or a race.
    /// Both publish the same frame, so presentation has one path.
    private enum Runtime {
        case solo(DrivingRuntime)
        case race(RaceRuntime)
        var frame: DrivingFrame {
            switch self { case .solo(let r): return r.frame; case .race(let r): return r.frame }
        }
        var isRace: Bool { if case .race = self { return true };return false }
    }
    private var runtime: Runtime
    private var capture: TelemetryWriter?
    private let signposter=OSSignposter(subsystem:"org.torcs.mac",category:"Driving simulation")
    init(_ simulation: SingleVehicleSimulation,configuration: RaceSessionConfiguration) throws {
        runtime = .solo(try DrivingRuntime(simulation:simulation,configuration:configuration))
    }
    init(race: RaceRuntime) { runtime = .race(race) }
    func endSession() throws -> DrivingFrame {
        switch runtime {
        case .solo(var r): r.endSession();runtime = .solo(r)
        case .race(var r): r.endRace();runtime = .race(r)
        }
        try finishCapture();return runtime.frame
    }
    func startCapture(_ destination: URL) throws {
        guard capture==nil else { throw TelemetryError.invalid("A telemetry capture is already running") }
        guard case .solo(let r)=runtime else {
            throw TelemetryError.invalid("Telemetry capture is available in practice and qualifying, not a race")
        }
        let writer=try TelemetryWriter(to:destination)
        try writer.append(DrivingTelemetry.record(r.simulation,timing:r.timing,raceTime:r.raceTime))
        capture=writer
    }
    func finishCapture() throws {
        guard let writer=capture else { return }
        defer { capture=nil }
        try writer.finish()
    }
    func advance(elapsed: Double,command: DriverCommand,paused: Bool) throws -> DrivingFrame {
        let interval=signposter.beginInterval("Driving fixed-step batch")
        defer { signposter.endInterval("Driving fixed-step batch",interval) }
        let writer=capture
        do {
            switch runtime {
            case .solo(var r):
                try r.advance(elapsed:elapsed,command:command,paused:paused,didStep:writer.map { writer in
                    { simulation,timing,time in try writer.append(DrivingTelemetry.record(simulation,timing:timing,raceTime:time)) }
                })
                runtime = .solo(r)
            case .race(var r):
                try r.advance(elapsed:elapsed,humanCommand:command,paused:paused)
                runtime = .race(r)
            }
        } catch { capture=nil;throw error } // Failed capture never publishes a partial JSON line.
        if runtime.frame.result != nil { try finishCapture() }
        return runtime.frame
    }
}
@MainActor @Observable final class DrivingSession {
    var content: DrivingContent?
    /// Where the loaded session lives; generated materials are looked for beside it.
    var contentDirectory: URL?
    var frame: DrivingFrame?
    var loading=false
    var selectedSessionKind: RaceSessionKind = .practice
    var selectedLaps=5
    /// Cars in a race, the human included. Practice and qualifying run alone.
    var selectedCars=3
    /// How the grid is ordered, and the qualifying ranking built so far.
    var weekend=try! RaceWeekend(cars:3)
    var sessionBusy=false
    var lastResult: DrivingSessionResult?
    var lastRaceResult: RaceResult?
    var paused=true
    var cameraPreferences=CameraPreferences()
    var cameraPreset: DrivingCameraPreset = .chase
    var cameraZoom:Float = DrivingCameraPreset.chase.zoomLimits.standard
    var cameraMessage:String?
    func selectCamera(_ preset:DrivingCameraPreset) { cameraPreferences.select(preset);cameraPreset=preset;cameraZoom=cameraPreferences.zoom(for:preset);saveCameraPreferences() }
    func adjustCameraZoom(_ command:CameraZoomCommand) {
        do { try cameraPreferences.adjust(command,for:cameraPreset);cameraZoom=cameraPreferences.zoom(for:cameraPreset);saveCameraPreferences() }
        catch { cameraMessage="Camera zoom could not be changed: \(error)" }
    }
    private func saveCameraPreferences() {
        do { try CameraPreferencesStore().save(cameraPreferences);cameraMessage=nil }
        catch { cameraMessage="Camera settings could not be saved: \(error)" }
    }
    var mirrors=UserDefaults.standard.object(forKey:"mirrors") as? Bool ?? true
    /// Wet track: darkened, glossy road with puddles and spray. A visual
    /// condition only; the physics stays dry until the simulation has weather.
    var wet=false
    /// Rain: wet track plus streaks and a dim sky. Visual only, like `wet`.
    var rain=false
    /// Overcast: a cloud layer covers the sky and the sun is dimmed. Visual only.
    var overcast=false
    /// The renderer has produced its first frame of this run: the loading
    /// screen can go and the countdown can start.
    var firstFrameDrawn=false
    /// The quality preset the next renderer is built with.
    var renderPreset: RenderSettings.Preset = RenderSettings.Preset(rawValue:UserDefaults.standard.string(forKey:"renderPreset") ?? "") ?? .m2Air
    /// The driving views in the order the camera key steps through them.
    static let cameraCycle: [DrivingCameraPreset]=[.chase,.near,.far,.low,.bonnet,.driver,.road,.trackAligned,.television]
    func cycleCamera() {
        let index=Self.cameraCycle.firstIndex(of:cameraPreset) ?? -1
        selectCamera(Self.cameraCycle[(index+1)%Self.cameraCycle.count])
    }
    var message: String?
    var requestedGear=1
    var focusRequested=false
    var recording=false
    var captureBusy=false
    var captureMessage: String?
    var generation=UUID()
    @ObservationIgnored var input=DrivingInput()
    var controllerReady=false
    var controllerName:String?
    var inputMessage:String?
    @ObservationIgnored weak var drivingWindow:NSWindow?
    @ObservationIgnored private let controllers=GameControllerSource()
    init() {
        do { cameraPreferences=try CameraPreferencesStore().load();cameraPreset=cameraPreferences.selectedPreset;cameraZoom=cameraPreferences.zoom(for:cameraPreset) }
        catch { cameraMessage="Camera settings could not be loaded: \(error)" }
        do { try input.configure(InputConfigurationStore().load()) }
        catch { inputMessage="Input settings could not be loaded: \(error)" }
        controllers.onButtonChange={ [weak self] element,pressed in
            guard let self else { return }
            if let action=self.input.controllerButton(element,pressed:pressed,acceptInput:self.acceptsController) { self.perform(action) }
        }
    }
    var acceptsController:Bool { NSApp.isActive && drivingWindow?.isKeyWindow==true && drivingWindow?.firstResponder is DrivingMetalNSView }
    func saveInput(_ configuration:InputConfiguration) throws {
        try InputConfigurationStore().save(configuration)
        suspend();try input.configure(configuration);inputMessage=nil
    }
    @ObservationIgnored private var worker: DrivingWorker?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending=false
    @ObservationIgnored private var lastWall=ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var captureTask: Task<Void,Never>?
    /// Practice and qualifying keep the single-car runtime; a race builds the
    /// authoritative race runtime with the human entry first on the grid.
    private func makeWorker(_ content: DrivingContent,configuration: RaceSessionConfiguration) throws -> (DrivingWorker,DrivingFrame) {
        guard configuration.kind == .race else {
            return (try DrivingWorker(content.simulation,configuration:configuration),
                    try DrivingRuntime(simulation:content.simulation,configuration:configuration).frame)
        }
        // The grid is the starting order applied to the field: the entry on each
        // slot from pole back. The human keeps its identity wherever it starts.
        let grid=try weekend.grid()
        let entries=grid.map { car in
            RaceEntry(parameters:content.carParameters,kind:car==0 ? .human:.bt,team:"bt",skillLevel:3)
        }
        let race=try RaceRuntime(road:content.simulation.road,entries:entries,grid:try .quickRace(),
                                 configuration:configuration)
        return (DrivingWorker(race:race),race.frame)
    }
    /// Load a prepared session folder and build its first run. False when it
    /// failed; `message` then says why.
    func load(_ directory: URL) async -> Bool {
        stop();generation=UUID();let token=generation
        content=nil;contentDirectory=nil;frame=nil;worker=nil;message=nil;loading=true;requestedGear=1
        firstFrameDrawn=false;finishedReported=false;lastResult=nil;lastRaceResult=nil
        do {
            let result=try await Task.detached(priority:.userInitiated) { try DrivingContent.load(directory) }.value
            guard generation==token else { return false }
            let configuration=try RaceSessionConfiguration(kind:selectedSessionKind,laps:selectedLaps)
            content=result;contentDirectory=directory
            let built=try makeWorker(result,configuration:configuration)
            worker=built.0;frame=built.1
            loading=false;return true
        } catch { guard generation==token else { return false };message=String(describing:error);loading=false;return false }
    }
    /// Leave the session: nothing loaded, nothing running.
    func unload() {
        stop();generation=UUID()
        content=nil;contentDirectory=nil;frame=nil;worker=nil;message=nil;loading=false
        lastResult=nil;lastRaceResult=nil;firstFrameDrawn=false;finishedReported=false;requestedGear=1
    }
    func restart() {
        guard let content,!sessionBusy,!captureBusy else { return }
        suspend();sessionBusy=true
        let oldWorker=worker,token=generation
        Task {
            defer { sessionBusy=false }
            do {
                if let oldWorker {
                    let ended=try await oldWorker.endSession()
                    guard generation==token else { return }
                    if ended.time>0 { lastResult=ended.result }
                }
                let configuration=try RaceSessionConfiguration(kind:selectedSessionKind,laps:selectedLaps)
                let built=try makeWorker(content,configuration:configuration)
                worker=built.0;frame=built.1
                generation=UUID();requestedGear=1;message=nil;recording=false;captureMessage=nil
                firstFrameDrawn=false;finishedReported=false
                lastWall=ProcessInfo.processInfo.systemUptime;startTimer()
            } catch { guard generation==token else { return };message="Could not start a new session: \(error)" }
        }
    }
    /// Whoever runs the game hears once per run that it is over, whether it
    /// finished, retired or was ended early.
    @ObservationIgnored var onFinished: ((DrivingFrame)->Void)?
    @ObservationIgnored private var finishedReported=false
    private func reportFinished(_ frame: DrivingFrame) {
        guard !finishedReported else { return }
        finishedReported=true;onFinished?(frame)
    }
    func endSession() {
        guard let worker,!sessionBusy,!captureBusy,frame?.result==nil else { return }
        suspend();sessionBusy=true;generation=UUID();let token=generation
        Task {
            defer { sessionBusy=false }
            do {
                let ended=try await worker.endSession()
                guard generation==token else { return }
                frame=ended;lastResult=ended.result;lastRaceResult=ended.raceResult;recording=false
                reportFinished(ended)
            } catch { guard generation==token else { return };message="Could not finish session: \(error)" }
        }
    }
    func exportResults(_ result: DrivingSessionResult) {
        suspend()
        let panel=NSSavePanel();panel.nameFieldStringValue="TORCS-results.json"
        panel.message="Save this session’s lap times and result."
        let completion: (NSApplication.ModalResponse)->Void = { [weak self] response in
            guard response == .OK,let url=panel.url else { return }
            do { try result.save(to:url);self?.captureMessage="Results saved to \(url.lastPathComponent)." }
            catch { self?.captureMessage="Results could not be saved: \(error)" }
        }
        if let window=NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    func startTimer() {
        guard timer==nil else { return }
        lastWall=ProcessInfo.processInfo.systemUptime
        timer=Timer.scheduledTimer(withTimeInterval:1/120,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
    }
    func togglePause() {
        guard worker != nil,message==nil,!captureBusy,!sessionBusy,frame?.result==nil else { return }
        paused.toggle();releaseInput();lastWall=ProcessInfo.processInfo.systemUptime
        if !paused { focusRequested=true;startTimer() }
    }
    func releaseInput() { input.releaseAll();if controllerReady { controllerReady=false } }
    func suspend() { paused=true;releaseInput();lastWall=ProcessInfo.processInfo.systemUptime }
    func stop() {
        suspend();timer?.invalidate();timer=nil
        finishRecording()
    }
    func chooseCapture() {
        guard !captureBusy,!recording,let worker else { return }
        suspend()
        let panel=NSSavePanel();panel.nameFieldStringValue="TORCS-driving.jsonl"
        panel.message="Record every simulation tick. Finish recording to save the telemetry file."
        let token=generation
        let completion: (NSApplication.ModalResponse)->Void = { [weak self] response in
            guard let self,response == .OK,let url=panel.url,self.generation==token else { return }
            self.captureBusy=true;self.captureMessage=nil
            self.captureTask=Task {
                defer { self.captureBusy=false }
                do {
                    try await worker.startCapture(url)
                    guard self.generation==token else { try await worker.finishCapture();return }
                    self.recording=true;self.captureMessage="Recording to \(url.lastPathComponent)"
                } catch { self.captureMessage="Telemetry: \(error)" }
            }
        }
        if let window=NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    func finishRecording() {
        guard recording || captureBusy,let worker else { return }
        recording=false;captureBusy=true
        let previousTask=captureTask
        captureTask=Task {
            await previousTask?.value
            recording=false
            do { try await worker.finishCapture();captureMessage="Telemetry saved." }
            catch { captureMessage="Telemetry could not be saved: \(error)" }
            captureBusy=false
        }
    }
    func prepareToQuit() async -> Bool {
        suspend()
        await captureTask?.value
        do { try await worker?.finishCapture();recording=false;return true }
        catch { captureMessage="Telemetry could not be saved: \(error)";recording=false;return false }
    }
    func update() {
        let device=controllers.poll();if controllerName != controllers.name { controllerName=controllers.name }
        if device.changed { suspend() }
        _=input.updateController(device.sample,acceptInput:acceptsController,detectEdges:false)
        if controllerReady != input.controllerReady { controllerReady=input.controllerReady }
        guard !pending,let worker else { return }
        let now=ProcessInfo.processInfo.systemUptime,elapsed=now-lastWall;lastWall=now
        guard !paused,!sessionBusy else { return }
        guard elapsed>=0,elapsed<1 else { suspend();return }
        let command=input.command(gear:requestedGear,speed:frame?.publicSpeed ?? 0)
        let token=generation;pending=true
        Task {
            defer { pending=false }
            do {
                let result=try await worker.advance(elapsed:elapsed,command:command,paused:false)
                guard token==generation else { return };frame=result
                if result.result != nil {
                    lastResult=result.result;lastRaceResult=result.raceResult;suspend()
                    if recording { recording=false;captureMessage="Telemetry saved." }
                    reportFinished(result)
                }
            } catch {
                guard token==generation else { return }
                if recording { recording=false;captureMessage="Telemetry aborted; the destination was not replaced." }
                message=String(describing:error);stop()
            }
        }
    }
    private func perform(_ action:DrivingAction) {
        if action == .pause { togglePause();return }
        guard !paused else { return }
        if action == .shiftUp { requestedGear=min(content?.maximumGear ?? 1,requestedGear+1) }
        if action == .shiftDown { requestedGear=max(content?.minimumGear ?? -1,requestedGear-1) }
    }
    func key(_ code:UInt16,pressed:Bool,repeating:Bool=false) {
        if !pressed { _=input.key(code,pressed:false);return }
        if paused,!input.configuration.keyboard[.pause]!.contains(where:{$0.code==code}) { return }
        if let action=input.key(code,pressed:true,repeating:repeating) { perform(action) }
    }

}

@MainActor final class DrivingMetalNSView: MTKView {
    var session: DrivingSession?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();session?.drivingWindow=window }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.command,.control,.option]).isEmpty { super.keyDown(with:event);return }
        // Escape is the game's pause; a bound key drives; V steps the camera.
        if event.keyCode==53 { if !event.isARepeat { session?.togglePause() };return }
        if session?.input.recognizes(event.keyCode)==true { session?.key(event.keyCode,pressed:true,repeating:event.isARepeat) }
        else if event.keyCode==9 { if !event.isARepeat { session?.cycleCamera() } }
        else { super.keyDown(with:event) }
    }
    override func keyUp(with event: NSEvent) { session?.key(event.keyCode,pressed:false) }
    override func resignFirstResponder() -> Bool { session?.releaseInput();return super.resignFirstResponder() }
}
struct DrivingMetalView: NSViewRepresentable {
    let session: DrivingSession
    let content: DrivingContent
    let rate: Int
    // Value inputs make visual-only changes invalidate the representable even
    // while simulation is paused and no new snapshot is published.
    let camera: DrivingCameraPreset
    let zoom:Float
    let mirrors: Bool
    @MainActor final class Coordinator: NSObject,MTKViewDelegate {
        let session: DrivingSession
        let content: DrivingContent
        var modern: ModernDrivingRenderer?
        var cameraRig=DrivingCameraRig()
        var fly: DrivingFlyCamera?
        var television: TVPresentation?
        var world:CameraWorld?
        init(session: DrivingSession,content: DrivingContent) { self.session=session;self.content=content }
        func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let modern, let frame=session.frame else { return }
            do {
                // Every car is interpolated the same way; the viewer's is the one
                // the cameras follow and the only one a cockpit view may hide.
                let poses=try frame.field.map { car -> VehiclePresentation in
                    let a=try VehiclePresentation(car.previous),b=try VehiclePresentation(car.current)
                    return try VehiclePresentation.interpolate(previous:a,current:b,alpha:frame.interpolation)
                }
                let viewer=frame.field.indices.contains(frame.viewer) ? frame.viewer:0
                let pose=poses[viewer]
                let preset=session.cameraPreset
                func ground(_ point: SIMD2<Float>) throws -> Float { try content.simulation.road.geometry.height(at:point,startingAt:frame.trackSegment) }
                let p=pose.body[3]
                let yaw=frame.previous.body.orientation.z
                let delta=frame.current.body.orientation.z-yaw
                let cameraYaw=yaw+atan2(sin(delta),cos(delta))*frame.interpolation
                // Original chase-camera relaxation runs once per graphics update.
                // Read published yaw: projecting a pitched car's forward vector
                // would reverse the camera when pitch passes 90 degrees.
                let trackHeading:Float
                if preset == .trackAligned {
                    let geometry=content.simulation.road.geometry
                    trackHeading=geometry.tangent(try geometry.globalToLocal(SIMD2(p.x,p.y),startingAt:frame.trackSegment))
                } else { trackHeading=0 }
                let flyView=try fly?.draw(time:frame.raceTime,selected:preset == .fly,snapshot:frame.current,zoom:session.cameraZoom)
                // Every preset resolves to a SceneCamera, so both renderers can
                // be driven from one camera decision rather than two.
                let sceneCamera: SceneCamera
                if preset == .fly {
                    guard let flyView else { throw RenderError.unavailable("Fly camera is not initialized") }
                    sceneCamera=flyView
                } else if preset == .television {
                    // The director chooses between the real cars, in race order.
                    let subjects=frame.standings.isEmpty ? frame.field.map(\.presentation)
                        :frame.standings.map { frame.field[$0.car].presentation }
                    guard let world,let result=try television?.view(screen:0,time:frame.raceTime,frame:subjects,road:content.simulation.road,world:world,zoom:session.cameraZoom) else { throw RenderError.unavailable("TV director is not initialized") }
                    sceneCamera=result.camera
                } else {
                    sceneCamera=try cameraRig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,world:world,roadCameraPosition:content.simulation.road.camera(at:frame.trackSegment)?.position,zoomValue:session.cameraZoom,yaw:cameraYaw,trackHeading:trackHeading,groundHeight:ground)
                }

                modern.mirror=session.mirrors && preset.allowsMirror ? RearViewMirror(body:pose.body,bonnetPosition:content.bonnetPosition,hiddenInstances:preset.drawsCar ? Set(1...17):[]):nil
                // A broadcast lens on the television view only: an 85 mm at
                // f/2.8 focused on the followed car. A driver's eyes focus
                // where they look; those views stay sharp everywhere.
                modern.depthOfField=preset == .television ? DepthOfField(focusDistance:sceneCamera.distance):nil
                modern.rain=session.rain ? 1:0
                modern.overcast=session.overcast || session.rain ? 1:0
                // Drops on the glass only where there is glass: the driver's seat.
                modern.windscreenRain=session.rain && preset == .driver ? 1:0
                modern.wetness=session.wet || session.rain ? 1:0
                let sources=ModernDrivingRenderer.particleSources(pose:pose,snapshot:frame.current,speed:frame.speed,geometry:content.simulation.road.geometry,segment:frame.trackSegment,wetness:modern.wetness)
                // Only the viewer's car answers to the view's own exclusions.
                let field=frame.field.indices.map { index in
                    ModernDrivingRenderer.FieldCar(pose:poses[index],
                        brakeCommand:frame.field[index].current.brakeCommand,
                        lightCommand:frame.field[index].current.lightCommand,
                        drawsCar:index==viewer ? preset.drawsCar:true,
                        drawsDriver:index==viewer ? preset.drawsDriver:true,
                        castsShadow:index==viewer ? preset.drawsCar:true)
                }
                modern.draw(in:view,field:field,camera:sceneCamera,viewer:viewer,particleSources:sources,skidSources:ModernDrivingRenderer.skidSources(pose:pose,snapshot:frame.current,speed:frame.speed),deltaTime:1/Float(max(view.preferredFramesPerSecond,1)))
                if let error=modern.lastError { throw RenderError.unavailable(error) }
                if !session.firstFrameDrawn { session.firstFrameDrawn=true }
            } catch { session.message=String(describing:error);session.stop() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session:session,content:content) }
    func makeNSView(context: Context) -> DrivingMetalNSView {
        let view=DrivingMetalNSView();view.session=session;view.preferredFramesPerSecond=rate
        view.isPaused=session.paused;view.enableSetNeedsDisplay=session.paused
        view.setAccessibilityElement(true);view.setAccessibilityRole(.image);view.setAccessibilityLabel("TORCS driving view")
        view.setAccessibilityHelp("Use configured keyboard or controller bindings to drive. Open Controls to change bindings. Driving pauses when the window loses focus.")
        do {
            context.coordinator.world=try CameraWorld(bounds:content.simulation.road.bounds)
            let modern=try ModernDrivingRenderer(content:content,settings:RenderSettings(preset:session.renderPreset),materials:ModernDrivingRenderer.materialsDirectory(beside:session.contentDirectory))
            modern.configure(view)
            context.coordinator.modern=modern
            view.delegate=context.coordinator
            context.coordinator.television=try TVPresentation(carCount:1,settings:TVDirector.Settings())
            try context.coordinator.television?.activate(screen:0,car:0)
            let geometry=content.simulation.road.geometry
            let startSegment=content.simulation.vehicle.chassis.trackPosition.segment
            context.coordinator.fly=try DrivingFlyCamera(height:{ point in try geometry.height(at:point,startingAt:startSegment) })
        }
        catch { let message=String(describing:error);DispatchQueue.main.async { session.message=message;session.stop() } }
        return view
    }
    func updateNSView(_ view: DrivingMetalNSView,context: Context) {
        view.preferredFramesPerSecond=rate
        view.isPaused=session.paused;view.enableSetNeedsDisplay=session.paused
        if session.paused { view.draw() }
        if session.focusRequested {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view);session.focusRequested=false }
        }
    }
}
