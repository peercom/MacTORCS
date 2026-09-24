// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import MetalKit
import Observation
import TORCSSimulation
import TORCSRaceEngine
import TORCSTelemetry
import TORCSMetal
import TORCSInput
import os

private actor DrivingWorker {
    private var runtime: DrivingRuntime
    private var capture: TelemetryWriter?
    private let signposter=OSSignposter(subsystem:"org.torcs.mac",category:"Driving simulation")
    init(_ simulation: SingleVehicleSimulation,configuration: RaceSessionConfiguration) throws { runtime=try DrivingRuntime(simulation:simulation,configuration:configuration) }
    func endSession() throws -> DrivingFrame {
        runtime.endSession();try finishCapture();return runtime.frame
    }
    func startCapture(_ destination: URL) throws {
        guard capture==nil else { throw TelemetryError.invalid("A telemetry capture is already running") }
        let writer=try TelemetryWriter(to:destination)
        try writer.append(DrivingTelemetry.record(runtime.simulation,timing:runtime.timing,raceTime:runtime.raceTime))
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
            try runtime.advance(elapsed:elapsed,command:command,paused:paused,didStep:writer.map { writer in
                { simulation,timing,time in try writer.append(DrivingTelemetry.record(simulation,timing:timing,raceTime:time)) }
            })
        } catch { capture=nil;throw error } // Failed capture never publishes a partial JSON line.
        if runtime.result != nil { try finishCapture() }
        return runtime.frame
    }
}
@MainActor @Observable final class DrivingSession {
    var content: DrivingContent?
    var frame: DrivingFrame?
    var loading=false
    var selectedSessionKind: RaceSessionKind = .practice
    var selectedLaps=5
    var sessionBusy=false
    var lastResult: DrivingSessionResult?
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
    var enhancedFiltering=false
    var enhancedVegetation=false
    var vegetationAvailable=false
    var shadows=true
    var mirrors=true
    var smoothEdges=false
    let supportsEdgeSmoothing=MTLCreateSystemDefaultDevice()?.supportsTextureSampleCount(4) == true
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
    @ObservationIgnored private var loadTask: Task<Void,Never>?
    @ObservationIgnored private var captureTask: Task<Void,Never>?
    func choose(onSelection: @escaping @MainActor ()->Void = {}) {
        suspend()
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true
        panel.message="Choose a prepared driving session containing driving.json."
        // Do not nest a modal loop inside a SwiftUI accessibility button action.
        let completion: (NSApplication.ModalResponse)->Void = { [weak self] response in
            guard response == .OK,let directory=panel.url else { return }
            self?.load(directory)
            onSelection()
        }
        if let window=NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    func load(_ directory: URL) {
        stop();loadTask?.cancel();generation=UUID();let token=generation
        content=nil;frame=nil;worker=nil;message=nil;loading=true;requestedGear=1
        loadTask=Task {
            do {
                let result=try await Task.detached(priority:.userInitiated) { try DrivingContent.load(directory) }.value
                guard !Task.isCancelled,generation==token else { return }
                let configuration=try RaceSessionConfiguration(kind:selectedSessionKind,laps:selectedLaps)
                content=result;worker=try DrivingWorker(result.simulation,configuration:configuration)
                frame=try DrivingRuntime(simulation:result.simulation,configuration:configuration).frame
                loading=false
            } catch { guard generation==token else { return };message=String(describing:error);loading=false }
        }
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
                worker=try DrivingWorker(content.simulation,configuration:configuration)
                frame=try DrivingRuntime(simulation:content.simulation,configuration:configuration).frame
                generation=UUID();requestedGear=1;message=nil;recording=false;captureMessage=nil
                lastWall=ProcessInfo.processInfo.systemUptime;startTimer()
            } catch { guard generation==token else { return };message="Could not start a new session: \(error)" }
        }
    }
    func endSession() {
        guard let worker,!sessionBusy,!captureBusy,frame?.result==nil else { return }
        suspend();sessionBusy=true;generation=UUID();let token=generation
        Task {
            defer { sessionBusy=false }
            do {
                let ended=try await worker.endSession()
                guard generation==token else { return }
                frame=ended;lastResult=ended.result;recording=false
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
                if result.result != nil { lastResult=result.result;suspend();if recording { recording=false;captureMessage="Telemetry saved." } }
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

struct DrivingScreen: View {
    let session: DrivingSession
    @AppStorage("renderRate") private var renderRate=60
    @State private var showControls=false
    @State private var showSetup=false
    @State private var showResults=false
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text(session.content?.name ?? "Driving Session").font(.headline)
                Spacer()
                Button(session.frame?.result != nil ? "Finished":session.paused ? (session.frame?.time==0 ? "Start":"Resume"):"Pause") { session.togglePause() }
                    .disabled(session.content==nil || session.message != nil || session.captureBusy || session.sessionBusy || session.frame?.result != nil)
                Button("New Session…") { session.suspend();showSetup=true }
                    .disabled(session.content==nil || session.captureBusy || session.sessionBusy)
                Button("Results…") { session.suspend();showResults=true }.disabled(session.frame?.result==nil && session.lastResult==nil)
                Button(session.recording ? "Finish Recording":"Record Telemetry…") {
                    if session.recording { session.finishRecording() } else { session.chooseCapture() }
                }.disabled(session.content==nil || session.captureBusy || session.sessionBusy || session.frame?.result != nil)
                Button("Controls…") { session.suspend();showControls=true }
                Button("Open Session…") { session.choose() }.disabled(session.sessionBusy || session.captureBusy)
            }.padding()
            if let content=session.content {
                DrivingMetalView(session:session,content:content,rate:renderRate,camera:session.cameraPreset,zoom:session.cameraZoom,shadows:session.shadows,mirrors:session.mirrors,enhancedFiltering:session.enhancedFiltering,smoothEdges:session.smoothEdges,enhancedVegetation:session.enhancedVegetation).id(session.generation)
                    .overlay {
                        if let frame=session.frame,!session.paused,frame.result==nil,frame.raceTime<0.8 {
                            Text(frame.phase == .prestart ? (frame.raceTime < -1 ? "Ready":"Set"):"Go!")
                                .font(.system(size:56,weight:.bold,design:.rounded)).foregroundStyle(.white)
                                .padding(24).background(.black.opacity(0.6),in:RoundedRectangle(cornerRadius:16))
                                .allowsHitTesting(false)
                        }
                    }
            } else if session.loading { ProgressView("Preparing car and track…").frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { ContentUnavailableView("Open a driving session",systemImage:"steeringwheel",description:Text("Choose a prepared car and track session to drive.")) }
            HStack {
                Picker("Camera",selection:Binding(get:{session.cameraPreset},set:{session.selectCamera($0)})) {
                    ForEach(["Driving views","Side views","Overhead views","Circuit views","Trackside views"],id:\.self) { family in
                        Section(family) {
                            ForEach(DrivingCameraPreset.allCases.filter { $0.family==family },id:\.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                }.frame(width:235).help("Side views keep a fixed world direction. Overhead views use the original heights and orientations.")
                ControlGroup {
                    Button { session.adjustCameraZoom(.zoomIn) } label: { Label("Zoom in",systemImage:"plus.magnifyingglass") }
                    Button { session.adjustCameraZoom(.zoomOut) } label: { Label("Zoom out",systemImage:"minus.magnifyingglass") }
                }.labelStyle(.iconOnly)
                Menu("Zoom options") {
                    Button("Reset zoom") { session.adjustCameraZoom(.reset) }
                    Button("Maximum zoom") { session.adjustCameraZoom(.minimum) }
                    Button("Minimum zoom") { session.adjustCameraZoom(.maximum) }
                }.fixedSize()
                Spacer()
            }.disabled(session.content==nil).padding(.horizontal).padding(.top,8)
            if let cameraMessage=session.cameraMessage { Text(cameraMessage).foregroundStyle(.orange).padding(.horizontal) }
            HStack {
                Toggle("Car shadow",isOn:Binding(get:{session.shadows},set:{session.shadows=$0})).disabled(session.content?.shadow==nil)
                Toggle("Rear-view mirror",isOn:Binding(get:{session.mirrors},set:{session.mirrors=$0}))
                    .disabled(!session.cameraPreset.allowsMirror).help("Available in Driver, Bonnet and Road views.")
                Toggle("Smooth edges",isOn:Binding(get:{session.smoothEdges},set:{session.smoothEdges=$0}))
                    .disabled(!session.supportsEdgeSmoothing).help("Optional 4× multisample antialiasing for car and track geometry.")
                Toggle("3D trees",isOn:Binding(get:{session.enhancedVegetation},set:{session.enhancedVegetation=$0}))
                    .disabled(!session.vegetationAvailable).help("Adds volume to supported nearby trees. Original trees remain in distant views.")
                Toggle("Sharper road textures",isOn:Binding(get:{session.enhancedFiltering},set:{session.enhancedFiltering=$0}))
                    .help("Optional 4× anisotropic texture filtering. Classic filtering is used when off.")
                Spacer()
            }.padding(.horizontal).padding(.top,8)
            HStack(spacing:24) {
                Text(session.frame?.result != nil ? "Session ended":session.paused ? "Paused":session.frame?.phase == .prestart ? ((session.frame?.raceTime ?? -2)<(-1) ? "Ready":"Set"):((session.frame?.raceTime ?? 1)<1 ? "Go!":"Driving"))
                if let frame=session.frame {
                    Text(String(format:"%.0f km/h",frame.speed*3.6));Text("Gear \(frame.gear) → \(session.requestedGear)")
                    Text(String(format:"%.0f RPM",frame.rpm));Text(String(format:"%.2f s",max(0,frame.raceTime)))
                    if frame.behind { Text("Catching up").foregroundStyle(.orange) }
                }
                Spacer()
            }.monospacedDigit().padding(.horizontal).padding(.top,10)
            if let frame=session.frame {
                HStack(spacing:20) {
                    Text(frame.configuration.kind == .qualifying ? "Qualifying":"Practice")
                    Text(frame.result != nil ? "\(frame.completedLaps.count) / \(frame.timing.targetLaps) laps completed":frame.phase == .prestart ? "Starting…":frame.timing.laps==0 ? "Approaching start line":"Lap \(min(frame.timing.laps,frame.timing.targetLaps)) / \(frame.timing.targetLaps)")
                    Text(frame.phase == .prestart ? "Current —":String(format:"Current %.3f s",frame.timing.currentLapTime))
                    Text(frame.timing.lastLapTime>0 ? String(format:"Last %.3f s",frame.timing.lastLapTime):"Last —")
                    Text(frame.timing.bestLapTime>0 ? String(format:"Best %.3f s",frame.timing.bestLapTime):"Best —")
                    if !frame.timing.commitBestLapTime { Text("Invalid lap").foregroundStyle(.orange) }
                    Spacer()
                }.monospacedDigit().font(.callout).padding(.horizontal).padding(.top,8)
                if frame.result==nil,frame.time>0 {
                    Button("End Session") { session.endSession() }.disabled(session.sessionBusy || session.captureBusy).padding(6)
                }
            }
            if let message=session.captureMessage { Text(message).font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal) }
            HStack {
                Text(session.controllerName.map { "Controller: \($0)" } ?? "Keyboard · No game controller connected")
                if session.controllerName != nil,!session.controllerReady { Text("Release controller controls to enable input").foregroundStyle(.secondary) }
                Spacer()
                Text("Configure keys and controller in Controls…")
            }
                .font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal).padding(.vertical,8)
            if let message=session.inputMessage { Text(message).font(.caption).padding(.horizontal) }
            if let message=session.message { Text(message).font(.caption).textSelection(.enabled).padding() }
        }.frame(minWidth:900,minHeight:650)
        .sheet(isPresented:$showControls) { DrivingControlsEditor(session:session) }
        .sheet(isPresented:$showSetup) { DrivingSessionSetup(session:session) }
        .sheet(isPresented:$showResults) {
            if let result=session.frame?.result ?? session.lastResult { DrivingResultsView(session:session,result:result) }
        }
        .onChange(of:session.frame?.phase) { _,phase in if phase == .results { showResults=true } }
        .onAppear { session.startTimer() }
        .onDisappear { session.stop() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didResignActiveNotification)) { _ in session.suspend() }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didResignKeyNotification)) { _ in session.suspend() }
    }
}
@MainActor final class DrivingMetalNSView: MTKView {
    var session: DrivingSession?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();session?.drivingWindow=window }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.command,.control,.option]).isEmpty { super.keyDown(with:event);return }
        if session?.input.recognizes(event.keyCode)==true { session?.key(event.keyCode,pressed:true,repeating:event.isARepeat) }
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
    let shadows,mirrors,enhancedFiltering,smoothEdges,enhancedVegetation: Bool
    @MainActor final class Coordinator: NSObject,MTKViewDelegate {
        let session: DrivingSession
        let content: DrivingContent
        var renderer: SceneRenderer?
        var cameraRig=DrivingCameraRig()
        var fly: DrivingFlyCamera?
        var television: TVPresentation?
        var shadow: CarShadow?
        var trackShadow: CarTrackShadowMapping?
        var world:CameraWorld?
        init(session: DrivingSession,content: DrivingContent) { self.session=session;self.content=content }
        func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let renderer,let frame=session.frame else { return }
            do {
                let a=try VehiclePresentation(frame.previous),b=try VehiclePresentation(frame.current)
                let pose=try VehiclePresentation.interpolate(previous:a,current:b,alpha:frame.interpolation)
                let preset=session.cameraPreset
                renderer.enhancedFiltering=session.enhancedFiltering
                renderer.smoothEdges=session.smoothEdges
                renderer.enhancedVegetation=session.enhancedVegetation
                func ground(_ point: SIMD2<Float>) throws -> Float { try content.simulation.road.geometry.height(at:point,startingAt:frame.trackSegment) }
                try renderer.setShadow(session.shadows && preset.drawsCar ? shadow?.project(body:pose.body,groundHeight:ground) ?? []:[],normal:SIMD3(pose.body[2].x,pose.body[2].y,pose.body[2].z))
                let p=pose.body[3]
                let yaw=frame.previous.body.orientation.z
                let delta=frame.current.body.orientation.z-yaw
                let cameraYaw=yaw+atan2(sin(delta),cos(delta))*frame.interpolation
                let reflection=try CarReflection(body:pose.body,yaw:cameraYaw,track:content.simulation.road.geometry,startingAt:frame.trackSegment,trackShadow:trackShadow)
                try renderer.setInstances([SceneInstance(resource:5,anchor:.land)]+(preset.drawsCar ? pose.instances(bodyResource:0,wheelResources:[1,2,3,4],reflection:reflection,drawDriver:preset.drawsDriver,brakeResources:content.brakeResources):[]))
                // Original chase-camera relaxation runs once per graphics update.
                // Read published yaw: projecting a pitched car's forward vector
                // would reverse the camera when pitch passes 90 degrees.
                let trackHeading:Float
                if preset == .trackAligned {
                    let geometry=content.simulation.road.geometry
                    trackHeading=geometry.tangent(try geometry.globalToLocal(SIMD2(p.x,p.y),startingAt:frame.trackSegment))
                } else { trackHeading=0 }
                let heightShadow = session.shadows ? try shadow?.project(body:b.body,groundHeight:ground) ?? []:[]
                let flyView=try fly?.draw(time:frame.raceTime,selected:preset == .fly,snapshot:frame.current,drawsCar:preset.drawsCar,drawsDriver:preset.drawsDriver,shadowVertices:heightShadow,zoom:session.cameraZoom,enhancedVegetation:session.enhancedVegetation)
                if preset == .fly {
                    if let flyView { renderer.camera=flyView }
                } else if preset == .television {
                    guard let world,let result=try television?.view(screen:0,time:frame.raceTime,frame:[frame.presentationCar],road:content.simulation.road,world:world,zoom:session.cameraZoom) else { throw RendererError.unavailable("TV director is not initialized") }
                    renderer.camera=result.camera
                } else {
                renderer.camera=try cameraRig.view(preset:preset,body:pose.body,bonnetPosition:content.bonnetPosition,driverPosition:content.driverPosition,world:world,roadCameraPosition:content.simulation.road.camera(at:frame.trackSegment)?.position,zoomValue:session.cameraZoom,yaw:cameraYaw,trackHeading:trackHeading,groundHeight:ground)
                }
                renderer.mirror=session.mirrors && preset.allowsMirror ? RearViewMirror(body:pose.body,bonnetPosition:content.bonnetPosition,hiddenInstances:preset.drawsCar ? Set(1...17):[]):nil
                renderer.lightView=ShadowView(currentCar:0,drawsCurrentCar:preset.drawsCar)
                let lightInstances=content.lightTextures.isEmpty ? []:try CarLightInstance.instances(definitions:content.lights,body:pose.body,brakeCommand:frame.current.brakeCommand,lightCommand:frame.current.lightCommand,display:true)
                try renderer.setCarLights(lightInstances.map { SceneCarLight(carIndex:0,light:$0) })
                renderer.draw(in:view)
                if let error=renderer.lastRenderError { throw RendererError.unavailable(error) }
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
            if let track=content.trackLoaderBounds,let car=content.carShadowLoaderBounds {
                context.coordinator.trackShadow=try CarTrackShadowMapping(trackBounds:track,carBounds:car)
            }
            context.coordinator.renderer=try SceneRenderer(scenes:content.renderScenes,view:view,vegetationResource:5);try context.coordinator.renderer?.setCarLightTextures(content.lightTextures);try context.coordinator.renderer?.setShadowTexture(content.shadow);try context.coordinator.renderer?.setEnvironment(content.graphics,background:content.background);try context.coordinator.renderer?.setCarEnvironment(reflection:content.reflection,shade:content.environmentShade,trackShadow:content.trackShadow);context.coordinator.shadow=try CarShadow(dimensions:content.dimensions);view.delegate=context.coordinator
            let treeCount=context.coordinator.renderer?.vegetationForest?.placements.count ?? 0
            DispatchQueue.main.async { session.vegetationAvailable=treeCount>0 }
            context.coordinator.television=try TVPresentation(carCount:1,settings:TVDirector.Settings())
            try context.coordinator.television?.activate(screen:0,car:0)
            let snapshot=content.simulation.visualSnapshot
            let initialShadow=try context.coordinator.shadow!.project(body:VehiclePresentation.matrix(snapshot.body)) { try content.simulation.road.geometry.height(at:$0,startingAt:content.simulation.vehicle.chassis.trackPosition.segment) }
            context.coordinator.fly=try DrivingFlyCamera(height:DrivingSceneHeight(scenes:content.scenes.map { $0.asset.scene },snapshot:snapshot,shadowVertices:initialShadow,brakeScenes:content.brakeScenes.map { $0.asset.scene },lights:content.lights),vegetation:context.coordinator.renderer?.vegetationForest)
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
