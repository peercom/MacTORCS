// SPDX-License-Identifier: GPL-2.0-only
import TORCSSimulation
import TORCSTelemetry

/// Diagnostic capture, not replay: preserves mechanical telemetry and adds the
/// independently published human timing state after each completed physics tick.
public enum DrivingTelemetry {
    public static func timingValues(_ n: RaceLapTiming,raceTime: Double) -> [String:Double] {
        ["race.time":raceTime,"race.lapStartTime":n.startTime,"race.currentLapTime":n.currentLapTime,
         "race.lastLapTime":n.lastLapTime,"race.bestLapTime":n.bestLapTime,"race.deltaBestLapTime":n.deltaBestLapTime,
         "race.totalTime":n.totalTime,"race.topSpeed":Double(n.topSpeed),"race.lapTopSpeed":Double(n.lapTopSpeed),
         "race.lapMinimumSpeed":Double(n.lapMinimumSpeed),"race.currentMinimumSpeed":Double(n.currentMinimumSpeed),
         "race.distanceFromStart":Double(n.distanceFromStart),"race.distanceRaced":Double(n.distanceRaced),
         "race.laps":Double(n.laps),"race.remainingLaps":Double(n.remainingLaps),"race.backwardCrossings":Double(n.backwardCrossings),
         "race.previousSegment":Double(n.previousSegment),"race.valid":n.commitBestLapTime ? 1:0,"race.flags":Double(n.flags)]
    }
    public static func record(_ simulation: SingleVehicleSimulation,timing: RaceLapTiming,raceTime: Double) -> TelemetryRecord {
        let physics=VehicleTelemetry.record(simulation,scenario:"human-practice-v1")
        var fields=physics.values
        fields.merge(timingValues(timing,raceTime:raceTime)) { _,new in new }
        return TelemetryRecord(scenario:physics.scenario,tick:physics.tick,time:physics.time,values:fields)
    }
}
