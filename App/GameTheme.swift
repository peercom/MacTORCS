// SPDX-License-Identifier: GPL-2.0-only
// The look of the game shell: one palette, a few type styles, the buttons
// and panels every screen is built from, and the circuit outline view.
import SwiftUI
import TORCSRaceEngine

enum GameTheme {
    static let accent=Color(red:1.0,green:0.47,blue:0.13)
    static let accentDeep=Color(red:0.85,green:0.28,blue:0.05)
    static let ink=Color(red:0.035,green:0.045,blue:0.07)
    static let inkLight=Color(red:0.09,green:0.11,blue:0.16)
    static let panel=Color.white.opacity(0.055)
    static let panelStrong=Color.black.opacity(0.42)
    static let stroke=Color.white.opacity(0.10)
    static let text=Color.white.opacity(0.94)
    static let textSecondary=Color.white.opacity(0.60)
    static let good=Color(red:0.35,green:0.85,blue:0.45)
    static let warn=Color(red:1.0,green:0.78,blue:0.25)
    static let bad=Color(red:1.0,green:0.33,blue:0.30)
    static func display(_ size: CGFloat,weight: Font.Weight = .black) -> Font { .system(size:size,weight:weight,design:.rounded) }
    static func label(_ size: CGFloat,weight: Font.Weight = .semibold) -> Font { .system(size:size,weight:weight,design:.rounded) }
    static func mono(_ size: CGFloat,weight: Font.Weight = .semibold) -> Font { .system(size:size,weight:weight,design:.monospaced) }
    static let version: String = {
        let short=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
        return short.map { "Version \($0)" } ?? "Development build"
    }()
}

/// Lap and gap times the way a timing screen writes them.
enum RaceFormat {
    static func lap(_ seconds: Double) -> String {
        guard seconds.isFinite,seconds>0 else { return "—:——.———" }
        let whole=Int(seconds),ms=Int(((seconds-Double(whole))*1000).rounded(.down))
        return String(format:"%d:%02d.%03d",whole/60,whole%60,min(ms,999))
    }
    static func gap(_ seconds: Double) -> String { seconds>0 ? String(format:"+%.3f",seconds):"—" }
    static func distance(_ metres: Float) -> String { metres>=1000 ? String(format:"%.2f km",metres/1000):String(format:"%.0f m",metres) }
    static func kind(_ kind: RaceSessionKind) -> String {
        switch kind { case .practice:"Training";case .qualifying:"Qualifying";case .race:"Race" }
    }
}

struct GameBackdrop: View {
    var map: TrackMap?
    var body: some View {
        ZStack {
            LinearGradient(colors:[GameTheme.inkLight,GameTheme.ink,.black],startPoint:.topLeading,endPoint:.bottomTrailing)
            Canvas { context,size in
                // Diagonal speed stripes, faint, off to the right.
                var stripes=Path()
                var x: CGFloat = size.width*0.35
                while x<size.width*1.6 { stripes.move(to:CGPoint(x:x,y:size.height));stripes.addLine(to:CGPoint(x:x+size.height*0.55,y:0));x += 46 }
                context.stroke(stripes,with:.color(.white.opacity(0.025)),lineWidth:1)
                var band=Path()
                band.move(to:CGPoint(x:size.width*0.52,y:size.height));band.addLine(to:CGPoint(x:size.width*0.52+size.height*0.55,y:0))
                band.addLine(to:CGPoint(x:size.width*0.60+size.height*0.55,y:0));band.addLine(to:CGPoint(x:size.width*0.60,y:size.height))
                context.fill(band,with:.linearGradient(Gradient(colors:[GameTheme.accent.opacity(0.10),GameTheme.accent.opacity(0.0)]),startPoint:CGPoint(x:0,y:size.height),endPoint:CGPoint(x:size.width,y:0)))
            }
            if let map {
                TrackMapView(map:map,lineWidth:3,color:.white.opacity(0.05),showStart:false)
                    .frame(width:820,height:820).offset(x:360,y:60).allowsHitTesting(false)
            }
        }.ignoresSafeArea()
    }
}

