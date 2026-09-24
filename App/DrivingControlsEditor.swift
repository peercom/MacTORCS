// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import TORCSInput

struct DrivingControlsEditor:View {
    let session:DrivingSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft:InputConfiguration
    @State private var capture:DrivingAction?
    @State private var message:String?
    init(session:DrivingSession) { self.session=session;_draft=State(initialValue:session.input.configuration) }
    var body:some View {
        VStack(alignment:.leading) {
            Text("Driving Controls").font(.title2.bold()).padding(.horizontal)
            ScrollView {
                Form {
                    Section("Keyboard") {
                        ForEach(DrivingAction.allCases,id:\.self) { action in
                            HStack {
                                Text(action.title);Spacer()
                                Button(draft.keyboard[action]!.isEmpty ? "Assign key…":draft.keyboard[action]!.map(\.label).joined(separator:" / ")) { capture=action }
                                    .accessibilityLabel("Change \(action.title) key binding")
                                    .accessibilityValue(draft.keyboard[action]!.isEmpty ? "Unassigned":draft.keyboard[action]!.map(\.label).joined(separator:" / "))
                                Button("Clear") { draft.keyboard[action]=[] }.accessibilityLabel("Clear \(action.title) key binding")
                            }
                        }
                        Text("Assigning a key replaces that action’s current keys. Escape cancels key capture. Command, Control and Option shortcuts remain available to macOS.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Game controller") {
                        Text(session.controllerName ?? "No extended game controller connected. Pair a controller in macOS Bluetooth settings or connect it by USB.").font(.callout)
                        ForEach(AnalogAction.allCases,id:\.self) { role in
                            GroupBox(role.title) {
                                VStack(alignment:.leading) {
                                    Picker("Control",selection:Binding(get:{draft.analog[role]!},set:{draft.analog[role]=$0})) {
                                        ForEach(role == .steering ? ControllerElement.axes:ControllerElement.buttons,id:\.self) { Text($0.title).tag($0) }
                                    }.accessibilityLabel("\(role.title) controller control")
                                    calibrationSlider("Dead zone",role:role,key:\.deadZone,range:0...0.5)
                                    calibrationSlider("Sensitivity",role:role,key:\.sensitivity,range:0.1...2)
                                    calibrationSlider("Linearity",role:role,key:\.linearity,range:0.2...4)
                                    if role == .steering { calibrationSlider("Speed sensitivity",role:role,key:\.speedSensitivity,range:0...1) }
                                    Toggle("Invert \(role.title.lowercased())",isOn:Binding(get:{draft.calibration[role]!.inverted},set:{draft.calibration[role]!.inverted=$0}))
                                        .accessibilityLabel("Invert \(role.title.lowercased())")
                                }.padding(4)
                            }
                        }
                        ForEach([DrivingAction.shiftUp,.shiftDown,.pause],id:\.self) { action in
                            Picker(action.title,selection:Binding(get:{draft.buttons[action]!},set:{draft.buttons[action]=$0})) {
                                ForEach(ControllerElement.buttons,id:\.self) { Text($0.title).tag($0) }
                            }
                        }
                        Text("Controller steering follows TORCS’s left/right curves. Its dead zone reduces maximum steering unless sensitivity compensates. Linearity 1 is linear; higher values soften the center. Release all controls after pause or reconnection before driving.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
            if let message { Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(.horizontal) }
            HStack {
                Button("Restore Defaults") { draft = .standard;message=nil }
                Spacer();Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try session.saveInput(draft);dismiss() }
                    catch { message=String(describing:error) }
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }.padding(.top,16).frame(width:610,height:700)
        .onAppear { session.suspend() }
        .sheet(isPresented:Binding(get:{capture != nil},set:{if !$0 { capture=nil }})) {
            VStack(alignment:.leading,spacing:16) {
                Text("Press a key for \(capture?.title ?? "driving")").font(.headline)
                Text("Press Escape to cancel. Avoid Command, Control and Option combinations.").font(.callout)
                KeyCaptureView { key in
                    if let key,let action=capture {
                        var proposed=draft;proposed.keyboard[action]=[key]
                        do { try proposed.validate();draft=proposed;message=nil }
                        catch { message=String(describing:error) }
                    }
                    capture=nil
                }.frame(height:50)
                Button("Cancel") { capture=nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width:440)
        }
    }
    private func calibrationSlider(_ label:String,role:AnalogAction,key:WritableKeyPath<AxisCalibration,Float>,range:ClosedRange<Float>) -> some View {
        HStack {
            Text(label).frame(width:115,alignment:.leading)
            Slider(value:Binding(get:{draft.calibration[role]![keyPath:key]},set:{draft.calibration[role]![keyPath:key]=$0}),in:range)
                .accessibilityLabel("\(role.title) \(label.lowercased())")
            Text(String(format:"%.2f",draft.calibration[role]![keyPath:key])).monospacedDigit().frame(width:42,alignment:.trailing)
        }
    }
}
private struct KeyCaptureView:NSViewRepresentable {
    var complete:(KeyBinding?)->Void
    final class Capture:NSView {
        var complete:((KeyBinding?)->Void)?
        override var acceptsFirstResponder:Bool { true }
        override func keyDown(with event:NSEvent) {
            if event.keyCode==53 { complete?(nil);return }
            guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty,KeyBinding.supported(event.keyCode),!event.isARepeat else { return }
            let names:[UInt16:String]=[123:"←",124:"→",125:"↓",126:"↑",49:"Space",36:"Return",48:"Tab",51:"Delete"]
            let label=names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            complete?(KeyBinding(event.keyCode,label))
        }
    }
    func makeNSView(context:Context) -> Capture {
        let view=Capture();view.complete=complete
        view.setAccessibilityElement(true);view.setAccessibilityRole(.textField);view.setAccessibilityLabel("Press a key to assign")
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view:Capture,context:Context) { view.complete=complete }
}
