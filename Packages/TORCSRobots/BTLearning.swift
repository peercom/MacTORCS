// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 robots/bt/learn.cpp.
// Copyright (C) 2004 Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

public struct BTLearning: Sendable {
    public private(set) var radius: [Float]
    public private(set) var updateIDs: [Int]
    var check=false,minimum: Float,previous=TrackCurve.straight,lastTurn=TrackCurve.straight
    public init(road: TrackRoad,karma: Data?=nil) throws {
        let g=road.geometry,count=g.mainSegments.count
        guard count>0,g.mainSegments.contains(where:{g.segments[$0].curve != .straight}),
              Set(g.mainSegments.map { g.segments[$0].upstreamID })==Set(0..<count) else { throw BTError.invalid("Invalid BT learning track") }
        minimum=road.width/2;radius=Array(repeating:0,count:count);updateIDs=Array(0..<count)
        if let karma {
            let bytes=Array(karma)
            // Original ARM64/x86 macOS files are little endian. Validate complete
            // records before accepting any state; original unchecked fread did not.
            guard karma.count==18+8*count,Array(bytes[12..<18])==Array("TORCS\0".utf8) else { throw BTError.invalid("Invalid BT karma length or signature") }
            func word(_ at: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at+$1]) << (8*$1) } }
            guard word(0)==0x34be1f01,word(4)==0x45aa9fbe,word(8)==count else { throw BTError.invalid("Invalid BT karma header") }
            for i in 0..<count {
                let id=Int(word(18+i*8)),r=Float(bitPattern:word(22+i*8))
                guard id<count,r.isFinite else { throw BTError.invalid("Invalid BT karma segment") }
                updateIDs[i]=id;radius[i]=r
            }
        } else {
            for i in g.mainSegments where g.segments[i].curve == .straight {
                var j=i
                while g.segments[j].curve == .straight { j=g.segments[j].previous }
                updateIDs[g.segments[i].upstreamID]=g.segments[j].upstreamID
            }
        }
    }
    public func encodedKarma() -> Data {
        var data=Data()
        func append(_ value: UInt32) { for byte in 0..<4 { data.append(UInt8(truncatingIfNeeded:value >> (byte*8))) } }
        append(0x34be1f01);append(0x45aa9fbe);append(UInt32(radius.count));data.append(contentsOf:"TORCS\0".utf8)
        for i in radius.indices { append(UInt32(updateIDs[i]));append(radius[i].bitPattern) }
        return data
    }
    /// The session owner controls paths and shutdown persistence; no global IO.
    public func save(to url: URL) throws { try encodedKarma().write(to:url,options:.atomic) }
    mutating func update(_ car: BTObservation,geometry g: TrackGeometry,offset: Float,outside: Float,base: [Float]) {
        let s=g.segments[car.position.segment]
        if s.curve==lastTurn || s.curve == .straight {
            if abs(offset)<0.2,check {
                let dr: Float=lastTurn == .right ? outside-car.position.toMiddle:lastTurn == .left ? outside+car.position.toMiddle:0
                minimum=min(dr,minimum)
            } else { check=false }
        }
        if s.curve != previous {
            previous=s.curve
            if s.curve != .straight {
                if check {
                    var j=s.previous
                    while g.segments[j].curve == .straight { j=g.segments[j].previous }
                    while g.segments[j].curve==lastTurn {
                        let segment=g.segments[j],id=updateIDs[segment.upstreamID]
                        if radius[id]+minimum<0 { minimum=max(segment.radius-base[segment.upstreamID],minimum) }
                        radius[id] += minimum;radius[id]=min(radius[id],1000);j=segment.previous
                    }
                }
                check=true;minimum=min(s.width/2,s.radius/10);lastTurn=s.curve
            }
        }
    }
}
