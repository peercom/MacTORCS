// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/collide.cpp wall construction.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import TORCSTrack

public enum TrackWallCollision {
    /// Original fixed-object polygons in left-side then right-side object order.
    /// Outer boundary walls remain handled by the track barrier response.
    public static func polygons(track: TrackGeometry) throws -> [[ConvexShape]] {
        let segments = track.segments
        var objects: [[ConvexShape]] = []
        func side(_ main: Int,_ side: TrackSide) -> Int? { side == .left ? segments[main].left : segments[main].right }
        func wall(_ main: Int,_ which: TrackSide) -> Bool {
            guard let i = side(main,which) else { return false }
            return segments[i].style == .wall && side(i,which) != nil
        }
        func firstWall(_ which: TrackSide) -> Int? {
            let start = track.mainSegments.last!
            var first = start
            repeat { if wall(first,which) { first = segments[first].previous } else { break } } while first != start
            let searchStart = first
            repeat { if wall(first,which) { return first }; first = segments[first].next } while first != searchStart
            return nil
        }
        func polygon(_ points: [SIMD3<Float>]) throws -> ConvexShape {
            try .init(vertices:points.map { SIMD3(Double($0.x),Double($0.y),Double($0.z)) },polygon:true)
        }
        for which in [TrackSide.left,.right] {
            guard let start = firstWall(which) else { continue }
            var current = start, open = false
            repeat {
                if wall(current,which),let index = side(current,which) {
                    let s = segments[index], previous = side(segments[current].previous,which).map { segments[$0] }, next = side(segments[current].next,which).map { segments[$0] }
                    let sl = s.startLeft, sr = s.startRight, el = s.endLeft, er = s.endRight, height = s.curbHeight
                    func top(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x,p.y,p.z+height) }
                    // Preserve x-only continuity and the Float 0.01 threshold.
                    let begins = previous.map { $0.style != .wall || abs($0.endLeft.x-sl.x)>0.01 || abs($0.endRight.x-sr.x)>0.01 || abs(height-$0.curbHeight)>0.01 } ?? true
                    if begins || objects.isEmpty {
                        guard objects.count<100 else { throw TrackError.invalid("More than 100 fixed collision wall objects") }
                        objects.append([try polygon([sl,sr,top(sr),top(sl)])]); open = true
                    }
                    if open {
                        objects[objects.count-1].append(try polygon([sl,top(sl),top(el),el]))
                        objects[objects.count-1].append(try polygon([top(sr),sr,er,top(er)]))
                    }
                    let ends = next.map { $0.style != .wall || abs($0.startLeft.x-el.x)>0.01 || abs($0.startRight.x-er.x)>0.01 || abs(height-$0.curbHeight)>0.01 } ?? true
                    if ends && open {
                        // Upstream's end cap uses START vertices, not end vertices.
                        objects[objects.count-1].append(try polygon([sl,sr,top(sr),top(sl)])); open = false
                    }
                }
                current = segments[current].next
            } while current != start
            // Upstream documents closed rings as unsupported; avoid constructing
            // an unfinished SOLID-equivalent hierarchy from that malformed input.
            guard !open else { throw TrackError.invalid("Unclosed fixed collision wall ring") }
        }
        return objects
    }
}