/// The circuit outline, fitted to its frame with the aspect kept.
struct TrackMapView: View {
    let map: TrackMap
    var lineWidth: CGFloat = 4
    var color: Color = GameTheme.text
    var progress: CGFloat = 1
    var showStart=true
    var body: some View {
        Canvas { context,size in
            guard map.points.count>1 else { return }
            let inset=lineWidth*1.5
            let available=CGSize(width:size.width-2*inset,height:size.height-2*inset)
            // The unit square holds the longer side; fit the outline's own
            // extent to the frame.
            let aspect=CGFloat(max(map.aspect,1e-3))
            let extentX=min(aspect,1),extentY=min(1/aspect,1)
            let fit=min(available.width/extentX,available.height/extentY)
            func point(_ p: SIMD2<Float>) -> CGPoint {
                let x=(CGFloat(p.x)-0.5)*fit+size.width/2
                let y=(0.5-CGFloat(p.y))*fit+size.height/2
                return CGPoint(x:x,y:y)
            }
            var path=Path()
            path.move(to:point(map.points[0]))
            for p in map.points.dropFirst() { path.addLine(to:point(p)) }
            let shown=progress<1 ? path.trimmedPath(from:0,to:max(0,progress)):path
            context.stroke(shown,with:.color(color),style:StrokeStyle(lineWidth:lineWidth,lineCap:.round,lineJoin:.round))
            if showStart,progress>=1 {
                let s=point(map.start)
                let r=lineWidth*1.6
                context.fill(Path(ellipseIn:CGRect(x:s.x-r,y:s.y-r,width:2*r,height:2*r)),with:.color(GameTheme.accent))
            }
        }
    }
}

struct GamePanel: ViewModifier {
    var strong=false
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius:14,style:.continuous).fill(strong ? GameTheme.panelStrong:GameTheme.panel))
            .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).stroke(GameTheme.stroke,lineWidth:1))
    }
}
extension View {
    func gamePanel(strong: Bool = false) -> some View { modifier(GamePanel(strong:strong)) }
}

/// The main menu's rows: a wide bar, the accent edge lit when hovered or
/// selected.
struct MenuRowStyle: ButtonStyle {
    var selected=false
    @State private var hovering=false
    func makeBody(configuration: Configuration) -> some View {
        let lit=selected || hovering || configuration.isPressed
        configuration.label
            .font(GameTheme.label(22,weight:.bold))
            .foregroundStyle(lit ? GameTheme.text:GameTheme.textSecondary)
            .padding(.vertical,12).padding(.horizontal,18)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:10,style:.continuous).fill(lit ? Color.white.opacity(0.08):.clear))
            .overlay(alignment:.leading) { RoundedRectangle(cornerRadius:2).fill(GameTheme.accent).frame(width:4).padding(.vertical,8).opacity(lit ? 1:0) }
            .contentShape(Rectangle())
            .onHover { hovering=$0 }
            .animation(.easeOut(duration:0.12),value:lit)
    }
}
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GameTheme.label(17,weight:.bold))
            .foregroundStyle(.white)
            .padding(.vertical,12).padding(.horizontal,26)
            .background(Capsule().fill(LinearGradient(colors:[GameTheme.accent,GameTheme.accentDeep],startPoint:.top,endPoint:.bottom)))
            .opacity(enabled ? (configuration.isPressed ? 0.8:1):0.35)
            .scaleEffect(configuration.isPressed ? 0.97:1)
            .animation(.easeOut(duration:0.1),value:configuration.isPressed)
    }
}
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering=false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GameTheme.label(16,weight:.semibold))
            .foregroundStyle(GameTheme.text)
            .padding(.vertical,11).padding(.horizontal,22)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.14:0.08)))
            .overlay(Capsule().stroke(GameTheme.stroke,lineWidth:1))
            .opacity(enabled ? (configuration.isPressed ? 0.7:1):0.35)
            .onHover { hovering=$0 }
    }
}
struct ChipStyle: ButtonStyle {
    var selected=false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GameTheme.label(14,weight:.semibold))
            .foregroundStyle(selected ? .white:GameTheme.textSecondary)
            .padding(.vertical,7).padding(.horizontal,14)
            .background(Capsule().fill(selected ? GameTheme.accent.opacity(0.9):Color.white.opacity(0.07)))
            .opacity(configuration.isPressed ? 0.7:1)
    }
}

