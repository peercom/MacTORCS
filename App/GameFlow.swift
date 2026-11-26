// SPDX-License-Identifier: GPL-2.0-only
// The game's state: which screen is up, what the player is putting together
// (mode, circuit, car, options), the content library, and the race weekend
// the qualifying and race sessions share.
import SwiftUI
import Observation
import TORCSRaceEngine
import TORCSRender
import TORCSInput

@MainActor @Observable final class GameFlow {
    enum Screen: Equatable { case menu,trackSelect,carSelect,options,loading,driving,results,settings,controls,about,championship,championshipSetup }
    /// Panels shown over a live session without tearing its renderer down.
    enum Overlay: Equatable { case settings,controls }
    enum Conditions: String,CaseIterable,Identifiable {
        case dry="Dry",wet="Wet",overcast="Overcast",rain="Rain"
        var id: String { rawValue }
        var summary: String {
            switch self {
            case .dry:"Clear sky, dry road";case .wet:"Wet road, spray, dry sky";case .overcast:"Cloud cover, dry road";case .rain:"Rain, wet road"
            }
        }
    }
    /// What the opponents drive.
    enum Rivals: String,CaseIterable,Identifiable {
        case sameCar="Your car",sameClass="Your class",mixed="Any car"
        var id: String { rawValue }
        var summary: String {
            switch self {
            case .sameCar:"Everyone drives the car you chose"
            case .sameClass:"Opponents take other cars of your car's class"
            case .mixed:"Opponents take the cars closest to yours in power to weight, whatever the class"
            }
        }
    }
    /// How hard the opponents push: the share of their throttle they get.
    enum Difficulty: String,CaseIterable,Identifiable {
        case easy="Easy",medium="Medium",hard="Hard"
        var id: String { rawValue }
        var pace: Float { switch self { case .easy:0.78;case .medium:0.9;case .hard:1 } }
        var summary: String {
            switch self {
            case .easy:"Opponents lift early on the straights"
            case .medium:"Opponents hold a little back"
            case .hard:"The original drivers at their own pace"
            }
        }
    }
    struct Plan: Equatable {
        var kind: RaceSessionKind = .practice
        var difficulty=Difficulty(rawValue:UserDefaults.standard.string(forKey:"difficulty") ?? "") ?? .medium
        var track: TrackDescriptor?
        var car: CarDescriptor?
        var laps=5
        var opponents=5
        var order: StartingOrder = .driversList
        var conditions: Conditions = .dry
        var rivals: Rivals = .sameClass
        var cars: Int { kind == .practice ? 1:opponents+1 }
    }
    /// How many different car models one field holds, the player's included:
    /// each is a body and wheels uploaded to the GPU.
    static let maximumFieldModels=4
    /// Who the opponents are. Invented names, in grid-entry order.
    static let driverRoster=["A. Moretti","K. Lindqvist","J. Okafor","T. Brandt","S. Nakamura","L. Duval","M. Ferreira",
                             "R. Kowalski","D. Hartmann","P. Olsen","E. Varga","C. Ibarra","N. Petrov","H. Sorensen","G. Rinaldi"]
    var screen: Screen = .menu
    var overlay: Overlay?
    private var returnScreen: Screen = .menu
    var plan=Plan()
    let session: DrivingSession
    var library=ContentLibrary()
    var preferences=ContentLibraryPreferences()
    var libraryWarnings: [String]=[]
    var scanning=false
    var message: String?
    /// The session has been sent off: its countdown has started once.
    var sessionStarted=false
    /// The opponents' qualifying runs, simulated after the player's own.
    var qualifyingCar: Int?
    var qualifyingFraction: Double = 0
    var qualifyingDone=false
    /// The player's best laps, and whether the session just finished set one.
    var records=LapRecords()
    var newRecord=false
    @ObservationIgnored private let recordsStore=try? LapRecordsStore()
    /// The season in progress, the round on screen if the session is one of
    /// its races, and what a new season is being set up with.
    var championship: Championship?
    var championshipRound: Int?
    var seasonRounds=5
    private var settingUpChampionship=false
    @ObservationIgnored private let championshipStore=try? ChampionshipStore()
    /// The pairing the weekend's ranking was set on; a grid only describes
    /// the field that set it.
    private var weekendTrack: String?
    private var weekendCar: String?
    @ObservationIgnored private var qualifyingTask: Task<Void,Never>?
    @ObservationIgnored private var scanTask: Task<Void,Never>?
    private let store: ContentLibraryStore?

