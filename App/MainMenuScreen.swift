// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import TORCSRaceEngine

/// The start screen: the wordmark, the modes, and a look at what is loaded.
struct MainMenuScreen: View {
    let flow: GameFlow
    private struct Item: Identifiable,Equatable {
        let id: String
        let title,detail: String
        let symbol: String
        let action: (GameFlow)->Void
        static func == (a: Item,b: Item) -> Bool { a.id==b.id }
    }
    private var items: [Item] {
        [Item(id:"training",title:"Training",detail:"Alone on the circuit, against the clock",symbol:"stopwatch") { $0.choose(.practice) },
         Item(id:"qualifying",title:"Qualifying",detail:"Set a time, watch the field qualify, then race from your slot",symbol:"flag.checkered") { $0.choose(.qualifying) },
         Item(id:"race",title:"Race",detail:"Line up against the field with the original rules",symbol:"flag.2.crossed") { $0.choose(.race) },
         Item(id:"settings",title:"Settings",detail:"Display, graphics, view and content",symbol:"slider.horizontal.3") { $0.open(.settings) },
         Item(id:"controls",title:"Controls",detail:"Keyboard bindings and controller calibration",symbol:"gamecontroller") { $0.open(.controls) },
         Item(id:"about",title:"About",detail:"Credits and licences",symbol:"info.circle") { $0.open(.about) },
         Item(id:"quit",title:"Quit",detail:"",symbol:"power") { _ in NSApp.terminate(nil) }]
    }
    @State private var selection: String? = "training"
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:0) {
                Wordmark(size:72).padding(.bottom,42)
                KeyboardList(items:items,selection:$selection,activateOnClick:true,activate:{ $0.action(flow) }) { item,selected in
                    HStack(spacing:16) {
                        Image(systemName:item.symbol).font(.system(size:20,weight:.semibold)).frame(width:30)
                        VStack(alignment:.leading,spacing:2) {
                            Text(item.title)
                            if !item.detail.isEmpty { Text(item.detail).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary) }
                        }
                    }.modifier(MenuRowLook(selected:selected))
                }.frame(maxWidth:460)
                Spacer(minLength:12)
                HStack(spacing:14) {
                    Text(GameTheme.version)
                    Text("·")
                    Text(flow.session.controllerName.map { "Controller: \($0)" } ?? "Keyboard")
                    if flow.scanning { Text("·");ProgressView().controlSize(.mini);Text("Scanning content…") }
                }.font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
            }.padding(56).frame(width:600,alignment:.leading)
            Spacer(minLength:0)
            hero.padding(56)
        }
    }
    @ViewBuilder private var hero: some View {
        if flow.library.isEmpty && !flow.scanning {
            VStack(alignment:.leading,spacing:18) {
                Image(systemName:"shippingbox").font(.system(size:44,weight:.light)).foregroundStyle(GameTheme.accent)
                Text("No circuits yet").font(GameTheme.display(30)).foregroundStyle(GameTheme.text)
                Text("Add a folder of prepared driving sessions and the circuits and cars in it appear here. Sessions are prepared from a local TORCS 1.3.9 install:")
                    .font(GameTheme.label(15,weight:.medium)).foregroundStyle(GameTheme.textSecondary).fixedSize(horizontal:false,vertical:true)
                Text("python3 Scripts/prepare-driving-session.py <torcs-1.3.9> <folder> --track <name> --car <name>")
                    .font(GameTheme.mono(12,weight:.regular)).foregroundStyle(GameTheme.text).textSelection(.enabled)
                    .padding(12).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).fill(.black.opacity(0.4)))
                Button("Add Content Folder…") { flow.addContentFolder() }.buttonStyle(PrimaryButtonStyle())
                if !flow.libraryWarnings.isEmpty {
                    Text(flow.libraryWarnings.joined(separator:"\n")).font(GameTheme.label(12,weight:.medium)).foregroundStyle(GameTheme.warn)
                }
            }.padding(28).frame(width:520).gamePanel(strong:true)
        } else if let track=flow.plan.track {
            VStack(alignment:.leading,spacing:14) {
                Text("LAST DRIVEN").font(GameTheme.label(11,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
                TrackMapView(map:track.map,lineWidth:5,color:GameTheme.text).frame(width:360,height:300)
                Text(track.name).font(GameTheme.display(30)).foregroundStyle(GameTheme.text)
                HStack(spacing:10) {
                    StatChip(label:"Length",value:RaceFormat.distance(track.length))
                    StatChip(label:"Type",value:track.categoryTitle)
                    if let car=flow.plan.car { StatChip(label:"Car",value:car.name) }
                }
                Text("\(flow.library.tracks.count) circuit\(flow.library.tracks.count==1 ? "":"s") · \(flow.library.cars.count) car\(flow.library.cars.count==1 ? "":"s") in your library")
                    .font(GameTheme.label(13,weight:.medium)).foregroundStyle(GameTheme.textSecondary)
            }.padding(28).gamePanel(strong:true)
        }
    }
}

/// The main menu row's look, applied inside the keyboard list rather than a
/// button so arrow keys and clicks share one selection.
struct MenuRowLook: ViewModifier {
    var selected: Bool
    @State private var hovering=false
    func body(content: Content) -> some View {
        let lit=selected || hovering
        content
            .font(GameTheme.label(22,weight:.bold))
            .foregroundStyle(lit ? GameTheme.text:GameTheme.textSecondary)
            .padding(.vertical,10).padding(.horizontal,18)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:10,style:.continuous).fill(lit ? Color.white.opacity(0.08):.clear))
            .overlay(alignment:.leading) { RoundedRectangle(cornerRadius:2).fill(GameTheme.accent).frame(width:4).padding(.vertical,8).opacity(selected ? 1:0) }
            .onHover { hovering=$0 }
            .animation(.easeOut(duration:0.12),value:lit)
    }
}
