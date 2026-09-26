// SPDX-License-Identifier: GPL-2.0-only
// The game's state: which screen is up, what the player is putting together
// (mode, circuit, car, options), the content library, and the race weekend
// the qualifying and race sessions share.
import SwiftUI
import Observation
import TORCSRaceEngine
import TORCSRender

@MainActor @Observable final class GameFlow {
    enum Screen: Equatable { case menu,trackSelect,carSelect,options,loading,driving,results,settings,controls,about }
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
    struct Plan: Equatable {
        var kind: RaceSessionKind = .practice
        var track: TrackDescriptor?
        var car: CarDescriptor?
        var laps=5
        var opponents=5
        var order: StartingOrder = .driversList
        var conditions: Conditions = .dry
        var cars: Int { kind == .practice ? 1:opponents+1 }
    }
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
        session.onFinished={ [weak self] frame in self?.sessionFinished(frame) }
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
    var entry: ContentLibraryEntry? {
        guard let track=plan.track,let car=plan.car else { return nil }
        return library.entry(track:track.id,car:car.id)
    }
    func refreshLibrary() {
        scanTask?.cancel();scanning=true
        let roots=preferences.rootURLs+launchRoots
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
        let tracks=library.tracks
        if plan.track==nil || !tracks.contains(where:{ $0.id==plan.track?.id }) {
            plan.track=tracks.first { $0.id==preferences.lastTrack } ?? tracks.first
        }
        if let track=plan.track {
            let cars=library.cars(on:track)
            if plan.car==nil || !cars.contains(where:{ $0.id==plan.car?.id }) {
                plan.car=cars.first { $0.id==preferences.lastCar } ?? cars.first
            }
        } else { plan.car=nil }
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
        plan.kind=kind
        if kind == .race,!qualifyingOrderAvailable { plan.order = .driversList }
        screen = .trackSelect
    }
    func selectTrack(_ track: TrackDescriptor) {
        plan.track=track
        let cars=library.cars(on:track)
        if !cars.contains(where:{ $0.id==plan.car?.id }) { plan.car=cars.first }
        screen = .carSelect
    }
    func selectCar(_ car: CarDescriptor) { plan.car=car;screen = .options }
    func open(_ target: Screen) {
        if screen == .driving || screen == .results {
            overlay=target == .controls ? .controls:.settings;session.suspend();return
        }
        if target != screen,![.settings,.controls,.about].contains(screen) { returnScreen=screen }
        screen=target
    }
    func closeOverlay() { overlay=nil }
    func back() {
        switch screen {
        case .trackSelect: screen = .menu
        case .carSelect: screen = .trackSelect
        case .options: screen = .carSelect
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
    func startSession() {
        guard let entry else { message="Choose a circuit and a car first.";return }
        qualifyingTask?.cancel();qualifyingTask=nil
        preferences.lastTrack=entry.track.id;preferences.lastCar=entry.car.id;savePreferences()
        session.selectedSessionKind=plan.kind;session.selectedLaps=plan.laps;session.selectedCars=plan.cars
        session.wet=plan.conditions == .wet;session.rain=plan.conditions == .rain;session.overcast=plan.conditions == .overcast
        prepareWeekend()
        message=nil;sessionStarted=false;overlay=nil
        if session.content != nil,session.contentDirectory==entry.directory {
            // The same circuit and car: no reload, a fresh run.
            session.restart();screen = .driving;return
        }
        screen = .loading
        Task {
            let loaded=await session.load(entry.directory)
            guard screen == .loading else { return }
            if loaded { screen = .driving } else { message=session.message ?? "The session could not be loaded.";screen = .options }
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
        prepareWeekend();sessionStarted=false;overlay=nil
        session.restart();screen = .driving
    }
    func endSession() { session.endSession() }
    private func sessionFinished(_ frame: DrivingFrame) {
        screen = .results;overlay=nil
        guard frame.configuration.kind == .qualifying,session.weekend.qualifying==0 else { return }
        do {
            try session.weekend.recordQualifying(car:0,bestLapTime:Float(frame.result?.bestLap ?? 0))
            simulateOpponentQualifying()
        } catch { message="Qualifying could not be recorded: \(error)" }
    }
    /// The opponents' runs, one after another, headless, while the player
    /// reads their own result.
    private func simulateOpponentQualifying() {
        guard let content=session.content else { return }
        let road=content.simulation.road,parameters=content.carParameters,laps=plan.laps
        let cars=session.weekend.cars
        qualifyingDone=session.weekend.qualifyingComplete
        guard !qualifyingDone else { return }
        qualifyingTask=Task { [weak self] in
            for car in 1..<cars {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.qualifyingCar=car;self?.qualifyingFraction=0 }
                let outcome: QualifyingSimulation.Outcome?
                do {
                    outcome=try await Task.detached(priority:.userInitiated) {
                        try QualifyingSimulation.run(road:road,parameters:parameters,laps:laps,seed:12345 &+ UInt32(car)*7919,
                            progress:{ fraction in Task { @MainActor in self?.qualifyingFraction=fraction } },
                            cancelled:{ Task.isCancelled })
                    }.value
                } catch {
                    await MainActor.run { self?.message="Opponent qualifying failed: \(error)" }
                    outcome=nil
                }
                guard !Task.isCancelled,let self else { return }
                do { try session.weekend.recordQualifying(car:car,bestLapTime:outcome?.gridTime ?? 0) }
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
        qualifyingTask?.cancel();qualifyingTask=nil
        session.unload();overlay=nil;sessionStarted=false
        screen = .menu
    }
    func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }
    var isFullScreen: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
}
