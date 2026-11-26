// SPDX-License-Identifier: GPL-2.0-only
// The game's sound: looping samples whose pitch, volume and filter follow
// the original's car sound model, one-shots for gears and impacts, and the
// menus' ticks. The install's own samples are used when the library has
// them; generated stand-ins otherwise, through the same players.
@preconcurrency import AVFoundation
import simd
import TORCSPresentation
import TORCSRaceEngine
import TORCSSimulation
import TORCSTrack

@MainActor final class GameAudio {
    static let shared=GameAudio()
    /// Offscreen runs make no sound.
    static var enabled: Bool { !CommandLine.arguments.contains { ["--screenshot","--render-preview","--render-icon"].contains($0) } }
    enum Cue { case move,select,back,light,go,record }

    /// A looping sample with its own speed and filter.
    private final class Voice {
        let player=AVAudioPlayerNode(),speed=AVAudioUnitVarispeed(),filter=AVAudioUnitEQ(numberOfBands:1)
        var key=""
        /// Room for a field of engines and the tyres to sum without clipping.
        static let headroom: Float = 0.6
        func set(_ voice: SoundVoice,gain: Float) {
            player.volume=max(0,min(gain,1))*Self.headroom
            speed.rate=max(0.25,min(voice.pitch,4))
            // The filter's opening, 0…1, as a cutoff from 500 Hz to 20 kHz.
            filter.bands[0].frequency=min(20_000,500*pow(40,max(0,min(voice.lowPass,1))))
        }
    }
    private let engine=AVAudioEngine()
    private let format=AVAudioFormat(standardFormatWithSampleRate:SyntheticSound.sampleRate,channels:1)!
    private var started=false,failed=false
    /// Engine voices: the player's car, then the nearest opponents.
    private var engines: [Voice]=[]
    private var loops: [String:Voice]=[:]
    private var shots: [AVAudioPlayerNode]=[]
    private var nextShot=0
    private var buffers: [String:AVAudioPCMBuffer]=[:]
    private var models: [CarSoundModel]=[]
    /// Which buffer each car model's engine plays, and its red line.
    private var engineKeys: [String]=[]
    private var redLines: [Float]=[]
    private var soundRoot: URL?
    private var lastUpdate=0.0,lastCollisionTick: [Int]=[]
    private var lightsLit=0,wasPrestart=false
    private var lastCrash=0.0
    private var silent=true
    /// How many samples came from the library's files rather than stand-ins,
    /// for diagnostics.
    private(set) var filesLoaded=0,standInsMade=0
    var status: String { "audio started=\(started) failed=\(failed) files=\(filesLoaded) standIns=\(standInsMade) engines=\(engineKeys)" }
    var volume: Float = Float(UserDefaults.standard.object(forKey:"volume") as? Double ?? 0.8) {
        didSet { engine.mainMixerNode.outputVolume=volume }
    }

