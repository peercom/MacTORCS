// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 track/track4.cpp and trackutil.cpp.
// track4.cpp: Copyright (C) 2002-2015 Eric Espie, Bernhard Wymann.
// trackutil.cpp: Copyright (C) 2000 Eric Espie. Upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

// Keep sine/cosine together as in the original loader's paired expressions.
// At -O the Apple C++ compiler emits sincosf; separate sinf/cosf can differ by
// one ULP and accumulate into coordinate drift. This boundary keeps Swift's
// optimizer from separating the pair across the value-typed geometry code.
@inline(never) private func trackSineCosine(_ angle: Float) -> (sine: Float, cosine: Float) {
    (sin(angle), cos(angle))
}

public struct TrackRoad: Sendable {
    public let geometry: TrackGeometry
    public let length: Float
    /// Original Main Track width, independent of side/segment widths.
    public let width: Float
    public let bounds: SIMD3<Float>
    public let pits: TrackPits
    public let cameras: [TrackRoadCamera]
    /// Original assignments are on main segments only; sides have no camera.
    public let cameraIndices: [Int?]
    /// Content the loader accepted but had to interpret, such as a camera whose
    /// segment reference does not resolve. Empty for well-formed tracks.
    public let warnings: [String]
    public func camera(at segment: Int) -> TrackRoadCamera? {
        guard cameraIndices.indices.contains(segment), let index = cameraIndices[segment] else { return nil }
        return cameras[index]
    }
}
/// Road, barriers, static pits and trackside camera construction.
///
/// Accepts version 4 directly and versions 0 through 3 by translating them to
/// the version-4 shape first; see `TrackVersion3`. The original loader
/// dispatches on the same boundary.
public enum TrackBuilder {
    public static func buildRoad(parameters: ParameterDocument) throws -> TrackRoad {
        let version = parameters.section("Header")?.number("version", default: 0) ?? 0
        guard version >= 0, version <= 4 else {
            throw TrackError.invalid("Unsupported track version \(version); expected 0 through 4")
        }
        let document = version < 4 ? TrackVersion3.normalised(parameters) : parameters
        guard let main = document.section("Main Track"), let definitions = main.section("Track Segments"),
              !definitions.sections.isEmpty else {
            throw TrackError.invalid("Expected a nonempty version-4 track")
        }
        return try RoadBuilder(parameters: document, main: main).build(definitions.sections)
    }
}