    init(session: DrivingSession) {
        self.session=session
        store=try? ContentLibraryStore()
        if let store {
            do { preferences=try store.load() } catch { message="Content settings could not be read: \(error)" }
        }
        if let recordsStore { do { records=try recordsStore.load() } catch { message="Lap records could not be read: \(error)" } }
        if let championshipStore { do { championship=try championshipStore.load() } catch { message="The saved championship could not be read: \(error)" } }
        session.onFinished={ [weak self] frame in self?.sessionFinished(frame) }
        session.onMenuButton={ [weak self] element in self?.menuButton(element) }
        let controllerTimer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.pollControllerForMenus() }
        }
        RunLoop.main.add(controllerTimer,forMode:.common)
        // `--content DIR` adds a content folder for this launch without
        // saving it; `--screen NAME` opens on a screen, for screenshots.
        let arguments=CommandLine.arguments
        for (index,argument) in arguments.enumerated() where argument=="--content" && index+1<arguments.count {
            launchRoots.append(URL(fileURLWithPath:arguments[index+1]))
        }
        if let index=arguments.firstIndex(of:"--screen"),index+1<arguments.count {
            switch arguments[index+1] {
            case "trackSelect": screen = .trackSelect;case "carSelect": screen = .carSelect;case "options": screen = .options
            case "settings": screen = .settings;case "controls": screen = .controls;case "about": screen = .about
            case "seasonSetup": settingUpChampionship=true;plan.kind = .race;screen = .championshipSetup
            case "season": screen = .championship
            case "training": plan.kind = .practice;screen = .options
            case "qualifying": plan.kind = .qualifying;screen = .options
            case "race": plan.kind = .race;screen = .options
            default: break
            }
        }
        refreshLibrary()
    }
    @ObservationIgnored private var launchRoots: [URL]=[]

    // MARK: Content
    /// The plan is drivable: a circuit and a car are chosen.
    var ready: Bool { plan.track != nil && plan.car != nil }
    /// The other car models the planned field uses, nearest rival first.
    var rivalCars: [CarDescriptor] {
        guard let car=plan.car,plan.kind != .practice,plan.opponents>0,plan.rivals != .sameCar else { return [] }
        var pool=library.rivals(of:car,sameClass:plan.rivals == .sameClass).dropFirst()
        // A car alone in its class races the nearest cars of any class.
        if pool.isEmpty { pool=library.rivals(of:car,sameClass:false).dropFirst() }
        return Array(pool.prefix(min(Self.maximumFieldModels-1,plan.opponents)))
    }
    /// The player's car has no class-mates in the library.
    var aloneInClass: Bool {
        guard let car=plan.car else { return false }
        return library.rivals(of:car,sameClass:true).count==1
    }
    /// The car each field entry drives; entry 0 is the player.
    var fieldCars: [CarDescriptor] {
        guard let car=plan.car else { return [] }
        let rivals=rivalCars
        return (0..<plan.cars).map { $0==0 || rivals.isEmpty ? car:rivals[($0-1)%rivals.count] }
    }
    /// The folder the game keeps its own content in, scanned without being
    /// added.
    var defaultContentDirectory: URL? { store?.defaultContentDirectory }
    func refreshLibrary() {
        scanTask?.cancel();scanning=true
        var found=preferences.rootURLs+launchRoots
        if let builtIn=defaultContentDirectory,FileManager.default.fileExists(atPath:builtIn.path),
           !found.contains(where:{ $0.standardizedFileURL==builtIn.standardizedFileURL }) { found.insert(builtIn,at:0) }
        let roots=found
        scanTask=Task {
            let scanned=await Task.detached(priority:.userInitiated) { ContentLibrary.scan(roots:roots) }.value
            guard !Task.isCancelled else { return }
            library=scanned.library;libraryWarnings=scanned.warnings;scanning=false
            reconcilePlan()
        }
    }
    /// Keep the plan pointing at content that exists, preferring what was
    /// driven last.
    private func reconcilePlan() {
        // The descriptor is taken afresh: a rescan may have moved the package.
        plan.track=library.track(plan.track?.id) ?? library.track(preferences.lastTrack) ?? library.tracks.first
        plan.car=library.car(plan.car?.id) ?? library.car(preferences.lastCar) ?? library.cars.first
    }
    private func savePreferences() {
        guard let store else { return }
        do { try store.save(preferences) } catch { message="Content settings could not be saved: \(error)" }
    }
    func addContentFolder() {
        session.suspend()
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=true
        panel.message="Choose a folder of prepared driving sessions. Every folder holding a driving.json beneath it is added."
        panel.prompt="Add"
        let completion: (NSApplication.ModalResponse)->Void = { [weak self] response in
            guard let self,response == .OK else { return }
            for url in panel.urls { preferences.add(url) }
            savePreferences();refreshLibrary()
        }
        if let window=NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    func removeContentFolder(_ path: String) { preferences.remove(path);savePreferences();refreshLibrary() }

    // MARK: Navigation
    func choose(_ kind: RaceSessionKind) {
        settingUpChampionship=false
        plan.kind=kind
        if kind == .race,!qualifyingOrderAvailable { plan.order = .driversList }
        screen = .trackSelect
    }
    func selectTrack(_ track: TrackDescriptor) { plan.track=track;screen = .carSelect }
    func selectCar(_ car: CarDescriptor) { plan.car=car;screen=settingUpChampionship ? .championshipSetup:.options }
    /// Whether the car screen is choosing a season's car rather than a session's.
    var choosingSeasonCar: Bool { settingUpChampionship }
    func open(_ target: Screen) {
        if screen == .driving || screen == .results {
            overlay=target == .controls ? .controls:.settings;session.suspend();return
        }
        if target != screen,![.settings,.controls,.about].contains(screen) { returnScreen=screen }
        screen=target
    }
    func closeOverlay() { overlay=nil }
    func back() {
        GameAudio.shared.ui(.back)
        switch screen {
        case .trackSelect: screen = .menu
        case .carSelect: screen=settingUpChampionship ? .menu:.trackSelect
        case .options: screen = .carSelect
        case .championship: screen = .menu
        case .championshipSetup: screen = .carSelect
        case .settings,.controls,.about: screen=returnScreen
        default: break
        }
    }

    // MARK: The weekend
    /// A race may start from the qualifying order only for the field that
    /// qualified on this pairing.
    var qualifyingOrderAvailable: Bool {
        session.weekend.qualifyingComplete && session.weekend.startingOrder != .driversList
            && session.weekend.cars==plan.opponents+1 && weekendTrack==plan.track?.id && weekendCar==plan.car?.id
    }
    private func prepareWeekend() {
        let cars=plan.cars
        switch plan.kind {
        case .practice:
            session.weekend=(try? RaceWeekend(cars:1)) ?? session.weekend
        case .qualifying:
            // A fresh weekend: the player qualifies first, the field after.
            session.weekend=(try? RaceWeekend(cars:cars,startingOrder:.lastRace)) ?? session.weekend
            weekendTrack=plan.track?.id;weekendCar=plan.car?.id
            qualifyingCar=nil;qualifyingFraction=0;qualifyingDone=false
        case .race:
            if plan.order != .driversList,qualifyingOrderAvailable {
                session.weekend.startingOrder=plan.order
            } else {
                plan.order = .driversList
                session.weekend=(try? RaceWeekend(cars:cars,startingOrder:.driversList)) ?? session.weekend
            }
        }
    }

    // MARK: Sessions
    /// Start what the plan describes. A championship round supplies its own
    /// field and grid; everything else takes them from the plan.
    func startSession(season: Championship? = nil) {
        guard let track=plan.track,let car=plan.car else { message="Choose a circuit and a car first.";return }
        if season==nil { championshipRound=nil }
        qualifyingTask?.cancel();qualifyingTask=nil
        preferences.lastTrack=track.id;preferences.lastCar=car.id;savePreferences()
        session.selectedSessionKind=plan.kind;session.selectedLaps=plan.laps;session.selectedCars=plan.cars
        session.wet=plan.conditions == .wet;session.rain=plan.conditions == .rain;session.overcast=plan.conditions == .overcast
        session.opponentPace=plan.difficulty.pace
        UserDefaults.standard.set(plan.difficulty.rawValue,forKey:"difficulty")
        // Who drives what: the distinct rival models after the player's,
        // and each entry's index into them.
        var rivals=rivalCars
        if let season {
            // The season's own cars, in the order they first appear.
            var seen=Set([car.id])
            rivals=season.entrants.dropFirst().compactMap { seen.insert($0.car).inserted ? library.car($0.car):nil }
            let models=[car]+rivals
            session.fieldModels=season.entrants.map { entrant in models.firstIndex { $0.id==entrant.car } ?? 0 }
            session.fieldNames=season.entrants.map(\.name)
            session.gridOverride=season.grid
            session.weekend=(try? RaceWeekend(cars:season.entrants.count,startingOrder:.driversList)) ?? session.weekend
        } else {
            let models=[car]+rivals
            session.fieldModels=fieldCars.map { entry in models.firstIndex { $0.id==entry.id } ?? 0 }
            session.fieldNames=(0..<plan.cars).map { $0==0 ? "You":Self.driverRoster[($0-1)%Self.driverRoster.count] }
            session.gridOverride=nil
            prepareWeekend()
        }
        message=nil;sessionStarted=false;overlay=nil;newRecord=false
        let opponents=rivals.map(\.directory)
        if session.content != nil,session.contentKey==DrivingSession.key(track:track.directory,car:car.directory,opponents:opponents) {
            // The same circuit and cars: no reload, a fresh run.
            session.restart();screen = .driving;return
        }
        screen = .loading
        Task {
            let loaded=await session.load(track:track.directory,car:car.directory,opponents:opponents)
            guard screen == .loading else { return }
            if loaded { screen = .driving }
            else { message=session.message ?? "The session could not be loaded.";screen=championshipRound==nil ? .options:.championship }
        }
    }
    /// The renderer has drawn its first frame: send the car off.
    func sessionReady() {
        guard !sessionStarted,session.content != nil,session.frame?.result==nil else { return }
        sessionStarted=true
        if session.paused { session.togglePause() }
    }
    func resume() { overlay=nil;if session.paused { session.togglePause() } }
    func restartSession() {
        guard session.content != nil else { return }
        qualifyingTask?.cancel();qualifyingTask=nil
        if championshipRound==nil { prepareWeekend() }
        sessionStarted=false;overlay=nil;newRecord=false
        session.restart();screen = .driving
    }
    func endSession() { session.endSession() }
    private func sessionFinished(_ frame: DrivingFrame) {
        screen = .results;overlay=nil
        GameAudio.shared.silence()
        // A best valid lap counts in any kind of session.
        newRecord=false
        if let best=frame.result?.bestLap,let track=plan.track,let car=plan.car,
           records.submit(track:track.id,car:car.id,time:best,date:Date()) {
            newRecord=true;GameAudio.shared.ui(.record)
            do { try recordsStore?.save(records) } catch { message="Lap records could not be saved: \(error)" }
        }
        // A championship round that ran its course goes into the table. One
        // ended from the pause menu does not: it can be run again.
        if let round=championshipRound,var season=championship,let race=frame.raceResult,race.reason != .endedEarly {
            do {
                try season.record(round:round,classification:race.classification.map { session.entrant($0) })
                championship=season
                try championshipStore?.save(season)
            } catch { message="The round could not be recorded: \(error)" }
        }
        guard frame.configuration.kind == .qualifying,session.weekend.qualifying==0 else { return }
        do {
            try session.weekend.recordQualifying(car:0,bestLapTime:Float(frame.result?.bestLap ?? 0),name:"You")
            simulateOpponentQualifying()
        } catch { message="Qualifying could not be recorded: \(error)" }
    }
    /// The opponents' runs, one after another, headless, while the player
    /// reads their own result.
    private func simulateOpponentQualifying() {
        guard let content=session.content else { return }
        let road=content.simulation.road,laps=plan.laps,pace=plan.difficulty.pace
        let cars=session.weekend.cars
        let parameters=(0..<cars).map { content.models[session.model(ofEntrant:$0)].parameters }
        let names=(0..<cars).map { session.entrantName($0) }
        qualifyingDone=session.weekend.qualifyingComplete
        guard !qualifyingDone else { return }
        qualifyingTask=Task { [weak self] in
            for car in 1..<cars {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.qualifyingCar=car;self?.qualifyingFraction=0 }
                let outcome: QualifyingSimulation.Outcome?
                do {
                    outcome=try await Task.detached(priority:.userInitiated) {
                        try QualifyingSimulation.run(road:road,parameters:parameters[car],laps:laps,seed:12345 &+ UInt32(car)*7919,pace:pace,
                            progress:{ fraction in Task { @MainActor in self?.qualifyingFraction=fraction } },
                            cancelled:{ Task.isCancelled })
                    }.value
                } catch {
                    await MainActor.run { self?.message="Opponent qualifying failed: \(error)" }
                    outcome=nil
                }
                guard !Task.isCancelled,let self else { return }
                do { try session.weekend.recordQualifying(car:car,bestLapTime:outcome?.gridTime ?? 0,name:names[car]) }
                catch { message="Qualifying could not be recorded: \(error)" }
            }
            guard let self,!Task.isCancelled else { return }
            qualifyingCar=nil;qualifyingDone=session.weekend.qualifyingComplete
        }
    }
    /// From a finished qualifying to the race it set the grid for.
    func proceedToRace() {
        guard qualifyingDone else { return }
        plan.kind = .race;plan.order = .lastRace
        screen = .options
    }
    func changeSetup() {
        qualifyingTask?.cancel();qualifyingTask=nil
        screen = .options
    }
    func quitToMenu() {
        GameAudio.shared.silence()
        qualifyingTask?.cancel();qualifyingTask=nil
        session.unload();overlay=nil;sessionStarted=false
        championshipRound=nil
        screen = .menu
    }

    // MARK: Controller in the menus
    /// What a list on screen does with the pad: move its selection or
    /// activate it.
    static let menuMove=Notification.Name("org.torcs.mac.menuMove")
    static let menuActivate=Notification.Name("org.torcs.mac.menuActivate")
    /// The d-pad moves through a list, the south button chooses or confirms
    /// the screen's main action, the east button goes back. The menu button
    /// pauses and resumes a race, as it always did.
    private func menuButton(_ element: ControllerElement) {
        switch element {
        case .dpadUp: NotificationCenter.default.post(name:Self.menuMove,object:-1)
        case .dpadDown: NotificationCenter.default.post(name:Self.menuMove,object:1)
        case .menu where screen == .driving: resume()
        case .south:
            switch screen {
            case .menu,.trackSelect,.carSelect: NotificationCenter.default.post(name:Self.menuActivate,object:nil)
            case .options: GameAudio.shared.ui(.select);startSession()
            case .championshipSetup: GameAudio.shared.ui(.select);startSeason()
            case .championship: if championship?.isComplete==false { GameAudio.shared.ui(.select);startSeasonRound() }
            case .driving: if overlay==nil { resume() }
            case .results:
                if championshipRound != nil { showSeason() }
                else if plan.kind == .qualifying { proceedToRace() }
                else { restartSession() }
            case .settings,.controls,.about: back()
            case .loading: break
            }
        case .east:
            switch screen {
            case .driving: if overlay != nil { closeOverlay() } else { resume() }
            case .results: quitToMenu()
            case .loading,.menu: break
            default: back()
            }
        default: break
        }
    }

    // MARK: Championship
    /// The championship menu entry: the season in progress, or a new one.
    func openChampionship() {
        if championship != nil { screen = .championship }
        else { settingUpChampionship=true;plan.kind = .race;screen = .carSelect }
    }
    /// The circuits a new season of `seasonRounds` rounds visits: spread
    /// across the library by length, shortest first.
    var seasonTracks: [TrackDescriptor] {
        let byLength=library.tracks.sorted { ($0.length,$0.id)<($1.length,$1.id) }
        let count=min(max(seasonRounds,1),byLength.count)
        guard count>0 else { return [] }
        if count==byLength.count { return byLength }
        return (0..<count).map { byLength[count==1 ? 0:$0*(byLength.count-1)/(count-1)] }
    }
    func startSeason() {
        guard let car=plan.car else { return }
        let cars=fieldCars
        let entrants=cars.enumerated().map { index,entry in
            Championship.Entrant(name:index==0 ? "You":Self.driverRoster[(index-1)%Self.driverRoster.count],car:entry.id)
        }
        do {
            let season=try Championship(entrants:entrants.isEmpty ? [.init(name:"You",car:car.id)]:entrants,tracks:seasonTracks.map(\.id),laps:plan.laps)
            championship=season;try championshipStore?.save(season)
            settingUpChampionship=false;message=nil
            screen = .championship
        } catch { message="\(error)" }
    }
    func abandonSeason() {
        championship=nil;championshipRound=nil
        do { try championshipStore?.clear() } catch { message="The championship could not be removed: \(error)" }
        screen = .menu
    }
    /// What stops the next round from starting, if anything: content the
    /// season needs that is no longer in the library.
    var seasonProblem: String? {
        guard let season=championship,let round=season.nextRound else { return nil }
        if library.track(season.rounds[round].track)==nil { return "The circuit \(season.rounds[round].track) is not in the library." }
        if let missing=season.entrants.first(where:{ library.car($0.car)==nil }) { return "The car \(missing.car) is not in the library." }
        return nil
    }
    func startSeasonRound() {
        guard let season=championship,let round=season.nextRound,seasonProblem==nil,
              let track=library.track(season.rounds[round].track),let car=library.car(season.entrants[0].car) else { return }
        plan.kind = .race;plan.track=track;plan.car=car;plan.laps=season.laps;plan.opponents=season.entrants.count-1
        plan.order = .driversList
        championshipRound=round
        startSession(season:season)
    }
    func showSeason() {
        qualifyingTask?.cancel();qualifyingTask=nil
        session.unload();overlay=nil;sessionStarted=false;championshipRound=nil
        screen = .championship
    }
    func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }
    var isFullScreen: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
}