    private func start() {
        guard !started,!failed,Self.enabled else { return }
        func loop(_ name: String) {
            let voice=Voice()
            voice.filter.bands[0].filterType = .lowPass;voice.filter.bands[0].bypass=false;voice.filter.bands[0].frequency=20_000
            engine.attach(voice.player);engine.attach(voice.speed);engine.attach(voice.filter)
            engine.connect(voice.player,to:voice.speed,format:format)
            engine.connect(voice.speed,to:voice.filter,format:format)
            engine.connect(voice.filter,to:engine.mainMixerNode,format:format)
            voice.player.volume=0
            if name.hasPrefix("engine") { engines.append(voice) } else { loops[name]=voice }
        }
        for index in 0..<5 { loop("engine\(index)") }
        for name in ["skid","road","grass","grassSkid","curb","turbo"] { loop(name) }
        for _ in 0..<6 {
            let player=AVAudioPlayerNode()
            engine.attach(player);engine.connect(player,to:engine.mainMixerNode,format:format)
            shots.append(player)
        }
        engine.mainMixerNode.outputVolume=volume
        do { try engine.start();started=true } catch { failed=true;return }
        // The one-shot players run from now on: starting a player waits for
        // the audio thread's next cycle, which must not happen mid-race on
        // the thread that draws. A sound is then only scheduled onto one.
        for player in shots { player.play() }
        buffers["ui.move"]=buffer(SyntheticSound.blip(frequency:880,seconds:0.04))
        buffers["ui.select"]=buffer(SyntheticSound.blip(frequency:1320,seconds:0.08))
        buffers["ui.back"]=buffer(SyntheticSound.blip(frequency:660,seconds:0.07))
        buffers["ui.light"]=buffer(SyntheticSound.blip(frequency:440,seconds:0.14))
        buffers["ui.go"]=buffer(SyntheticSound.blip(frequency:880,seconds:0.5))
        buffers["ui.record"]=buffer(SyntheticSound.blip(frequency:1760,seconds:0.3))
    }
    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength=AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from:$0.baseAddress!,count:samples.count) }
        return buffer
    }
    /// A sample file as mono at the engine's rate, whatever it was recorded as.
    private func load(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file=try? AVAudioFile(forReading:url),file.length>0,file.length<Int64(format.sampleRate*60),
              let source=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)),
              (try? file.read(into:source)) != nil else { return nil }
        if file.processingFormat==format { return source }
        guard let converter=AVAudioConverter(from:file.processingFormat,to:format) else { return nil }
        let capacity=AVAudioFrameCount(Double(source.frameLength)*format.sampleRate/file.processingFormat.sampleRate)+64
        guard let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:capacity) else { return nil }
        // The converter asks once for the whole file, then is told it has ended.
        nonisolated(unsafe) var supplied=false
        nonisolated(unsafe) let input=source
        var error: NSError?
        converter.convert(to:output,error:&error) { _,status in
            if supplied { status.pointee = .endOfStream;return nil }
            supplied=true;status.pointee = .haveData;return input
        }
        return error==nil && output.frameLength>0 ? output:nil
    }
    /// The named sample from the library, or the stand-in made for it.
    private func sample(_ key: String,file: String,standIn: ()->[Float]) -> AVAudioPCMBuffer? {
        if let cached=buffers[key] { return cached }
        if let recorded=soundRoot.flatMap({ ContentPackage.sound(file,for:$0) }).flatMap({ load($0) }) {
            filesLoaded += 1;buffers[key]=recorded;return recorded
        }
        standInsMade += 1
        let made=buffer(standIn())
        buffers[key]=made
        return made
    }
    private func play(_ voice: Voice,key: String,buffer: AVAudioPCMBuffer?) {
        guard let buffer,voice.key != key else { return }
        voice.player.stop()
        voice.player.scheduleBuffer(buffer,at:nil,options:[.loops])
        voice.player.play();voice.key=key
    }
    private func shot(_ key: String,gain: Float) {
        guard started,let buffer=buffers[key] else { return }
        let player=shots[nextShot];nextShot=(nextShot+1)%shots.count
        player.volume=max(0,min(gain,1))
        player.scheduleBuffer(buffer,at:nil,options:[.interrupts])
    }
    func ui(_ cue: Cue) {
        start()
        switch cue {
        case .move:shot("ui.move",gain:0.25);case .select:shot("ui.select",gain:0.3);case .back:shot("ui.back",gain:0.25)
        case .light:shot("ui.light",gain:0.5);case .go:shot("ui.go",gain:0.5);case .record:shot("ui.record",gain:0.35)
        }
    }

    /// Take a loaded session's cars: an engine note and a sound model per
    /// model, and the shared samples from the library the content came from.
    func prepare(_ content: DrivingContent) {
        start()
        guard started else { return }
        soundRoot=content.car.directory
        // Samples differ between libraries; the shared ones are looked up again.
        for key in buffers.keys where !key.hasPrefix("ui.") { buffers[key]=nil }
        engineKeys=[];redLines=[];models=[]
        for model in content.models {
            let key="engine."+model.sound.engineSample
            // The stand-in's character follows the car: more cylinders, a smoother note.
            let cylinders=[4,6,8,10,12][abs(model.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })%5]
            let root=soundRoot
            soundRoot=model.directory
            _=sample(key,file:model.sound.engineSample) { SyntheticSound.engineLoop(cylinders:cylinders) }
            soundRoot=root
            engineKeys.append(key);redLines.append(model.sound.redLine)
            models.append(CarSoundModel(rpmScale:model.sound.rpmScale,turbo:model.sound.turbo,turboSpeed:model.sound.turboSpeed,turboLag:model.sound.turboLag))
        }
        play(loops["skid"]!,key:"skid",buffer:sample("skid",file:"skid_tyres.wav") { SyntheticSound.skidLoop() })
        play(loops["road"]!,key:"road",buffer:sample("road",file:"road-ride.wav") { SyntheticSound.noiseLoop(low:60,high:900,seed:11) })
        play(loops["grass"]!,key:"grass",buffer:sample("grass",file:"out_of_road.wav") { SyntheticSound.noiseLoop(low:120,high:2400,seed:12) })
        play(loops["grassSkid"]!,key:"grassSkid",buffer:sample("grassSkid",file:"out_of_road-3.wav") { SyntheticSound.noiseLoop(low:300,high:4000,seed:13) })
        play(loops["curb"]!,key:"curb",buffer:sample("curb",file:"curb_ride.wav") { SyntheticSound.noiseLoop(low:40,high:300,seed:14) })
        play(loops["turbo"]!,key:"turbo",buffer:sample("turbo",file:"turbo1.wav") { SyntheticSound.noiseLoop(low:2500,high:7000,seed:15) })
        buffers["gear"]=sample("gear",file:"gear_change1.wav") { SyntheticSound.impact(seconds:0.12,tone:140,noiseShare:0.5,seed:21) }
        for index in 1...6 {
            buffers["crash\(index)"]=sample("crash\(index)",file:"crash\(index).wav") { SyntheticSound.impact(seconds:0.6,tone:90,noiseShare:0.85,seed:UInt64(30+index)) }
        }
        lastCollisionTick=[];lastUpdate=0;lightsLit=0;wasPrestart=false
        silence()
    }
    /// Every loop down to nothing: a pause, a menu, the end of a session.
    func silence() {
        guard started,!silent else { return }
        silent=true
        for voice in engines+Array(loops.values) { voice.player.volume=0 }
    }

    /// One step of the sound model from the session's newest frame. Called
    /// from the session's timer; the model runs at its own hundred updates a
    /// second whatever that cadence is.
    func update(frame: DrivingFrame,content: DrivingContent,models assignment: (Int)->Int,throttle: Float,now: Double) {
        guard started,!models.isEmpty,now-lastUpdate>=CarSoundModel.updateInterval*0.8 else { return }
        lastUpdate=now;silent=false
        let viewer=frame.field.indices.contains(frame.viewer) ? frame.viewer:0
        guard frame.field.indices.contains(viewer) else { return }
        // The start lights: a beep as each comes on, a longer one as they go out.
        if frame.phase == .prestart {
            let lit=min(5,max(0,Int(((frame.raceTime+2)/2*5).rounded(.down))+1))
            if lit>lightsLit { ui(.light) }
            lightsLit=lit;wasPrestart=true
        } else if wasPrestart { wasPrestart=false;lightsLit=0;ui(.go) }
        if lastCollisionTick.count != frame.field.count { lastCollisionTick=frame.field.map { $0.presentation.collisions.lastCollisionTick } }
        let here=frame.field[viewer].current.body.position
        let finished=frame.result != nil

        // The player's own car, heard in full.
        let own=frame.field[viewer],model=min(assignment(viewer),models.count-1)
        let geometry=content.simulation.road.geometry
        var surfaces=[WheelSoundSurface](repeating:.init(),count:4)
        if let pose=try? VehiclePresentation(own.current) {
            for wheel in 0..<4 {
                let hub=pose.wheels[wheel].transform[3]
                if let local=try? geometry.globalToLocal(SIMD2(hub.x,hub.y),startingAt:frame.trackSegment,mode:.segment) {
                    let segment=geometry.segments[local.segment]
                    surfaces[wheel]=WheelSoundSurface(offRoad:WheelSoundSurface.isOffRoad(material:segment.surface.material),
                        curb:segment.style == .curb,roughWaveNumber:segment.surface.roughWaveNumber,roughness:segment.surface.roughness)
                } else { surfaces[wheel]=WheelSoundSurface(offRoad:true,roughWaveNumber:0.3,roughness:0.05) }
            }
        }
        let collisionTick=own.presentation.collisions.lastCollisionTick
        let collided=collisionTick>lastCollisionTick[viewer]
        lastCollisionTick[viewer]=collisionTick
        let mass=content.models[model].parameters.section("Car")?.number("mass",default:1100) ?? 1100
        let input=CarSoundInput(engineSpeed:own.engineSpeed,redLine:redLines[model],throttle:max(own.throttle,throttle),gear:own.gear,
            speed:abs(frame.speed),skid:(0..<4).map { own.current.wheels[$0].skid },wheelsTurning:abs(frame.speed)>0.3,
            surfaces:surfaces,wheelLoad:mass*9.81/4,collided:collided,simulated:!finished)
        let sound=models[model].update(input)
        play(engines[0],key:engineKeys[model],buffer:buffers[engineKeys[model]])
        // Louder under load: the filter's opening stands in for the load.
        engines[0].set(sound.engine,gain:sound.engine.volume*(0.32+0.38*min(1,sound.engine.lowPass*1.4)))
        loops["skid"]?.set(sound.skid,gain:min(1,sound.skid.volume)*0.5)
        loops["road"]?.set(sound.road,gain:min(1,sound.road.volume)*0.4)
        loops["grass"]?.set(sound.grass,gain:min(1,sound.grass.volume)*0.5)
        loops["grassSkid"]?.set(sound.grassSkid,gain:min(1,sound.grassSkid.volume)*0.4)
        loops["curb"]?.set(sound.curb,gain:min(1,sound.curb.volume)*0.5)
        loops["turbo"]?.set(sound.turbo,gain:min(1,sound.turbo.volume*2.5))
        if sound.gearChanged,frame.phase == .running { shot("gear",gain:0.45) }
        // A car scraping along a wall reports a contact every update; one
        // impact is heard, then nothing until it has rung out.
        if sound.crashed,now-lastCrash>0.35 {
            lastCrash=now
            shot("crash\(1+Int(collisionTick)%6)",gain:min(1,0.35+abs(frame.speed)*0.012))
        }

        // The nearest opponents' engines, quieter with distance.
        let others=frame.field.indices.filter { $0 != viewer }
            .map { ($0,simd_distance(SIMD3<Float>(frame.field[$0].current.body.position),SIMD3<Float>(here))) }
            .sorted { $0.1<$1.1 }.prefix(engines.count-1)
        for (slot,voice) in engines.dropFirst().enumerated() {
            guard slot<others.count else { voice.player.volume=0;continue }
            let (car,distance)=others[others.startIndex+slot]
            let other=frame.field[car],otherModel=min(assignment(car),models.count-1)
            // Opponents share their model's memory only loosely: the pitch
            // and filter matter, the smoothing less.
            var voiceModel=CarSoundModel(rpmScale:content.models[otherModel].sound.rpmScale)
            _=voiceModel.update(CarSoundInput(engineSpeed:other.engineSpeed,redLine:redLines[otherModel],throttle:other.throttle,gear:other.gear,speed:abs(other.speed)))
            let heard=voiceModel.update(CarSoundInput(engineSpeed:other.engineSpeed,redLine:redLines[otherModel],throttle:other.throttle,gear:other.gear,speed:abs(other.speed),simulated:!finished))
            play(voice,key:engineKeys[otherModel],buffer:buffers[engineKeys[otherModel]])
            let reach: Float = 10
            voice.set(heard.engine,gain:heard.engine.volume*(0.28+0.3*min(1,heard.engine.lowPass*1.4))*reach/(reach+distance))
        }
    }
}
