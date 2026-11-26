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
    /// Where the loaded circuit lives; generated materials are looked for beside it.
    var contentDirectory: URL?
    /// What is loaded, so the same choice is not loaded twice.
    private(set) var contentKey: String?
    /// The car model each entrant drives: 0 is the player's model, `n` is
    /// `content.opponentCars[n-1]`. Entrant 0 is the player; entrants past
    /// the end drive the player's model.
    var fieldModels: [Int]=[]
    /// The name each entrant races under.
    var fieldNames: [String]=[]
    /// The entrant on each grid slot, pole first. The race runtime numbers
    /// its cars by slot, so a published car index is looked up here.
    private(set) var fieldGrid: [Int]=[0]
    /// A grid decided elsewhere (a championship's), in place of the weekend's.
    var gridOverride: [Int]?
    /// The opponents' handicap for the next race; 1 is the original's pace.
    var opponentPace: Float = 1
    /// The player's car driven by the robot policy too: for unattended
    /// checks of a whole race, which nobody is there to drive.
    var autopilot=false
    func entrant(_ fieldIndex: Int) -> Int { fieldGrid.indices.contains(fieldIndex) ? fieldGrid[fieldIndex]:fieldIndex }
    func model(ofEntrant entrant: Int) -> Int {
        let model=fieldModels.indices.contains(entrant) ? fieldModels[entrant]:0
        return model<(content?.models.count ?? 1) ? model:0
    }
    func entrantName(_ entrant: Int) -> String {
        if entrant==0 { return "You" }
        return fieldNames.indices.contains(entrant) ? fieldNames[entrant]:RaceWeekend.defaultName(entrant)
    }
    /// By published car index.
    func model(of fieldIndex: Int) -> Int { model(ofEntrant:entrant(fieldIndex)) }
    func driverName(_ fieldIndex: Int) -> String { entrantName(entrant(fieldIndex)) }
    /// The newest simulation frame. The renderer reads it every draw; it is
    /// not observed, because it changes over a hundred times a second and a
    /// view that depended on it would be rebuilt as often, on the thread the
    /// renderer draws from. Views read `hudFrame`.
    @ObservationIgnored var frame: DrivingFrame? {
        didSet {
            let now=ProcessInfo.processInfo.systemUptime
            // The HUD's copy: twenty times a second, and at once whenever
            // the session changes phase, ends or starts over.
            if frame==nil || hudFrame==nil || now-hudStamp>=0.05 || frame?.phase != hudFrame?.phase
                || (frame?.result != nil) != (hudFrame?.result != nil) || (frame?.time ?? 0)<(hudFrame?.time ?? 0) {
                hudFrame=frame;hudStamp=now
            }
        }
    }
    private(set) var hudFrame: DrivingFrame?
    @ObservationIgnored private var hudStamp=0.0
    /// Frames drawn in the last second and the main thread's share of a
    /// frame in milliseconds, refreshed once a second.
    private(set) var frameRate=0
    private(set) var drawMilliseconds=0.0
    /// The GPU's time for the last frame in milliseconds and the render
    /// scale dynamic resolution has settled on, as the renderer reports them.
    private(set) var gpuMilliseconds=0.0
    private(set) var renderScale: Float = 1
    @ObservationIgnored private var meterStart=0.0
    @ObservationIgnored private var meterFrames=0
    @ObservationIgnored private var meterDraw=0.0
    @ObservationIgnored private var meterGPU=0.0
    func recordDraw(seconds: Double,gpu: Double = 0,scale: Float = 1) {
        let now=ProcessInfo.processInfo.systemUptime
        meterGPU=max(meterGPU,gpu)
        if meterStart==0 { meterStart=now }
        meterFrames += 1;meterDraw += seconds
        if now-meterStart>=1 {
            frameRate=Int((Double(meterFrames)/(now-meterStart)).rounded())
            // Automatic quality: a second of a running session, judged.
            if automaticQuality,!paused,firstFrameDrawn,frame?.result==nil {
                governor.targetRate=Double(UserDefaults.standard.object(forKey:"renderRate") as? Int ?? 60)
                let before=governor.index
                if let level=governor.record(frameRate:Double(meterFrames)/(now-meterStart)) {
                    qualityLevel=level;presetChanged=true
                    UserDefaults.standard.set(governor.index,forKey:Self.settledQualityKey)
                    UserDefaults.standard.set(governor.ceiling,forKey:Self.settledQualityKey+"Ceiling")
                    qualityNotice=governor.index<before ? "Quality lowered to hold \(Int(governor.targetRate)) fps":"Quality raised"
                    qualityNoticeStamp=now
                }
            } else { governor.reset() }
            if qualityNotice != nil,now-qualityNoticeStamp>6 { qualityNotice=nil }
            drawMilliseconds=meterDraw/Double(meterFrames)*1000
            gpuMilliseconds=meterGPU*1000;renderScale=scale
            meterStart=now;meterFrames=0;meterDraw=0;meterGPU=0
        }
    }
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
    /// The quality the player chose: "auto", which holds the frame rate by
    /// lowering the preset when frames are dropped, or a preset's name,
    /// fixed whatever the frame rate.
    var qualityMode: String = UserDefaults.standard.string(forKey:"renderQuality") ?? "auto" {
        didSet { UserDefaults.standard.set(qualityMode,forKey:"renderQuality");applyQualityMode(retest:true) }
    }
    var automaticQuality: Bool { RenderSettings.Preset(rawValue:qualityMode)==nil }
    /// The level in use: the fixed preset, or where automatic quality stands.
    private(set) var qualityLevel=QualityLevel(preset:.m2Air)
    var renderPreset: RenderSettings.Preset { qualityLevel.preset }
    /// Set when automatic quality has just moved, for the HUD to say so.
    private(set) var qualityNotice: String?
    @ObservationIgnored private var qualityNoticeStamp=0.0
    @ObservationIgnored private var governor=QualityGovernor(index:0)
    static let deviceName=MTLCreateSystemDefaultDevice()?.name ?? ""
    /// Where automatic quality last settled, kept apart for Low Power Mode.
    /// The same machine draws a frame in about 13 ms on mains and 21 ms in
    /// Low Power Mode, so a level learnt in one is wrong for the other.
    static var settledQualityKey: String {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? "renderQualityLevelLowPower":"renderQualityLevel"
    }
    /// Take the mode: a fixed preset as chosen; automatic from where it last
    /// settled on this machine, or from the machine's own starting point
    /// when asked to test again.
    private func applyQualityMode(retest: Bool) {
        let rate=Double(UserDefaults.standard.object(forKey:"renderRate") as? Int ?? 60)
        if let fixed=RenderSettings.Preset(rawValue:qualityMode) {
            qualityLevel=QualityLevel(preset:fixed)
        } else {
            if retest {
                for key in ["renderQualityLevel","renderQualityLevelLowPower"] {
                    UserDefaults.standard.removeObject(forKey:key);UserDefaults.standard.removeObject(forKey:key+"Ceiling")
                }
            }
            let settled=UserDefaults.standard.object(forKey:Self.settledQualityKey) as? Int
            // A rung that was climbed to and failed stays ruled out between
            // sessions, so the trial is not repeated every race. Choosing
            // the mode again in Settings tests afresh.
            let top=QualityGovernor.recommended(deviceName:Self.deviceName)
            let ceiling=min(UserDefaults.standard.object(forKey:Self.settledQualityKey+"Ceiling") as? Int ?? top,top)
            governor=QualityGovernor(index:settled ?? QualityGovernor.start(deviceName:Self.deviceName),
                                     ceiling:ceiling,targetRate:rate)
            qualityLevel=governor.level
        }
        presetChanged=true
    }
    /// The renderer has settings to take: checked and cleared by the draw loop.
    @ObservationIgnored var presetChanged=false
    /// The settings the next renderer is built with: the preset, less any
    /// effect named after `--render-off` (a diagnostic for finding what a
    /// frame's time goes on).
    var renderSettings: RenderSettings {
        // Automatic quality owns the resolution; a fixed preset is the renderer's own.
        var settings=automaticQuality ? qualityLevel.settings(wetRoad:wet || rain):RenderSettings(preset:renderPreset)
        Self.applyRenderOff(&settings)
        return settings
    }
    /// `--render-off a,b,...`: a diagnostic that switches effects off, for
    /// finding what a frame's time goes on.
    static func applyRenderOff(_ settings: inout RenderSettings) {
        let arguments=CommandLine.arguments
        guard let index=arguments.firstIndex(of:"--render-off"),index+1<arguments.count else { return }
        for name in arguments[index+1].split(separator:",") {
            switch name {
            case "ssr": settings.screenSpaceReflections = .off
            case "ao": settings.ambientOcclusion = .off
            case "contact": settings.contactShadows=false
            case "bloom": settings.bloom=false
            case "blur": settings.motionBlur=false
            case "glare": settings.sunGlare=false
            case "haze": settings.heatHaze=false
            case "dof": settings.depthOfField=false
            case "exposure": settings.autoExposure=false
            case "particles": settings.particles=false;settings.skidMarks=false
            case "drs": settings.dynamicResolution=false
            case "upscale": settings.upscaling=false;settings.dynamicResolution=false
            case "shadows": settings.shadowCascades=1;settings.shadowResolution=512
            case "cascades3": settings.shadowCascades=3
            case "shadow1024": settings.shadowResolution=1024
            case "s85": settings.renderScale=0.85;settings.upscaling=true;settings.dynamicResolution=false
            case "s67": settings.renderScale=0.67;settings.upscaling=true;settings.dynamicResolution=false
            case "half": settings.renderScale=0.5;settings.upscaling=true;settings.dynamicResolution=false
            default: break
            }
        }
    }
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
        applyQualityMode(retest:false)
        controllers.onButtonChange={ [weak self] element,pressed in
            guard let self else { return }
            // Outside a running session the controller works the menus.
            if let menu=self.onMenuButton,self.menuControl {
                if pressed,NSApp.isActive { menu(element) }
                return
            }
            if let action=self.input.controllerButton(element,pressed:pressed,acceptInput:self.acceptsController) { self.perform(action) }
        }
    }
    /// The controller belongs to the menus: no session is being driven.
    var menuControl: Bool { content==nil || paused || frame?.result != nil }
    @ObservationIgnored var onMenuButton: ((ControllerElement)->Void)?
    /// Keep the controller found and named while no session's timer runs.
    func pollControllerForMenus() {
        guard timer==nil else { return }
        _=controllers.poll()
        if controllerName != controllers.name { controllerName=controllers.name }
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
            fieldGrid=[0]
            return (try DrivingWorker(content.simulation,configuration:configuration),
                    try DrivingRuntime(simulation:content.simulation,configuration:configuration).frame)
        }
        // The grid is the starting order applied to the field: the entry on each
        // slot from pole back. The human keeps its identity wherever it starts.
        let grid=try gridOverride ?? weekend.grid()
        guard grid.sorted()==Array(0..<grid.count),grid.contains(0) else { throw RenderError.unavailable("The starting grid does not name every entrant once") }
        let entries=grid.map { entrant in
            RaceEntry(parameters:content.models[model(ofEntrant:entrant)].parameters,kind:entrant==0 && !autopilot ? .human:.bt,team:"bt",skillLevel:3)
        }
        fieldGrid=grid
        var race=try RaceRuntime(road:content.simulation.road,entries:entries,grid:try .quickRace(),
                                 configuration:configuration)
        race.opponentPace=opponentPace
        return (DrivingWorker(race:race),race.frame)
    }
    static func key(track: URL,car: URL,opponents: [URL]) -> String {
        ([track,car]+opponents).map(\.standardizedFileURL.path).joined(separator:"\n")
    }
    func load(_ directory: URL) async -> Bool { await load(track:directory,car:directory) }
    /// Load a circuit, the player's car and the further car models of the
    /// field, and build the first run. False when it failed; `message` then
    /// says why.
    func load(track: URL,car: URL,opponents: [URL] = []) async -> Bool {
        stop();generation=UUID();let token=generation
        content=nil;contentDirectory=nil;contentKey=nil;frame=nil;worker=nil;message=nil;loading=true;requestedGear=1
        firstFrameDrawn=false;finishedReported=false;lastResult=nil;lastRaceResult=nil
        do {
            let result=try await Task.detached(priority:.userInitiated) { try DrivingContent.load(track:track,car:car,opponents:opponents) }.value
            guard generation==token else { return false }
            let configuration=try RaceSessionConfiguration(kind:selectedSessionKind,laps:selectedLaps)
            content=result;contentDirectory=track;contentKey=Self.key(track:track,car:car,opponents:opponents)
            GameAudio.shared.prepare(result)
            let built=try makeWorker(result,configuration:configuration)
            worker=built.0;frame=built.1
            loading=false;return true
        } catch { guard generation==token else { return false };message=String(describing:error);loading=false;return false }
    }
    /// Leave the session: nothing loaded, nothing running.
    func unload() {
        stop();generation=UUID()
        content=nil;contentDirectory=nil;contentKey=nil;frame=nil;worker=nil;message=nil;loading=false
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
    func suspend() { paused=true;releaseInput();lastWall=ProcessInfo.processInfo.systemUptime;GameAudio.shared.silence() }
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
        if let frame,let content {
            GameAudio.shared.update(frame:frame,content:content,models:{ self.model(of:$0) },throttle:command.throttle,now:now)
        }
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
            let began=ProcessInfo.processInfo.systemUptime
            defer {
                session.recordDraw(seconds:ProcessInfo.processInfo.systemUptime-began,gpu:modern.renderer.gpuTime,scale:modern.renderer.dynamicResolution.scale)
                // A new quality takes effect on the renderer that is running.
                if session.presetChanged { session.presetChanged=false;modern.renderer.settings=session.renderSettings;modern.renderer.resetDynamicResolution() }
            }
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
                    ModernDrivingRenderer.FieldCar(model:session.model(of:index),pose:poses[index],
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
            let modern=try ModernDrivingRenderer(content:content,settings:session.renderSettings,materials:ModernDrivingRenderer.materialsDirectory(beside:session.contentDirectory))
            modern.configure(view)
            if ProcessInfo.processInfo.environment["TORCS_PASS_LOG"] != nil { modern.renderer.passTimer=try PassTimer(device:modern.renderer.device) }
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
