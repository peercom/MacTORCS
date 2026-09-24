// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import MetalKit
import Observation
import TORCSAssets
import TORCSPresentation
import TORCSRender
import TORCSRaceEngine
import ImageIO
import UniformTypeIdentifiers

@MainActor @Observable final class SceneInspectionSession {
    var directory: URL?
    func choose(onSelection: @escaping @MainActor ()->Void = {}) {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true
        panel.message="Choose a compiled scene folder containing scene.json."
        let completion: (NSApplication.ModalResponse)->Void = { [weak self] response in
            guard response == .OK else { return }
            self?.directory=panel.url
            onSelection()
        }
        if let window=NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
}
struct SceneInspectorScreen: View {
    let session: SceneInspectionSession
    @State private var scene: LoadedScene?
    @State private var message: String?
    @State private var loading=false
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text(session.directory?.lastPathComponent ?? "Compiled Scene").font(.headline)
                Spacer()
                Button("Open Scene…") { session.choose() }
            }.padding()
            if let scene {
                SceneMetalView(scene:scene,message:$message).id(session.directory)
                    .accessibilityLabel("TORCS compiled model inspection. Drag to orbit; scroll to zoom; double-click to frame the model.")
            } else if loading { ProgressView("Loading compiled scene…").frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { ContentUnavailableView("Open a compiled scene",systemImage:"cube",description:Text("Compile a model with torcs-assetc --scene, then open its output folder.")) }
            VStack(alignment:.leading,spacing:4) {
                Text("Drag or arrows to orbit · Scroll or +/− to zoom · Double-click or R to frame")
                Text("Physically based inspection with the sun overhead.")
                if let message { Text(message).textSelection(.enabled) }
            }.font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding()
        }.frame(minWidth:800,minHeight:600)
        .task(id:session.directory) {
            scene=nil;message=nil
            guard let url=session.directory else { return }
            loading=true
            do {
                let result=try await Task.detached(priority:.userInitiated) { try CompiledScene.load(url) }.value
                guard !Task.isCancelled else { return };scene=result
            } catch { if !Task.isCancelled { message=String(describing:error) } }
            if !Task.isCancelled { loading=false }
        }
    }
}
@MainActor final class OrbitMetalView: MTKView {
    var renderer: ForwardRenderer?
    var resources: SceneResources?
    var camera: SceneCamera?
    var bounds3: (SIMD3<Float>, SIMD3<Float>) = (.zero, .zero)
    var lighting = SunLighting()
    private var lastDragLocation: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    func frameModel() { camera = SceneCamera(framing: bounds3.0, bounds3.1) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragLocation=event.locationInWindow
        if event.clickCount==2 { frameModel() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard camera != nil,let previous=lastDragLocation else { return }
        let location=event.locationInWindow;lastDragLocation=location
        camera!.yaw -= Float(location.x-previous.x)*0.008
        camera!.pitch=max(-1.5,min(1.5,camera!.pitch+Float(location.y-previous.y)*0.008))
    }
    override func scrollWheel(with event: NSEvent) {
        guard camera != nil else { return }
        camera!.distance=max(0.1,min(100_000,camera!.distance*exp(max(-30,min(30,Float(event.scrollingDeltaY)))*0.01)))
    }
    override func keyDown(with event: NSEvent) {
        guard camera != nil else { return }
        switch event.charactersIgnoringModifiers {
        case "\u{F702}": camera!.yaw += 0.1
        case "\u{F703}": camera!.yaw -= 0.1
        case "\u{F700}": camera!.pitch=min(1.5,camera!.pitch+0.1)
        case "\u{F701}": camera!.pitch=max(-1.5,camera!.pitch-0.1)
        case "r": frameModel()
        case "+","=": camera!.distance=max(0.1,camera!.distance*0.9)
        case "-": camera!.distance=min(100_000,camera!.distance*1.1)
        default: super.keyDown(with:event)
        }
    }
}
@MainActor final class OrbitCoordinator: NSObject, MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let view = view as? OrbitMetalView, let renderer = view.renderer, let resources = view.resources, let camera = view.camera else { return }
        _ = try? renderer.present(in: view, resources: [resources], instances: [RenderInstance(resource: 0)],
                                  camera: ModernDrivingRenderer.camera(from: camera), lighting: view.lighting)
    }
}
struct SceneMetalView: NSViewRepresentable {
    let scene: LoadedScene
    @Binding var message: String?
    func makeCoordinator() -> OrbitCoordinator { OrbitCoordinator() }
    func makeNSView(context: Context) -> OrbitMetalView {
        let view=OrbitMetalView();view.preferredFramesPerSecond=60
        view.setAccessibilityElement(true);view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("TORCS compiled scene")
        view.setAccessibilityHelp("Drag or use arrow keys to orbit. Scroll or press plus and minus to zoom. Press R to frame the model.")
        do {
            var settings = RenderSettings()
            settings.motionBlur = false
            let renderer = try ForwardRenderer(settings: settings)
            renderer.configure(view)
            let flattened = try RenderScene(scene.asset.scene)
            let store = TextureStore(device: renderer.device, roots: [])
            let resources = try SceneResources(device: renderer.device, scene: flattened, textures: store, compiled: scene.textures)
            view.renderer = renderer; view.resources = resources
            view.bounds3 = (flattened.minimum, flattened.maximum); view.frameModel()
            view.delegate = context.coordinator
            let info="\(flattened.batches.count) batches · \(flattened.triangleCount) triangles\n"+flattened.warnings.joined(separator:"\n")
            DispatchQueue.main.async { message=info }
        } catch { let info=String(describing:error);DispatchQueue.main.async { message=info } }
        return view
    }
    func updateNSView(_ view: OrbitMetalView,context: Context) {}
}
