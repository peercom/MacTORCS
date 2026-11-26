// SPDX-License-Identifier: GPL-2.0-only
// What a car sounds like this instant: the original's per-car sound model,
// which turns engine speed, throttle, tyre skid, the surface under each
// wheel and collisions into a pitch, a volume and a filter per sound.
// Copyright (C) 2004-2017 Christos Dimitrakakis, Bernhard Wymann; upstream
// GPL-2.0-or-later (CarSoundData.cpp).
import Foundation

/// One sound's controls: volume, pitch as a playback-rate factor, and the
/// low-pass opening from 0 (dull) to 1 (open).
public struct SoundVoice: Sendable,Equatable {
    public var volume,pitch,lowPass: Float
    public init(volume: Float = 0,pitch: Float = 1,lowPass: Float = 1) { self.volume=volume;self.pitch=pitch;self.lowPass=lowPass }
}
/// What is under one wheel, as the sound model needs it.
public struct WheelSoundSurface: Sendable,Equatable {
    public var offRoad,curb: Bool
    /// The surface's roughness wave number and roughness, as the track stores them.
    public var roughWaveNumber,roughness: Float
    public init(offRoad: Bool = false,curb: Bool = false,roughWaveNumber: Float = 0,roughness: Float = 0) {
        self.offRoad=offRoad;self.curb=curb;self.roughWaveNumber=roughWaveNumber;self.roughness=roughness
    }
    /// The original's test for a loose surface, on its material name.
    public static func isOffRoad(material: String) -> Bool {
        let name=material.lowercased()
        return ["sand","dirt","grass","gravel","mud"].contains { name.contains($0) }
    }
}
/// One update's view of a car.
public struct CarSoundInput: Sendable {
    /// Engine speed and its red line, rad/s.
    public var engineSpeed,redLine: Float
    public var throttle: Float
    public var gear: Int
    /// The engaged gear's overall ratio; only the axle whine uses it.
    public var gearRatio: Float
    /// Speed over the ground, m/s.
    public var speed: Float
    /// Per wheel: the published skid factor, whether it turns, and its surface.
    public var skid: [Float]
    public var wheelsTurning: Bool
    public var surfaces: [WheelSoundSurface]
    /// The static wheel load, N, standing in for the tyre reaction the
    /// simulation does not publish.
    public var wheelLoad: Float
    /// A new contact since the last update.
    public var collided: Bool
    /// False once the car is out of the simulation: it makes no sound.
    public var simulated: Bool
    public init(engineSpeed: Float,redLine: Float,throttle: Float,gear: Int,gearRatio: Float = 1,speed: Float,
                skid: [Float] = [0,0,0,0],wheelsTurning: Bool = true,surfaces: [WheelSoundSurface] = Array(repeating:.init(),count:4),
                wheelLoad: Float = 3000,collided: Bool = false,simulated: Bool = true) {
        self.engineSpeed=engineSpeed;self.redLine=redLine;self.throttle=throttle;self.gear=gear;self.gearRatio=gearRatio
        self.speed=speed;self.skid=skid;self.wheelsTurning=wheelsTurning;self.surfaces=surfaces
        self.wheelLoad=wheelLoad;self.collided=collided;self.simulated=simulated
    }
}
/// Every sound of one car for one update.
public struct CarSoundFrame: Sendable,Equatable {
    public var engine=SoundVoice()
    public var turbo=SoundVoice(volume:0,pitch:0)
    public var axle=SoundVoice(volume:0,pitch:0)
    /// The loudest tyre skid on tarmac, and its pitch.
    public var skid=SoundVoice()
    public var road=SoundVoice(volume:0,pitch:0)
    public var grass=SoundVoice(volume:0,pitch:1)
    public var grassSkid=SoundVoice(volume:0,pitch:1)
    public var curb=SoundVoice(volume:0,pitch:1)
    public var gearChanged=false
    public var crashed=false
    public init() {}
}