private final class RoadBuilder {
    let parameters: ParameterDocument
    let main: ParameterSection
    var segments: [TrackSegment] = []
    var mains: [Int] = []
    var minimum = SIMD3<Float>.zero, maximum = SIMD3<Float>.zero
    var totalLength: Float = 0
    var sides: [SideDefinition] = []
    init(parameters: ParameterDocument, main: ParameterSection) { self.parameters = parameters; self.main = main }
    func number(_ section: ParameterSection?, _ key: String, _ fallback: Float) -> Float { section?.number(key, default: fallback) ?? fallback }
    func string(_ section: ParameterSection?, _ key: String, _ fallback: String) -> String { section?.string(key, default: fallback) ?? fallback }
    func surface(_ material: String) throws -> TrackSurface {
        let section = parameters.section("Surfaces/" + material)
        let wavelength = number(section, "roughness wavelength", 1)
        guard wavelength > 0 else { throw TrackError.invalid("Surface roughness wavelength must be positive") }
        return TrackSurface(material: material, friction: number(section, "friction", 0.8),
            rebound: number(section, "rebound", 0.5), rollingResistance: number(section, "rolling resistance", 0.001),
            roughness: number(section, "roughness", 0) / 2,
            roughWaveNumber: Float(2 * Double.pi / Double(wavelength)), damage: number(section, "dammage", 10),
            texture: { let name = string(section, "texture name", ""); return name.isEmpty ? nil : name }())
    }
    func blank(curve: TrackCurve, surface: TrackSurface) -> TrackSegment {
        TrackSegment(name: "", upstreamID: 0, curve: curve, role: .main, style: .flat, mainIndex: 0, previous: 0, next: 0,
            length: 0, width: 0, startWidth: 0, endWidth: 0, distanceFromStart: 0,
            radius: 0, rightRadius: 0, leftRadius: 0, arc: 0, center: .zero, startRight: .zero, startLeft: .zero,
            endRight: .zero, endLeft: .zero, headingStart: 0, headingEnd: 0, pitchLeft: 0, pitchRight: 0,
            bankStart: 0, bankEnd: 0, centerStart: 0, longitudinalSlope: 0, bankingSlope: 0, widthSlope: 0,
            curbHeight: 0, rightNormal: .zero, surface: surface)
    }
    func xy(_ x: Float, _ y: Float) {
        minimum.x = min(minimum.x, x); maximum.x = max(maximum.x, x)
        minimum.y = min(minimum.y, y); maximum.y = max(maximum.y, y)
    }
    func z(_ value: Float) { minimum.z = min(minimum.z, value); maximum.z = max(maximum.z, value) }
    func curveBounds(_ s: TrackSegment, radii: [Float]) {
        let sign: Float = s.curve == .left ? 1 : -1
        let step = Float(Double(s.arc) / 36 * Double(sign))
        var angle = s.centerStart
        for _ in 0..<36 {
            angle += step
            for radius in radii { xy(s.center.x + radius * trackSineCosine(angle).cosine, s.center.y + radius * trackSineCosine(angle).sine) }
        }
    }
    func spline(_ start: Float, _ end: Float, _ t0: Float, _ t1: Float, _ t: Float) -> Float {
        let t2 = t * t, t3 = t * t2
        let h1 = 3 * t2 - 2 * t3, h0 = 1 - h1, h2 = t3 - 2 * t2 + t, h3 = t3 - t2
        return h0 * start + h1 * end + h2 * t0 + h3 * t1
    }
    func build(_ definitions: [ParameterSection]) throws -> TrackRoad {
        let width = number(main, "width", 15), halfWidth = width / 2
        guard width > 0 else { throw TrackError.invalid("Main track width must be positive") }
        let globalStepLength = number(main, "profil steps length", 0)
        guard globalStepLength >= 0 else { throw TrackError.invalid("Negative profile step length") }
        for name in ["Right", "Left"] { sides.append(try sideDefaults(name)) }
        var right = SIMD2<Float>.zero, left = SIMD2<Float>(0, width), heading: Float = 0
        var endLeft: Float = 0, endRight: Float = 0, tangentLeft: Float = 0, tangentRight: Float = 0
        var grade: Float = -100000, material = string(main, "surface", "asphalt")
        for definition in definitions {
            let kind = string(definition, "type", "")
            if kind.isEmpty { continue } // Original ignores entries without a type.
            let curve: TrackCurve
            switch kind { case "str": curve = .straight; case "lft": curve = .left; case "rgt": curve = .right
            default: throw TrackError.invalid("Unknown track curve \(kind)") }
            var radius: Float = curve == .straight ? 0 : number(definition, "radius", 0)
            let endRadius: Float = curve == .straight ? 0 : number(definition, "end radius", radius)
            let arc: Float = curve == .straight ? 0 : number(definition, "arc", 0)
            let length = curve == .straight ? number(definition, "lg", 0) : Float(Double(radius + endRadius) / 2 * Double(arc))
            guard length.isFinite, length > 0, curve == .straight || (radius > 0 && endRadius > 0 && arc > 0) else {
                throw TrackError.invalid("Invalid radius/length at \(definition.name)")
            }
            material = string(definition, "surface", material)
            let roadSurface = try surface(material)
            var startLeft = endLeft, startRight = endRight
            z(startLeft); z(startRight)
            startLeft = number(definition, "z start left", startLeft); startRight = number(definition, "z start right", startRight)
            endLeft = number(definition, "z end left", endLeft); endRight = number(definition, "z end right", endRight)
            var startZ = number(definition, "z start", -100000), endZ = number(definition, "z end", -100000)
            grade = number(definition, "grade", grade)
            if startZ != -100000 { startRight = startZ; startLeft = startZ }
            else { startZ = (startLeft + startRight) / 2 }
            if endZ != -100000 { endRight = endZ; endLeft = endZ }
            else if grade != -100000 { endZ = startZ + length * grade }
            else { endZ = (endLeft + endRight) / 2 }
            let startBank = number(definition, "banking start", atan2(startLeft - startRight, width))
            let endBank = number(definition, "banking end", atan2(endLeft - endRight, width))
            var dz = tan(startBank) * width / 2
            startLeft = startZ + dz; startRight = startZ - dz
            dz = tan(endBank) * width / 2
            endLeft = endZ + dz; endRight = endZ - dz
            z(startLeft); z(startRight)
            var startTangentLeft = tangentLeft, startTangentRight = tangentRight
            var steps = 1
            if string(definition, "profil", "spline") == "spline" {
                let count = number(definition, "profil steps", 1)
                guard count.isFinite, count >= 1, count <= 100000 else { throw TrackError.invalid("Invalid profile step count") }
                steps = Int(count)
                if steps == 1 {
                    let stepLength = number(definition, "profil steps length", globalStepLength)
                    guard stepLength >= 0 else { throw TrackError.invalid("Negative profile step length") }
                    if stepLength != 0 {
                        let count = length / stepLength
                        guard count.isFinite, count < 100000 else { throw TrackError.invalid("Profile subdivision limit exceeded") }
                        steps = Int(count) + 1
                    }
                }
                startTangentLeft = number(definition, "profil start tangent left", startTangentLeft)
                tangentLeft = number(definition, "profil end tangent left", tangentLeft)
                startTangentRight = number(definition, "profil start tangent right", startTangentRight)
                tangentRight = number(definition, "profil end tangent right", tangentRight)
                let start = number(definition, "profil start tangent", -100000), end = number(definition, "profil end tangent", -100000)
                if start != -100000 { startTangentLeft = start; startTangentRight = start }
                if end != -100000 { tangentLeft = end; tangentRight = end }
            } else {
                startTangentLeft = (endLeft - startLeft) / length; tangentLeft = startTangentLeft
                startTangentRight = (endRight - startRight) / length; tangentRight = startTangentRight
            }
            guard mains.count + steps <= 100000 else { throw TrackError.invalid("Track subdivision limit exceeded") }
            let t1Left = startTangentLeft * length, t2Left = tangentLeft * length
            let t1Right = startTangentRight * length, t2Right = tangentRight * length
            let increment = 1 / Float(steps)
            var t: Float = 0, currentEndLeft = startLeft, currentEndRight = startRight
            var currentArc = arc / Float(steps), currentLength = length / Float(steps)
            var radiusIncrement = (endRadius - radius) / Float(steps)
            if endRadius != radius && steps != 1 {
                radiusIncrement = (endRadius - radius) / Float(steps - 1)
                var temporaryAngle: Float = 0, temporaryRadius = radius
                for _ in 0..<steps { temporaryAngle += currentLength / temporaryRadius; temporaryRadius += radiusIncrement }
                currentLength *= arc / temporaryAngle
            }
            for side in 0..<2 { try updateSide(side, definition: definition) }
            for step in 0..<steps {
                t += increment
                let currentStartLeft = currentEndLeft, currentStartRight = currentEndRight
                currentEndLeft = spline(startLeft, endLeft, t1Left, t2Left, t)
                currentEndRight = spline(startRight, endRight, t1Right, t2Right, t)
                if radiusIncrement != 0 { currentArc = currentLength / radius }
                var s = blank(curve: curve, surface: roadSurface)
                s.name = definition.name; s.upstreamID = mains.count; s.mainIndex = segments.count
                s.length = currentLength; s.width = width; s.startWidth = width; s.endWidth = width; s.distanceFromStart = totalLength
                s.startRight = SIMD3(right.x, right.y, currentStartRight); s.startLeft = SIMD3(left.x, left.y, currentStartLeft)
                s.headingStart = heading
                let newRight: SIMD2<Float>, newLeft: SIMD2<Float>
                if curve == .straight {
                    newRight = SIMD2(right.x + currentLength * trackSineCosine(heading).cosine, right.y + currentLength * trackSineCosine(heading).sine)
                    newLeft = SIMD2(left.x + currentLength * trackSineCosine(heading).cosine, left.y + currentLength * trackSineCosine(heading).sine)
                    s.rightNormal = SIMD2(-trackSineCosine(heading).sine, trackSineCosine(heading).cosine)
                    xy(newRight.x, newRight.y); xy(newLeft.x, newLeft.y)
                } else {
                    s.radius = radius; s.arc = currentArc
                    let inner = radius - halfWidth
                    if curve == .left {
                        s.rightRadius = radius + halfWidth; s.leftRadius = radius - halfWidth
                        s.center = SIMD3(left.x - inner * trackSineCosine(heading).sine, left.y + inner * trackSineCosine(heading).cosine, 0)
                        s.centerStart = Float(Double(heading) - Double.pi / 2)
                        heading += currentArc
                        newLeft = SIMD2(s.center.x + inner * trackSineCosine(heading).sine, s.center.y - inner * trackSineCosine(heading).cosine)
                        newRight = SIMD2(s.center.x + (inner + width) * trackSineCosine(heading).sine, s.center.y - (inner + width) * trackSineCosine(heading).cosine)
                    } else {
                        s.rightRadius = radius - halfWidth; s.leftRadius = radius + halfWidth
                        s.center = SIMD3(right.x + inner * trackSineCosine(heading).sine, right.y - inner * trackSineCosine(heading).cosine, 0)
                        s.centerStart = Float(Double(heading) + Double.pi / 2)
                        heading -= currentArc
                        newLeft = SIMD2(s.center.x - (inner + width) * trackSineCosine(heading).sine, s.center.y + (inner + width) * trackSineCosine(heading).cosine)
                        newRight = SIMD2(s.center.x - inner * trackSineCosine(heading).sine, s.center.y + inner * trackSineCosine(heading).cosine)
                    }
                    curveBounds(s, radii: [inner, inner + width])
                }
                s.headingEnd = heading
                s.endRight = SIMD3(newRight.x, newRight.y, currentEndRight); s.endLeft = SIMD3(newLeft.x, newLeft.y, currentEndLeft)
                s.bankStart = atan2(currentStartLeft - currentStartRight, width)
                s.bankEnd = atan2(currentEndLeft - currentEndRight, width)
                let rightRadius = curve == .left ? (radius - halfWidth) + width : radius - halfWidth
                let leftRadius = curve == .right ? (radius - halfWidth) + width : radius - halfWidth
                let rightDistance = curve == .straight ? currentLength : currentArc * rightRadius
                let leftDistance = curve == .straight ? currentLength : currentArc * leftRadius
                s.pitchRight = atan2(currentEndRight - currentStartRight, rightDistance)
                s.pitchLeft = atan2(currentEndLeft - currentStartLeft, leftDistance)
                s.longitudinalSlope = tan(s.pitchRight) * (curve == .straight ? 1 : rightRadius)
                s.bankingSlope = (s.bankEnd - s.bankStart) / s.extent
                mains.append(segments.count); segments.append(s)
                try addSides(main: s.mainIndex, step: step, steps: steps)
                totalLength += s.length; right = newRight; left = newLeft
                if curve != .straight { radius += radiusIncrement }
            }
        }
        guard !mains.isEmpty else { throw TrackError.invalid("No track geometry") }
        for (i, index) in mains.enumerated() {
            let previous = mains[(i + mains.count - 1) % mains.count], next = mains[(i + 1) % mains.count]
            segments[index].previous = previous; segments[index].next = next
            if Double(segments[index].distanceFromStart + segments[index].length) > Double(totalLength) - 50 { segments[index].raceFlags |= 1 }
            else if segments[index].distanceFromStart < 50 { segments[index].raceFlags |= 2 }
        }
        let pits = try buildPits()
        for index in segments.indices {
            let main = segments[index].mainIndex
            segments[index].previous = segments[main].previous; segments[index].next = segments[main].next
        }
        // TORCS computes cameras before translating track coordinates to positive space.
        let cameras = try TrackRoadCamera.build(parameters: parameters, geometry: TrackGeometry(segments: segments), minimum: minimum)
        for index in segments.indices {
            segments[index].startRight -= minimum; segments[index].startLeft -= minimum
            segments[index].endRight -= minimum; segments[index].endLeft -= minimum
            segments[index].center.x -= minimum.x; segments[index].center.y -= minimum.y
        }
        return TrackRoad(geometry: try TrackGeometry(segments: segments), length: totalLength, width: width, bounds: maximum - minimum, pits: pits, cameras: cameras.cameras, cameraIndices: cameras.indices, warnings: cameras.warnings)
    }
}

