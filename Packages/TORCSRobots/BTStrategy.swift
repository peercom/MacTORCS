// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 robots/bt/strategy.cpp (SimpleStrategy2).
// Copyright (C) 2004 Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

struct BTStrategy: Sendable {
    let expected,pitTime,bestLap,worstLap,initialFuel: Float
    var fuelChecked=false,fuelPerLap: Float=0,lastPitFuel: Float=0,fuelSum: Float=0,lastFuel: Float
    var fuelPerStint: Float,remainingStops: Int
    init(setup: ParameterDocument?,length: Float,laps: Int,index: Int) throws {
        func n(_ key: String,_ fallback: Float) -> Float { setup?.section("bt private")?.number(key,default:fallback) ?? fallback }
        expected=n("fuelperlap",length*0.0008);pitTime=n("pittime",25);bestLap=n("bestlap",87);worstLap=n("worstlap",87)
        let tank=setup?.section("Car")?.number("fuel tank",default:100) ?? 100
        guard [expected,pitTime,bestLap,worstLap,tank].allSatisfy(\.isFinite),expected>0,tank>0,expected/tank<10000 else { throw BTError.invalid("Invalid BT fuel strategy") }
        let fuel=(Float(laps)+1)*expected,minimum=Int(ceil(fuel/tank)-1)
        var time=Float.greatestFiniteMagnitude,stops=minimum,initial=tank,stint:Float=0
        for i in 0..<10 {
            let f=fuel/Float(minimum+i+1),average=bestLap+(worstLap-bestLap)*(f/tank)
            let estimate=Float(minimum+i)*(pitTime+f/8)+Float(laps)*average
            if time>estimate { time=estimate;stops=minimum+i;initial=f;stint=f }
        }
        lastFuel=initial;fuelPerStint=stint;remainingStops=stops;initialFuel=initial+Float(index)*expected
    }
    mutating func update(_ car: BTObservation,id: Int,tank: Float) {
        if id>=0 && id<5 && !fuelChecked {
            if car.laps>1 {
                fuelSum += lastFuel+lastPitFuel-car.fuel;fuelPerLap=fuelSum/Float(car.laps-1)
                updateFuelStrategy(car,tank:tank)
            }
            lastFuel=car.fuel;lastPitFuel=0;fuelChecked=true
        } else if id>5 { fuelChecked=false }
    }
    mutating func updateFuelStrategy(_ car: BTObservation,tank: Float) {
        // A zero measured consumption gives an infinite original quotient and no
        // additional fuel requirement. Avoid undefined Float-to-Int conversion.
        guard fuelPerLap>0 else { return }
        let required=Float((Double(car.remainingLaps+1)-Double(ceil(car.fuel/fuelPerLap)))*Double(fuelPerLap))
        if required<0 { return }
        let minimum=Int(ceil(required/tank));if minimum<1 { return }
        var time=Float.greatestFiniteMagnitude,stops=minimum
        for i in 0..<9 {
            let fuel=required/Float(minimum+i),average=bestLap+(worstLap-bestLap)*(fuel/tank)
            let estimate=Float(minimum+i)*(pitTime+fuel/8)+Float(car.remainingLaps)*average
            if time>estimate { time=estimate;stops=i+minimum;fuelPerStint=fuel }
        }
        remainingStops=stops
    }
    func needsPit(_ car: BTObservation,assigned: Bool) -> Bool {
        guard assigned else { return false }
        let laps=car.remainingLaps-car.lapsBehindLeader,comparison=fuelPerLap==0 ? expected:fuelPerLap
        if laps>0,Double(car.fuel)<1.5*Double(comparison),car.fuel<Float(laps)*comparison { return true }
        return car.damage>5000 && car.pitFree
    }
    mutating func refuel(_ car: BTObservation,tank: Float) -> Float {
        if remainingStops>1 { lastPitFuel=min(fuelPerStint,tank-car.fuel);remainingStops -= 1 }
        else { lastPitFuel=max(min((Float(car.remainingLaps)+1)*(fuelPerLap==0 ? expected:fuelPerLap)-car.fuel,tank-car.fuel),0) }
        return lastPitFuel
    }
}