/// The model's memory between updates. The original runs it a hundred times
/// a second and its smoothing constants are per update, so this is stepped
/// at that rate whatever the display does.
public struct CarSoundModel: Sendable {
    public static let updateInterval=0.01
    /// The engine sample's speed: playback rate 1 at 600 rad/s, times the
    /// car's own scale.
    public let rpmScale: Float
    public let turbo: Bool
    /// rad/s.
    public let turboSpeed: Float
    private let turboInverseLag: Float
    private var smoothThrottle: Float = 0
    private var previousAxle: Float = 0
    private var turboVoice=SoundVoice(volume:0,pitch:0)
    private var previousGear=0
    public init(rpmScale: Float = 1,turbo: Bool = false,turboSpeed: Float = 100,turboLag: Float = 1) {
        self.rpmScale=rpmScale;self.turbo=turbo;self.turboSpeed=turboSpeed
        turboInverseLag=turboLag>0 ? exp(-3*turboLag):0.05
    }
    static func roughnessFrequency(_ waveNumber: Float) -> Float {
        let f=2 * Float.pi*waveNumber
        return f>2 ? 2+tanh(f-2):f
    }
    public mutating func update(_ input: CarSoundInput) -> CarSoundFrame {
        var frame=CarSoundFrame()
        guard input.simulated else {
            frame.engine=SoundVoice(volume:0,pitch:rpmScale*input.engineSpeed/600,lowPass:1)
            return frame
        }
        // Engine: pitch follows speed; the filter opens with revs and load.
        let pitch=rpmScale*input.engineSpeed/600
        frame.engine.pitch=pitch;frame.engine.volume=1
        frame.axle.volume=0.2*tanh(100*abs(previousAxle-pitch))
        frame.axle.pitch=(previousAxle+pitch)*0.05*abs(input.gearRatio)
        previousAxle=(previousAxle+pitch)*0.5
        if turbo {
            var target: Float = 0.1,targetVolume: Float = 0
            if input.engineSpeed>turboSpeed { target=0.1+0.9*smoothThrottle;targetVolume=0.1*smoothThrottle }
            turboVoice.volume += 0.1*(targetVolume-turboVoice.volume)*(0.1+smoothThrottle)
            let targetPitch=target*input.engineSpeed/600
            turboVoice.pitch += turboInverseLag*(targetPitch-turboVoice.pitch)*smoothThrottle
            turboVoice.pitch -= turboVoice.pitch*0.01*(1-smoothThrottle)
            frame.turbo=turboVoice
        }
        smoothThrottle=smoothThrottle*0.5+0.5*(input.throttle*0.99+0.01)
        let rev=input.redLine>0 ? input.engineSpeed/input.redLine:0,rev2=rev*rev
        frame.engine.lowPass=(0.75*rev2+0.25)*smoothThrottle+(1-smoothThrottle)*0.25*rev2

        // Tyres: nothing at a standstill with still wheels.
        if input.speed>=0.3 || input.wheelsTurning {
            let base=input.speed*0.01,ride=0.001*input.wheelLoad
            for wheel in 0..<min(4,input.surfaces.count) {
                let surface=input.surfaces[wheel],skid=wheel<input.skid.count ? input.skid[wheel]:0
                let frequency=Self.roughnessFrequency(surface.roughWaveNumber)
                if surface.curb,input.wheelLoad>0 {
                    let volume=base*(5+ride/3)
                    if frame.curb.volume<volume { frame.curb=SoundVoice(volume:volume,pitch:base*(0.75+0.25*frequency)) }
                }
                if surface.offRoad {
                    let volume=(0.5+0.2*tanh(0.5*surface.roughness))*base*ride
                    if frame.grass.volume<volume { frame.grass=SoundVoice(volume:volume,pitch:base*(0.5+0.5*frequency)) }
                    if frame.grassSkid.volume<skid { frame.grassSkid=SoundVoice(volume:skid,pitch:1) }
                } else {
                    // Wind at 1, road noise a quarter of the ride.
                    let volume=base*(1+ride*0.25)
                    if frame.road.volume<volume { frame.road=SoundVoice(volume:volume,pitch:base*(0.75+0.25*frequency)) }
                    if skid>0.05 {
                        // The slip acceleration is not published; at zero the
                        // original's term is tanh(0.1).
                        let voice=SoundVoice(volume:skid-0.05,
                            pitch:(0.3-0.3*tanh(0.1)+0.3*frequency)/(1+0.5*tanh(input.wheelLoad*0.0001)))
                        if frame.skid.volume<voice.volume { frame.skid=voice }
                    }
                }
            }
        }
        frame.gearChanged=input.gear != previousGear
        previousGear=input.gear
        frame.crashed=input.collided
        return frame
    }
}