private struct SideDefinition {
    var startWidth, endWidth, banking: Float
    var surface: TrackSurface
    var borderWidth, borderHeight: Float
    var borderStyle: TrackStyle
    var borderSurface: TrackSurface
    var barrierWidth, barrierHeight: Float
    var barrierStyle: TrackStyle
    var barrierSurface: TrackSurface
}
private extension RoadBuilder {
    func borderStyle(_ name: String) -> TrackStyle { name == "plan" ? .flat : (name == "curb" ? .curb : .wall) }
    func sideDefaults(_ name: String) throws -> SideDefinition {
        let side = main.section(name + " Side"), border = main.section(name + " Border"), barrier = main.section(name + " Barrier")
        let fence = string(barrier, "style", "fence") == "fence"
        return SideDefinition(startWidth: 0, endWidth: number(side, "width", 0),
            banking: string(side, "banking type", "level") == "level" ? 0 : 1,
            surface: try surface(string(side, "surface", "grass")),
            borderWidth: number(border, "width", 0), borderHeight: number(border, "height", 0),
            borderStyle: borderStyle(string(border, "style", "plan")), borderSurface: try surface(string(border, "surface", "grass")),
            barrierWidth: fence ? 0 : number(barrier, "width", 0.5), barrierHeight: number(barrier, "height", 0.6),
            barrierStyle: fence ? .fence : .wall, barrierSurface: try surface(string(barrier, "surface", "barrier")))
    }
    func updateSide(_ side: Int, definition: ParameterSection) throws {
        let name = side == 0 ? "Right" : "Left"
        let strip = definition.section(name + " Side"), border = definition.section(name + " Border"), barrier = definition.section(name + " Barrier")
        var s = sides[side]
        s.startWidth = number(strip, "start width", s.endWidth)
        let w = number(strip, "width", s.startWidth)
        s.endWidth = number(strip, "end width", w)
        s.surface = try surface(string(strip, "surface", s.surface.material))
        s.borderWidth = number(border, "width", s.borderWidth); s.borderHeight = number(border, "height", s.borderHeight)
        s.borderSurface = try surface(string(border, "surface", s.borderSurface.material))
        let oldStyle = s.borderStyle == .flat ? "plan" : (s.borderStyle == .curb ? "curb" : "wall")
        s.borderStyle = borderStyle(string(border, "style", oldStyle))
        guard s.startWidth >= 0, s.endWidth >= 0, s.borderWidth >= 0 else { throw TrackError.invalid("Negative side width") }
        s.barrierSurface = try surface(string(barrier, "surface", s.barrierSurface.material))
        s.barrierHeight = number(barrier, "height", s.barrierHeight)
        let fence = string(barrier, "style", s.barrierStyle == .fence ? "fence" : "wall") == "fence"
        s.barrierStyle = fence ? .fence : .wall
        s.barrierWidth = fence ? 0 : number(barrier, "width", s.barrierWidth)
        sides[side] = s
    }
    func addSides(main: Int, step: Int, steps: Int) throws {
        for side in 0..<2 {
            let s = sides[side]
            let change = (s.endWidth - s.startWidth) / Float(steps)
            let end = s.startWidth + Float(step + 1) * change, start = s.startWidth + Float(step) * change
            var current = main
            if s.borderWidth > 0 {
                current = addSide(inner: current, main: main, side: side, border: true, banking: s.banking,
                    start: s.borderWidth, end: s.borderWidth, surface: s.borderSurface, height: s.borderHeight, style: s.borderStyle)
            }
            if start > 0 || end > 0 {
                current = addSide(inner: current, main: main, side: side, border: false, banking: s.banking,
                    start: start, end: end, surface: s.surface, height: 0, style: .flat)
            }
            // Normals use the original unshifted endpoints, before origin translation.
            let outer = segments[current], sign: Float = side == 0 ? 1 : -1
            let a = side == 0 ? outer.startRight : outer.startLeft
            let b = side == 0 ? outer.endRight : outer.endLeft
            var normal = SIMD2(-(b.y - a.y) * sign, (b.x - a.x) * sign)
            let length = sqrt(normal.x * normal.x + normal.y * normal.y)
            guard length > 0, length.isFinite else { throw TrackError.invalid("Degenerate barrier normal") }
            normal.x /= length; normal.y /= length
            let barrier = TrackBarrier(style: s.barrierStyle, width: s.barrierWidth, height: s.barrierHeight,
                                       surface: s.barrierSurface, normal: normal)
            if side == 0 { segments[main].rightBarrier = barrier } else { segments[main].leftBarrier = barrier }
        }
    }
    func addSide(inner: Int, main: Int, side: Int, border: Bool, banking: Float, start: Float, end: Float,
                 surface: TrackSurface, height: Float, style: TrackStyle) -> Int {
        let parent = segments[inner], left = side == 1
        var s = blank(curve: parent.curve, surface: surface)
        s.role = left ? (border ? .leftBorder : .leftSide) : (border ? .rightBorder : .rightSide)
        s.mainIndex = main; s.style = style; s.curbHeight = height
        s.startWidth = start; s.endWidth = end; s.width = min(start, end)
        s.bankStart = parent.bankStart * banking; s.bankEnd = parent.bankEnd * banking
        s.headingStart = parent.headingStart; s.headingEnd = parent.headingEnd; s.centerStart = parent.centerStart
        if left { s.startRight = parent.startLeft; s.endRight = parent.endLeft }
        else { s.startLeft = parent.startRight; s.endLeft = parent.endRight }
        var outerEnd: SIMD3<Float>
        if parent.curve == .straight {
            s.length = parent.length
            if left {
                s.startLeft = SIMD3(s.startRight.x + start * parent.rightNormal.x, s.startRight.y + start * parent.rightNormal.y,
                                   s.startRight.z + banking * start * tan(parent.bankStart))
                s.endLeft = SIMD3(s.endRight.x + end * parent.rightNormal.x, s.endRight.y + end * parent.rightNormal.y,
                                 s.endRight.z + banking * end * tan(parent.bankEnd))
                outerEnd = s.endLeft
            } else {
                s.startRight = SIMD3(s.startLeft.x - start * parent.rightNormal.x, s.startLeft.y - start * parent.rightNormal.y,
                                    s.startLeft.z - banking * start * tan(parent.bankStart))
                s.endRight = SIMD3(s.endLeft.x - end * parent.rightNormal.x, s.endLeft.y - end * parent.rightNormal.y,
                                  s.endLeft.z - banking * end * tan(parent.bankEnd))
                outerEnd = s.endRight
            }
            s.pitchRight = atan2(s.endRight.z - s.startRight.z, s.length)
            s.pitchLeft = atan2(s.endLeft.z - s.startLeft.z, s.length)
            s.longitudinalSlope = tan(s.pitchRight)
            s.rightNormal = parent.rightNormal
            xy(outerEnd.x, outerEnd.y)
        } else {
            s.center = parent.center; s.arc = parent.arc
            let sign: Float = parent.curve == .left ? 1 : -1
            let maxWidth = max(start, end)
            if left {
                s.radius = Float(Double(parent.leftRadius) - Double(sign * start) / 2)
                s.rightRadius = parent.leftRadius; s.leftRadius = parent.leftRadius - sign * maxWidth
                s.startLeft = SIMD3(s.startRight.x - sign * start * trackSineCosine(s.centerStart).cosine,
                                   s.startRight.y - sign * start * trackSineCosine(s.centerStart).sine,
                                   s.startRight.z + banking * start * tan(parent.bankStart))
                s.endLeft = SIMD3(s.endRight.x - sign * end * trackSineCosine(s.centerStart + sign * s.arc).cosine,
                                 s.endRight.y - sign * end * trackSineCosine(s.centerStart + sign * s.arc).sine,
                                 s.endRight.z + banking * end * tan(parent.bankEnd))
                outerEnd = s.endLeft
            } else {
                s.radius = Float(Double(parent.rightRadius) + Double(sign * start) / 2)
                s.leftRadius = parent.rightRadius; s.rightRadius = parent.rightRadius + sign * maxWidth
                s.startRight = SIMD3(s.startLeft.x + sign * start * trackSineCosine(s.centerStart).cosine,
                                    s.startLeft.y + sign * start * trackSineCosine(s.centerStart).sine,
                                    s.startLeft.z - banking * start * tan(parent.bankStart))
                s.endRight = SIMD3(s.endLeft.x + sign * end * trackSineCosine(s.centerStart + sign * s.arc).cosine,
                                  s.endLeft.y + sign * end * trackSineCosine(s.centerStart + sign * s.arc).sine,
                                  s.endLeft.z - banking * end * tan(parent.bankEnd))
                outerEnd = s.endRight
            }
            s.length = s.radius * s.arc
            s.pitchRight = atan2(s.endRight.z - s.startRight.z, s.arc * s.rightRadius)
            s.pitchLeft = atan2(s.endLeft.z - s.startLeft.z, s.arc * s.leftRadius)
            s.longitudinalSlope = tan(s.pitchRight) * s.rightRadius
            curveBounds(s, radii: [left ? s.leftRadius : s.rightRadius])
        }
        s.bankingSlope = (s.bankEnd - s.bankStart) / s.extent
        s.widthSlope = (end - start) / s.extent
        z(outerEnd.z)
        let index = segments.count
        if left { segments[inner].left = index } else { segments[inner].right = index }
        segments.append(s)
        return index
    }
}