/// Where a screen sits in the flow and how to leave it.
struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil
    var crumbs: [String]=[]
    var back: (()->Void)? = nil
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:18) {
            if let back {
                Button(action:back) { Label("Back",systemImage:"chevron.left").labelStyle(.titleAndIcon) }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            VStack(alignment:.leading,spacing:4) {
                if !crumbs.isEmpty {
                    Text(crumbs.joined(separator:"  ›  ").uppercased()).font(GameTheme.label(12,weight:.bold)).foregroundStyle(GameTheme.accent).tracking(1.5)
                }
                Text(title.uppercased()).font(GameTheme.display(38)).foregroundStyle(GameTheme.text).tracking(1)
                if let subtitle { Text(subtitle).font(GameTheme.label(15,weight:.medium)).foregroundStyle(GameTheme.textSecondary) }
            }
            Spacer()
        }
    }
}

struct StatChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment:.leading,spacing:2) {
            Text(label.uppercased()).font(GameTheme.label(10,weight:.bold)).foregroundStyle(GameTheme.textSecondary).tracking(1.2)
            Text(value).font(GameTheme.mono(15)).foregroundStyle(GameTheme.text)
        }.padding(.vertical,8).padding(.horizontal,12).gamePanel()
    }
}

struct Wordmark: View {
    var size: CGFloat = 64
    var body: some View {
        VStack(alignment:.leading,spacing:-size*0.08) {
            Text("TORCS").font(GameTheme.display(size)).foregroundStyle(GameTheme.text).tracking(size*0.06)
            HStack(spacing:8) {
                RoundedRectangle(cornerRadius:2).fill(GameTheme.accent).frame(width:size*0.55,height:4)
                Text("The Open Racing Car Simulator").font(GameTheme.label(size*0.22,weight:.semibold)).foregroundStyle(GameTheme.textSecondary)
            }.padding(.top,size*0.18)
        }
    }
}

/// A keyboard-driven list: arrows move the selection, Return activates,
/// a click selects and a double-click activates.
struct KeyboardList<Item: Identifiable & Equatable,Row: View>: View {
    let items: [Item]
    @Binding var selection: Item.ID?
    var activateOnClick=false
    var activate: (Item)->Void
    @ViewBuilder var row: (Item,Bool)->Row
    @FocusState private var focused: Bool
    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index=items.firstIndex { $0.id==selection } ?? -1
        let next=min(max(index+delta,0),items.count-1)
        selection=items[next].id
    }
    /// Screenshots are rendered offscreen, where a scroll view draws nothing.
    nonisolated(unsafe) static var scrolls: Bool { !CommandLine.arguments.contains("--screenshot") }
    private var rows: some View {
        VStack(spacing:6) {
            ForEach(items) { item in
                row(item,item.id==selection).id(item.id).contentShape(Rectangle())
                    .onTapGesture(count:2) { selection=item.id;activate(item) }
                    .onTapGesture { selection=item.id;if activateOnClick { activate(item) } }
            }
        }.padding(2)
    }
    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if Self.scrolls { ScrollView(showsIndicators:false) { rows } } else { rows }
            }
            .focusable().focusEffectDisabled().focused($focused)
            .onKeyPress(.upArrow) { move(-1);return .handled }
            .onKeyPress(.downArrow) { move(1);return .handled }
            .onKeyPress(.return) { if let item=items.first(where:{ $0.id==selection }) { activate(item) };return .handled }
            .onAppear { focused=true;if selection==nil { selection=items.first?.id } }
            .onChange(of:selection) { _,id in if let id { withAnimation(.easeOut(duration:0.15)) { proxy.scrollTo(id,anchor:.center) } } }
        }
    }
}

