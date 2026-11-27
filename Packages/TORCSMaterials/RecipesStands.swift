// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// A grandstand: the steps its people sit on and the sheet it is closed in with.
extension MaterialRecipes {
    // MARK: - Seats

    /// The steps of a stand from above: a concrete tread a metre deep with a
    /// row of tip-up seats along it, four to the tile's two metres.
    static func standSeats(size: Int, seed: UInt32) -> GeneratedMaterial {
        let across = 4, deep = 2
        let grain = fractalField(size: size, cells: 90, octaves: 3, seed: seed &+ 3)
        let wear = fractalField(size: size, cells: 6, octaves: 3, seed: seed &+ 5)
        /// Where in its own seat a texel is: -1 to 1 each way, and which seat.
        func place(_ x: Int, _ y: Int) -> (u: Float, v: Float, id: UInt32, tread: Float) {
            let fx = Float(x) / Float(size) * Float(across), fy = Float(y) / Float(size) * Float(deep)
            let id = Noise.hash(Int(fx), Int(fy), seed &+ 7)
            return ((fx - floor(fx)) * 2 - 1, (fy - floor(fy)) * 2 - 1, id, fy - floor(fy))
        }
        /// 1 on the seat's pan, the front half of the tread's depth; 0 off it.
        func pan(_ u: Float, _ v: Float) -> Float {
            let du = abs(u) / 0.84, dv = abs(v + 0.30) / 0.50
            let d = pow(pow(du, 4) + pow(dv, 4), 0.25)
            return 1 - smoothstep(0.90, 1.0, d)
        }
        /// The backrest, seen from above: a bar along the seat's rear.
        func back(_ u: Float, _ v: Float) -> Float {
            (1 - smoothstep(0.80, 0.88, abs(u))) * (1 - smoothstep(0.06, 0.09, abs(v - 0.34)))
        }
        var height = ScalarField(size: size) { x, y in
            let p = place(x, y)
            let seat = pan(p.u, p.v)
            // Dished: a seat is lower in its middle than round its rim.
            let dish: Float = 0.55 - 0.10 * (1 - min((p.u * p.u + (p.v + 0.3) * (p.v + 0.3)) * 2.2, 1))
            let riser: Float = smoothstep(0.92, 1.0, p.tread) * 0.5            // the next step up, at the tread's rear
            return max(max(seat * dish, back(p.u, p.v) * 0.95), 0.12 + grain[x, y] * 0.06 + riser)
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let p = place(x, y)
            let plastic = max(pan(p.u, p.v), back(p.u, p.v))
            return 0.88 - plastic * 0.42 + wear[x, y] * 0.10 * plastic
        }
        let albedo = colours(size) { x, y in
            let p = place(x, y)
            let plastic = max(pan(p.u, p.v), back(p.u, p.v))
            // Moulded blue, each seat faded by its own years in the sun.
            let fade: Float = 0.80 + fraction(p.id) * 0.40
            var shell = SIMD3<Float>(0.035, 0.085, 0.300) * fade
            shell = shell + (SIMD3<Float>(0.20, 0.24, 0.34) - shell) * smoothstep(0.55, 0.9, wear[x, y]) * 0.35
            var step = SIMD3<Float>(0.30, 0.295, 0.28) * (0.85 + grain[x, y] * 0.3)
            step *= 1 - smoothstep(0.5, 0.9, wear[x + size / 2, y]) * 0.25
            // A painted nosing along the tread's front edge, so feet find it.
            step = step + (SIMD3<Float>(0.62, 0.50, 0.08) - step) * (1 - smoothstep(0.02, 0.035, p.tread)) * 0.8
            let c = step + (shell - step) * plastic
            // Under the seat's rim, shadow.
            return c * (plastic > 0.05 ? 1 : 0.62 + 0.38 * smoothstep(0.84, 1.1, max(abs(p.u), abs(p.v + 0.3) / 0.6)))
        }
        return pack("stand-seats", size: size, height: height, occlusionRadius: max(size / 128, 2), occlusionStrength: 1.8,
                    normalStrength: Float(size) / 60, roughness: roughness, albedo: albedo, worldSize: 2)
    }

    // MARK: - Cladding

    /// Painted steel sheet with a trapezoid rib every twenty centimetres:
    /// what the back and the sides of a stand are closed in with. Blue,
    /// chalked by the sun, lapped every metre and a half with a row of
    /// fixings, and streaked below each of them.
    static func ribbedCladding(size: Int, seed: UInt32) -> GeneratedMaterial {
        let ribs = 15
        let grain = fractalField(size: size, cells: 80, octaves: 2, seed: seed &+ 3)
        let chalk = fractalField(size: size, cells: 9, octaves: 3, seed: seed &+ 5)
        func rib(_ x: Int) -> Float {
            let p = (Float(x) / Float(size) * Float(ribs)).truncatingRemainder(dividingBy: 1)
            // Flat pan, a slope up, a flat crown, a slope down.
            return smoothstep(0.30, 0.42, p) * (1 - smoothstep(0.70, 0.82, p))
        }
        func lap(_ y: Int) -> Float {
            let v = (Float(y) / Float(size) * 2).truncatingRemainder(dividingBy: 1)
            return 1 - smoothstep(0.0, 0.008, min(v, 1 - v))
        }
        /// A fixing on every other crown just under each lap, and how far below it a texel is.
        func fixing(_ x: Int, _ y: Int) -> (head: Float, below: Float) {
            let fx = Float(x) / Float(size) * Float(ribs), index = Int(fx)
            guard index % 2 == 0 else { return (0, -1) }
            let du = (fx - floor(fx) - 0.56) / Float(ribs)
            let v = (Float(y) / Float(size) * 2).truncatingRemainder(dividingBy: 1) / 2
            let dv = v - 0.012
            let head = 1 - smoothstep(0.0025, 0.0045, (du * du + dv * dv).squareRoot())
            return (head, abs(du) < 0.004 ? dv : -1)
        }
        var height = ScalarField(size: size) { x, y in
            rib(x) * 0.80 + lap(y) * 0.06 + fixing(x, y).head * 0.12 + grain[x, y] * 0.015
        }
        height.normalise()
        func streak(_ x: Int, _ y: Int) -> Float {
            let f = fixing(x, y)
            return f.below > 0 && f.below < 0.10 ? 1 - f.below / 0.10 : 0
        }
        let roughness = ScalarField(size: size) { x, y in 0.46 + smoothstep(0.4, 0.8, chalk[x, y]) * 0.22 + streak(x, y) * 0.15 }
        let albedo = colours(size) { x, y in
            var c = SIMD3<Float>(0.045, 0.110, 0.300) * (0.92 + grain[x, y] * 0.16)
            c = c + (SIMD3<Float>(0.24, 0.30, 0.42) - c) * smoothstep(0.45, 0.85, chalk[x, y]) * 0.13
            c = c + (SIMD3<Float>(0.10, 0.09, 0.08) - c) * streak(x, y) * 0.35
            c = c + (SIMD3<Float>(0.45, 0.46, 0.47) - c) * fixing(x, y).head * 0.8
            return c * (1 - lap(y) * 0.45)
        }
        return pack("corrugated", size: size, height: height, occlusionRadius: max(size / 128, 2), occlusionStrength: 1.2,
                    normalStrength: Float(size) / 48, roughness: roughness, albedo: albedo, worldSize: 3)
    }
}
