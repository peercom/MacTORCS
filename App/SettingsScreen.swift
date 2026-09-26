// SPDX-License-Identifier: GPL-2.0-only
// Settings, the controls screen and the credits, both as full screens from
// the menu and as panels over a paused session.
import SwiftUI
import TORCSRaceEngine
import TORCSPresentation
import TORCSRender

struct SettingsScreen: View {
    let flow: GameFlow
    var embedded=false
    @AppStorage("renderRate") private var renderRate=60
    @AppStorage("renderPreset") private var renderPreset=RenderSettings.Preset.m2Air.rawValue
    @AppStorage("hudStandings") private var showStandings=true
    @AppStorage("mirrors") private var mirrors=true
    private var session: DrivingSession { flow.session }
    private func close() { if embedded { flow.closeOverlay() } else { flow.back() } }
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            ScreenHeader(title:"Settings",back:embedded ? nil:{ flow.back() })
            HStack(alignment:.top,spacing:24) {
                VStack(alignment:.leading,spacing:22) {
                    section("Display") {
                        row("Presentation rate","Physics stays at 500 Hz; the display sets what it can show.") {
                            ChoiceChips(options:[(60,"60 Hz"),(120,"120 Hz")],selection:$renderRate)
                        }
                        row("Render quality",session.content==nil ? "The preset the renderer is built with.":"Applies to the next session.") {
                            ChoiceChips(options:[(RenderSettings.Preset.m2Air.rawValue,"Fanless"),(RenderSettings.Preset.balanced.rawValue,"Balanced"),(RenderSettings.Preset.high.rawValue,"High")],selection:$renderPreset)
                        }
                        row("Full screen","⌃⌘F toggles it at any time.") {
                            Button(flow.isFullScreen ? "Leave Full Screen":"Enter Full Screen") { flow.toggleFullScreen() }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    section("Driving view") {
                        row("Rear-view mirror","In the Driver, Bonnet and Road views.") { ToggleChip(isOn:$mirrors) }
                        row("Standings on the HUD","The live classification in a race.") { ToggleChip(isOn:$showStandings) }
                        row("Default camera","V steps through the driving views while driving.") {
                            ArrowChooser(options:DrivingCameraPreset.allCases,selection:Binding(get:{ session.cameraPreset },set:{ session.selectCamera($0) }),title:{ $0.rawValue },width:220)
                        }
                        if let message=session.cameraMessage { Text(message).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.warn) }
                    }
                }.frame(maxWidth:.infinity)
                section("Content") {
                    Text("Folders searched for prepared sessions. Each session pairs a circuit with a car.")
                        .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                    if flow.preferences.roots.isEmpty { Text("No folders yet.").font(GameTheme.label(14,weight:.semibold)).foregroundStyle(GameTheme.text) }
                    ForEach(flow.preferences.roots,id:\.self) { root in
                        HStack {
                            Image(systemName:"folder").foregroundStyle(GameTheme.accent)
                            Text(root).font(GameTheme.mono(12,weight:.regular)).foregroundStyle(GameTheme.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { flow.removeContentFolder(root) } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(GameTheme.textSecondary)
                        }.padding(8).background(RoundedRectangle(cornerRadius:8).fill(Color.white.opacity(0.05)))
                    }
                    HStack {
                        Button("Add Folder…") { flow.addContentFolder() }.buttonStyle(SecondaryButtonStyle())
                        Button("Rescan") { flow.refreshLibrary() }.buttonStyle(SecondaryButtonStyle()).disabled(flow.scanning)
                        if flow.scanning { ProgressView().controlSize(.small) }
                    }
                    Text("\(flow.library.tracks.count) circuit\(flow.library.tracks.count==1 ? "":"s"), \(flow.library.cars.count) car\(flow.library.cars.count==1 ? "":"s"), \(flow.library.entries.count) pairing\(flow.library.entries.count==1 ? "":"s")")
                        .font(GameTheme.label(13,weight:.semibold)).foregroundStyle(GameTheme.text)
                    if !flow.libraryWarnings.isEmpty {
                        ScrollView { Text(flow.libraryWarnings.joined(separator:"\n")).font(GameTheme.mono(11,weight:.regular)).foregroundStyle(GameTheme.warn).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:120)
                    }
                    Text("Prepare sessions from a local TORCS 1.3.9 install with Scripts/prepare-driving-session.py. Shared textures carry unresolved attribution, so sessions stay local.")
                        .font(GameTheme.label(11,weight:.medium)).foregroundStyle(GameTheme.textSecondary.opacity(0.8))
                }.frame(width:420)
            }
            HStack { Spacer();Button("Done") { close() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
            if embedded { Button("") { close() }.keyboardShortcut(.cancelAction).hidden() }
        }.padding(embedded ? 28:48).frame(maxWidth:embedded ? 1100:.infinity,maxHeight:embedded ? nil:.infinity,alignment:.topLeading)
        .background { if embedded { RoundedRectangle(cornerRadius:14,style:.continuous).fill(GameTheme.ink.opacity(0.96)).overlay(RoundedRectangle(cornerRadius:14,style:.continuous).stroke(GameTheme.stroke)) } }
        .onChange(of:mirrors) { _,value in session.mirrors=value }
        .onChange(of:renderPreset) { _,value in session.renderPreset=RenderSettings.Preset(rawValue:value) ?? .m2Air }
    }
    private func section<Content: View>(_ title: String,@ViewBuilder content: ()->Content) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Text(title.uppercased()).font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
            content()
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading).gamePanel()
    }
    private func row<Content: View>(_ title: String,_ detail: String,@ViewBuilder content: ()->Content) -> some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(GameTheme.label(15,weight:.semibold)).foregroundStyle(GameTheme.text)
                Text(detail).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
            }
            Spacer()
            content()
        }
    }
}