/// The game's own controls, so menus are chips and arrows rather than the
/// desktop's pickers and steppers.
struct ChoiceChips<Value: Hashable>: View {
    let options: [(Value,String)]
    @Binding var selection: Value
    var disabled: Set<Value>=[]
    var body: some View {
        HStack(spacing:8) {
            ForEach(options,id:\.0) { value,title in
                Button(title) { selection=value }.buttonStyle(ChipStyle(selected:selection==value)).disabled(disabled.contains(value))
            }
        }
    }
}
struct ToggleChip: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing:8) {
                Circle().fill(isOn ? Color.white:Color.white.opacity(0.35)).frame(width:8,height:8)
                Text(isOn ? "On":"Off")
            }
        }.buttonStyle(ChipStyle(selected:isOn)).frame(width:74)
    }
}
struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack(spacing:6) {
            stepButton("minus") { value=max(range.lowerBound,value-1) }
            Text("\(value)").font(GameTheme.mono(16)).foregroundStyle(GameTheme.text).frame(width:36)
            stepButton("plus") { value=min(range.upperBound,value+1) }
        }
    }
    private func stepButton(_ symbol: String,action: @escaping ()->Void) -> some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:12,weight:.bold)).frame(width:30,height:30) }
            .buttonStyle(.plain).foregroundStyle(GameTheme.text).background(Circle().fill(Color.white.opacity(0.09)))
    }
}
/// ‹ name › over an ordered list, for the camera presets.
struct ArrowChooser<Value: Equatable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value)->String
    var width: CGFloat = 200
    private func step(_ delta: Int) {
        guard !options.isEmpty else { return }
        let index=options.firstIndex(of:selection) ?? 0
        selection=options[(index+delta+options.count)%options.count]
    }
    var body: some View {
        HStack(spacing:4) {
            arrow("chevron.left") { step(-1) }
            Text(title(selection)).font(GameTheme.label(14,weight:.semibold)).foregroundStyle(GameTheme.text).lineLimit(1).frame(width:width-68)
            arrow("chevron.right") { step(1) }
        }.padding(.vertical,4).padding(.horizontal,6).background(Capsule().fill(Color.white.opacity(0.07)))
    }
    private func arrow(_ symbol: String,action: @escaping ()->Void) -> some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:12,weight:.bold)).frame(width:26,height:24) }
            .buttonStyle(.plain).foregroundStyle(GameTheme.textSecondary)
    }
}

/// The application icon: the wordmark over a circuit outline on the game's
/// palette, drawn by the app itself so it matches the screens.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:186,style:.continuous)
                .fill(LinearGradient(colors:[GameTheme.inkLight,GameTheme.ink,.black],startPoint:.topLeading,endPoint:.bottomTrailing))
            Canvas { context,size in
                var band=Path()
                band.move(to:CGPoint(x:size.width*0.58,y:size.height));band.addLine(to:CGPoint(x:size.width*1.15,y:0))
                band.addLine(to:CGPoint(x:size.width*1.33,y:0));band.addLine(to:CGPoint(x:size.width*0.76,y:size.height))
                context.fill(band,with:.linearGradient(Gradient(colors:[GameTheme.accent.opacity(0.35),GameTheme.accent.opacity(0.0)]),startPoint:CGPoint(x:0,y:size.height),endPoint:CGPoint(x:size.width,y:0)))
                // A stylised circuit, sat above the wordmark.
                let w=size.width,h=size.height
                context.translateBy(x:w*0.5,y:h*0.42);context.scaleBy(x:0.9,y:0.9);context.translateBy(x:-w*0.5,y:-h*0.5)
                var track=Path()
                track.move(to:CGPoint(x:0.24*w,y:0.36*h))
                track.addCurve(to:CGPoint(x:0.70*w,y:0.30*h),control1:CGPoint(x:0.36*w,y:0.18*h),control2:CGPoint(x:0.58*w,y:0.16*h))
                track.addCurve(to:CGPoint(x:0.78*w,y:0.56*h),control1:CGPoint(x:0.84*w,y:0.36*h),control2:CGPoint(x:0.90*w,y:0.50*h))
                track.addCurve(to:CGPoint(x:0.50*w,y:0.62*h),control1:CGPoint(x:0.68*w,y:0.62*h),control2:CGPoint(x:0.60*w,y:0.54*h))
                track.addCurve(to:CGPoint(x:0.30*w,y:0.68*h),control1:CGPoint(x:0.40*w,y:0.70*h),control2:CGPoint(x:0.36*w,y:0.78*h))
                track.addCurve(to:CGPoint(x:0.24*w,y:0.36*h),control1:CGPoint(x:0.16*w,y:0.60*h),control2:CGPoint(x:0.14*w,y:0.44*h))
                context.stroke(track,with:.color(.white.opacity(0.92)),style:StrokeStyle(lineWidth:0.052*w,lineCap:.round,lineJoin:.round))
                let s=CGPoint(x:0.24*w,y:0.36*h),r=0.045*w
                context.fill(Path(ellipseIn:CGRect(x:s.x-r,y:s.y-r,width:2*r,height:2*r)),with:.color(GameTheme.accent))
            }.clipShape(RoundedRectangle(cornerRadius:186,style:.continuous))
            VStack {
                Spacer()
                Text("TORCS").font(GameTheme.display(150)).foregroundStyle(GameTheme.text).tracking(8).padding(.bottom,84)
            }
        }.frame(width:832,height:832).padding(96).frame(width:1024,height:1024)
    }
}
