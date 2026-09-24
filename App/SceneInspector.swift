// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import MetalKit
import Observation
import TORCSAssets
import TORCSMetal
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
                Text("Inspection camera and lighting · Reflections and full scene effects are pending.")
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
    var renderer: SceneRenderer?
    private var lastDragLocation: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragLocation=event.locationInWindow
        if event.clickCount==2,let renderer { renderer.camera=SceneCamera(geometry:renderer.geometry) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let renderer,let previous=lastDragLocation else { return }
        let location=event.locationInWindow;lastDragLocation=location
        renderer.camera.yaw -= Float(location.x-previous.x)*0.008
        renderer.camera.pitch=max(-1.5,min(1.5,renderer.camera.pitch+Float(location.y-previous.y)*0.008))
    }
    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        renderer.camera.distance=max(0.1,min(100_000,renderer.camera.distance*exp(max(-30,min(30,Float(event.scrollingDeltaY)))*0.01)))
    }
    override func keyDown(with event: NSEvent) {
        guard let renderer else { return }
        switch event.charactersIgnoringModifiers {
        case "\u{F702}": renderer.camera.yaw += 0.1
        case "\u{F703}": renderer.camera.yaw -= 0.1
        case "\u{F700}": renderer.camera.pitch=min(1.5,renderer.camera.pitch+0.1)
        case "\u{F701}": renderer.camera.pitch=max(-1.5,renderer.camera.pitch-0.1)
        case "r": renderer.camera=SceneCamera(geometry:renderer.geometry)
        case "+","=": renderer.camera.distance=max(0.1,renderer.camera.distance*0.9)
        case "-": renderer.camera.distance=min(100_000,renderer.camera.distance*1.1)
        default: super.keyDown(with:event)
        }
    }
}
struct SceneMetalView: NSViewRepresentable {
    let scene: LoadedScene
    @Binding var message: String?
    func makeNSView(context: Context) -> OrbitMetalView {
        let view=OrbitMetalView();view.preferredFramesPerSecond=60
        view.setAccessibilityElement(true);view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("TORCS compiled scene")
        view.setAccessibilityHelp("Drag or use arrow keys to orbit. Scroll or press plus and minus to zoom. Press R to frame the model.")
        do {
            let renderer=try SceneRenderer(scene:scene,view:view);view.renderer=renderer
            let info="\(renderer.geometry.batches.count) batches · \(renderer.triangleCount) triangles\n"+renderer.warnings.joined(separator:"\n")
            DispatchQueue.main.async { message=info }
        } catch { let info=String(describing:error);DispatchQueue.main.async { message=info } }
        return view
    }
    func updateNSView(_ view: OrbitMetalView,context: Context) {}
}

@MainActor enum SceneSmoke {
    static func run(directory: URL,output: URL) throws {
        let loaded=try CompiledScene.load(directory),renderer=try SceneRenderer(scene:loaded)
        let width=960,height=640,data=try renderer.render(width:width,height:height)
        let repeated=try renderer.render(width:width,height:height)
        try verifyRasterRepeat(data,repeated)
        let pixels=Array(data),background=[UInt8(41),56,74]
        var coverage=0,checksum: UInt64=0
        for i in stride(from:0,to:pixels.count,by:4) {
            if (0..<3).contains(where:{ abs(Int(pixels[i+$0])-Int(background[$0]))>1 }) { coverage += 1 }
            for c in 0..<3 { checksum += UInt64(pixels[i+c]) }
        }
        guard coverage>100 else { throw RendererError.unavailable("Scene rendered no measurable geometry") }
        try writePNG(data,width:width,height:height,output:output)
        print("SCENE_RENDER source=\(loaded.source) batches=\(renderer.geometry.batches.count) triangles=\(renderer.triangleCount) coveredPixels=\(coverage) rgbChecksum=\(checksum) repeat=1")
        for warning in renderer.warnings { print("Scene limitation: \(warning)") }
    }
    /// Allow only sparse one-LSB GPU rounding; retain measured differences.
    static func verifyRasterRepeat(_ a: Data,_ b: Data) throws {
        guard a.count==b.count,!a.isEmpty else { throw RendererError.unavailable("Raster dimensions differ") }
        let changes=zip(a,b).map { abs(Int($0)-Int($1)) }.filter { $0 != 0 }
        let maximum=changes.max() ?? 0
        print("Raster repeat: changedChannels=\(changes.count) maxChannelDelta=\(maximum)")
        guard maximum<=1,changes.count<=a.count/10_000 else {
            throw RendererError.unavailable("Repeated scene render differs: \(changes.count) channels, maximum \(maximum)")
        }
    }
    static func writePNG(_ data: Data,width: Int,height: Int,output: URL) throws {
        guard let provider=CGDataProvider(data:data as CFData),
              let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),
              let dest=CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil) else { throw RendererError.unavailable("PNG export failed") }
        CGImageDestinationAddImage(dest,image,nil)
        guard CGImageDestinationFinalize(dest) else { throw RendererError.unavailable("PNG finalization failed") }
    }

}