private extension RoadBuilder {
    func buildPits() throws -> TrackPits {
        guard let section = main.section("Pits"), case .string(let entryName, _) = section.parameters["entry"] else { return .none }
        let side: TrackSide = string(section, "side", "right") == "right" ? .right : .left
        let speed = number(section, "speed limit", 25)
        // Original reverse scan returns the first subdivision in a named run;
        // a run covering the entire ring retains its last segment.
        func firstInRun(_ matches: (TrackSegment) -> Bool) -> Int? {
            var current = mains.last!, found = false
            for _ in mains.indices {
                if matches(segments[current]) { found = true }
                else if found { current = segments[current].next; break }
                current = segments[current].previous
            }
            return found ? current : nil
        }
        func lastNamed(_ key: String) -> Int? {
            let name = string(section, key, "")
            return mains.reversed().first { segments[$0].name == name }
        }
        let firstEntryID = mains.first { segments[$0].name == entryName }.map { segments[$0].upstreamID } ?? -1
        let entry = firstInRun { $0.upstreamID == firstEntryID }
        let startName = string(section, "start", "")
        let start = firstInRun { $0.name == startName }
        guard let entry, let start, let end = lastNamed("end"), let exit = lastNamed("exit") else {
            return TrackPits(type: .none, side: side, entry: nil, start: nil, end: nil, exit: nil,
                             stallLength: 0, laneWidth: 0, speedLimit: speed, positions: [])
        }
        let length = number(section, "length", 15), width = number(section, "width", 5)
        guard length > 0, width >= 0, speed >= 0 else { throw TrackError.invalid("Invalid pit dimensions or speed limit") }
        let startDistance = segments[start].distanceFromStart, endDistance = segments[end].distanceFromStart
        let span: Float
        if startDistance > endDistance { span = totalLength - startDistance + endDistance + segments[end].length }
        else { span = endDistance + segments[end].length - startDistance }
        let capacity = (Double(span) + Double(length) / 2) / Double(length)
        guard capacity.isFinite, capacity >= 0, capacity < 100000 else { throw TrackError.invalid("Pit allocation limit exceeded") }
        segments[entry].raceFlags |= 0x10; segments[exit].raceFlags |= 0x20
        var positions: [TrackLocalPosition] = []
        var current = segments[start].previous, changeSegment = true
        var toStart: Float = 0, offset: Float = 0, pitSegment: Int?
        // Bound both stall count and advancement even for malformed geometry.
        var advances = 0
        while positions.count < Int(capacity) {
            if changeSegment {
                changeSegment = false; offset = 0; current = segments[current].next
                advances += 1
                guard advances <= mains.count * 2 else { throw TrackError.invalid("Pit placement exceeded track traversal limit") }
                if toStart >= segments[current].length {
                    toStart -= segments[current].length; changeSegment = true; continue
                }
                guard let first = segments[current].side(side) else { throw TrackError.invalid("Pit lane has no side surface") }
                pitSegment = first
                if let outer = segments[first].side(side) { offset = segments[first].width; pitSegment = outer }
            }
            let strip = segments[pitSegment!]
            // toStart stays in metres here even on curves, exactly as track4.cpp
            // stores it. Do not silently reinterpret the original pit placement.
            let stripWidth = abs(strip.startWidth + toStart * strip.widthSlope)
            let lateral = Float(Double(-offset - stripWidth) + Double(width) / 2)
            let opposite = segments[current].width - lateral
            let middle = Float(Double(segments[current].width) / 2 - Double(lateral))
            positions.append(TrackLocalPosition(segment: current, toStart: Float(Double(toStart) + Double(length) / 2),
                toRight: side == .right ? lateral : opposite, toMiddle: middle, toLeft: side == .right ? opposite : lateral))
            toStart += length
            if toStart >= segments[current].length { toStart -= segments[current].length; changeSegment = true }
        }
        let before = segments[start].previous, after = segments[end].next, stop = segments[after].next
        current = before
        var marked = 0
        while current != stop {
            guard marked < mains.count else { throw TrackError.invalid("Invalid pit flag traversal") }
            guard let first = segments[current].side(side) else { throw TrackError.invalid("Pit approach has no side surface") }
            let flag: UInt32 = current == before ? 0x80 : (current == after ? 0x100 : 0x40 | 0x08)
            segments[first].raceFlags |= flag
            if let outer = segments[first].side(side) { segments[outer].raceFlags |= flag }
            if current != before && current != after {
                if side == .right { segments[current].rightBarrier?.style = .pitBuilding }
                else { segments[current].leftBarrier?.style = .pitBuilding }
            }
            marked += 1; current = segments[current].next
        }
        return TrackPits(type: .trackSide, side: side, entry: entry, start: start, end: end, exit: exit,
                         stallLength: length, laneWidth: width, speedLimit: speed, positions: positions)
    }
}