struct ControlsScreen: View {
    let flow: GameFlow
    var embedded=false
    private func close() { if embedded { flow.closeOverlay() } else { flow.back() } }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            if !embedded { ScreenHeader(title:"Controls",subtitle:"Keyboard bindings and controller calibration",back:{ flow.back() }) }
            HStack { Spacer();DrivingControlsEditor(session:flow.session,onClose:close).gamePanel(strong:true);Spacer() }
        }.padding(embedded ? 0:48)
    }
}

struct AboutScreen: View {
    let flow: GameFlow
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            ScreenHeader(title:"About",back:{ flow.back() })
            HStack(alignment:.top,spacing:24) {
                VStack(alignment:.leading,spacing:14) {
                    Wordmark(size:44)
                    Text(GameTheme.version).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
                    Text("A native macOS port of TORCS 1.3.9: Swift 6 physics, race rules, the BT driver and a Metal renderer, developed increment by increment against the original code's own executable tests.")
                        .font(GameTheme.label(15,weight:.medium)).foregroundStyle(GameTheme.text).fixedSize(horizontal:false,vertical:true)
                    Text("TORCS is © 2000–2017 Eric Espié, Bernhard Wymann and contributors, released under the GNU General Public License version 2 or later. This port is GPL-2.0-only. Original artwork retains its own terms; see the third-party notices beside the application.")
                        .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary).fixedSize(horizontal:false,vertical:true)
                    Text("The cars and circuits are prepared locally from a TORCS install and are not redistributed with the game.")
                        .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary).fixedSize(horizontal:false,vertical:true)
                }.padding(28).frame(width:560,alignment:.leading).gamePanel(strong:true)
                VStack(alignment:.leading,spacing:12) {
                    Text("KEYS").font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
                    keyRow("↑ / W","Accelerate");keyRow("↓ / S / Space","Brake");keyRow("← → / A D","Steer")
                    keyRow("E / Q","Shift up / down");keyRow("C","Clutch");keyRow("P","Pause")
                    keyRow("ESC","Pause menu");keyRow("V","Next camera");keyRow("⌃⌘F","Full screen")
                    Text("Bindings are changed under Controls.").font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary).padding(.top,6)
                }.padding(22).gamePanel()
            }
            Spacer()
        }.padding(48)
    }
    private func keyRow(_ key: String,_ action: String) -> some View {
        HStack(spacing:14) {
            Text(key).font(GameTheme.mono(12)).foregroundStyle(GameTheme.text).padding(.vertical,3).padding(.horizontal,8).background(RoundedRectangle(cornerRadius:5).fill(Color.white.opacity(0.1))).frame(width:130,alignment:.leading)
            Text(action).font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
        }
    }
}