/// Stand-in samples, generated rather than recorded, for when the install's
/// own sound files are not in the library: the game is never silent, and
/// the same playback path serves both.
public enum SyntheticSound {
    public static let sampleRate: Double = 44100
    /// A deterministic noise source, so a generated sample is the same every run.
    struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state=state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded:state>>32))/Float(Int32.max)
        }
    }
    /// A loop that ends where it begins: the tail is faded into the head.
    static func looped(_ samples: [Float],fade: Int) -> [Float] {
        guard samples.count>2*fade,fade>0 else { return samples }
        var out=Array(samples[fade...])
        let n=out.count
        for i in 0..<fade {
            let t=Float(i)/Float(fade)
            out[n-fade+i]=out[n-fade+i]*(1-t)+samples[i]*t
        }
        return out
    }
    static func normalized(_ samples: [Float],peak: Float) -> [Float] {
        let top=samples.map(abs).max() ?? 0
        return top>0 ? samples.map { $0/top*peak }:samples
    }
    /// An engine note as it would be recorded at 600 rad/s: half-order
    /// harmonics of the crank with the firing order strongest, a little
    /// rough. Half a second, a whole number of cycles, so it loops cleanly.
    public static func engineLoop(cylinders: Int = 6) -> [Float] {
        let count=Int(sampleRate/2),halfOrder=48.0   // 24 cycles in the loop
        let firing=Double(max(2,cylinders))          // in half-orders: cylinders × crank/2
        var noise=Noise(state:0x5EED)
        var out=[Float](repeating:0,count:count)
        for harmonic in 1...40 {
            let h=Double(harmonic)
            // Strongest at the firing frequency and its multiples, a floor
            // of the orders between for the rasp.
            let distance=abs(h.truncatingRemainder(dividingBy:firing))
            let onOrder=min(distance,firing-distance)<0.5
            let amplitude=(onOrder ? 1.0:0.22)/pow(h,0.85)
            let phase=Double(noise.next())*Double.pi
            for i in 0..<count {
                out[i] += Float(amplitude*sin(2*Double.pi*halfOrder*h*Double(i)/sampleRate+phase))
            }
        }
        // A soft clip for grit.
        return normalized(out.map { tanh(1.6*$0) },peak:0.8)
    }
    /// Filtered noise for a tyre, a surface or the wind: a band between two
    /// one-pole filters.
    public static func noiseLoop(seconds: Double = 1.5,low: Double,high: Double,seed: UInt64) -> [Float] {
        let fade=4096,count=Int(sampleRate*seconds)+fade
        var noise=Noise(state:seed)
        let a=Float(1-exp(-2*Double.pi*high/sampleRate)),b=Float(1-exp(-2*Double.pi*low/sampleRate))
        var lowState: Float = 0,highState: Float = 0
        var out=[Float](repeating:0,count:count)
        for i in 0..<count {
            let x=noise.next()
            lowState += a*(x-lowState)        // keeps what is below `high`
            highState += b*(lowState-highState) // what is below `low`
            out[i]=lowState-highState
        }
        return normalized(looped(out,fade:fade),peak:0.8)
    }
    /// A tyre's squeal: a narrow, slightly wandering tone over a hiss.
    public static func skidLoop() -> [Float] {
        let fade=4096,count=Int(sampleRate*1.5)+fade
        var noise=Noise(state:0x51D)
        var phase=0.0,wander: Float = 0,hiss: Float = 0
        var out=[Float](repeating:0,count:count)
        for i in 0..<count {
            wander += 0.0008*(noise.next()-wander)
            phase += 2*Double.pi*(1150+Double(wander)*9000)/sampleRate
            hiss += 0.35*(noise.next()-hiss)
            out[i]=Float(sin(phase))*0.6+Float(sin(phase*2.01))*0.2+hiss*0.25
        }
        return normalized(looped(out,fade:fade),peak:0.7)
    }
    /// A short decaying knock: a gear going in, or with more noise and a
    /// longer tail, a hit.
    public static func impact(seconds: Double,tone: Double,noiseShare: Float,seed: UInt64) -> [Float] {
        let count=Int(sampleRate*seconds)
        var noise=Noise(state:seed)
        var filtered: Float = 0
        return normalized((0..<count).map { i in
            let t=Double(i)/sampleRate
            let envelope=Float(exp(-t*6/seconds))
            filtered += 0.25*(noise.next()-filtered)
            return envelope*(Float(sin(2*Double.pi*tone*t*(1-0.3*t/seconds)))*(1-noiseShare)+filtered*noiseShare*2)
        },peak:0.9)
    }
    /// A menu's tick: a brief soft tone.
    public static func blip(frequency: Double,seconds: Double = 0.06) -> [Float] {
        let count=Int(sampleRate*seconds)
        return (0..<count).map { i in
            let t=Double(i)/sampleRate
            return Float(sin(2*Double.pi*frequency*t)*sin(Double.pi*Double(i)/Double(count)))*0.5
        }
    }
}
