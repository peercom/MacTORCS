// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// BC1/BC3/BC4/BC5 block compression for the modern render path.
///
/// The classic path uploaded every texture as uncompressed `rgba8Unorm`, which
/// cost 4 bytes per texel on the GPU — tolerable for 256-square original art,
/// impossible for the 2K physically based material sets the new renderer needs
/// on an 8 GB unified-memory machine.
///
/// Bytes per texel, and the reduction against the 4-byte RGBA8 the classic path
/// uploaded: BC1 and BC4 are 0.5 (8:1), BC3 and BC5 are 1.0 (4:1). Measured
/// against their natural channel counts instead, BC1 is 6:1 on RGB8 and BC4/BC5
/// are 2:1 on R8/RG8. Decode is in hardware, so there is no runtime cost.
///
/// Apple silicon supports BC from Apple family 7 onward; callers must still
/// check `MTLDevice.supportsBCTextureCompression` before uploading.
///
/// Encoding runs on the CPU because it happens once, offline, inside
/// `torcs-assetc`. Decoders are included because they are what makes the
/// encoders testable — they are the reference the round-trip error is measured
/// against, and they mirror the hardware's fixed-point rules exactly.
public enum BlockCompression {
    public enum Format: String, Sendable, CaseIterable {
        /// RGB, 8 bytes per 4x4 block. Opaque colour.
        case bc1
        /// RGBA, 16 bytes per block. BC1 colour plus interpolated alpha.
        case bc3
        /// Single channel, 8 bytes per block.
        case bc4
        /// Two channels, 16 bytes per block. The normal-map format: store X and
        /// Y, reconstruct Z as sqrt(1 - x^2 - y^2) in the shader.
        case bc5

        public var bytesPerBlock: Int { self == .bc1 || self == .bc4 ? 8 : 16 }
    }

    // MARK: - Single-channel (BC4) blocks

    /// The eight reachable values when `e0 > e1`: both endpoints plus six
    /// interpolants. The alternative mode trades two interpolants for exact 0
    /// and 255, which is worse for continuous data like normals and roughness.
    static func bc4Palette(_ e0: UInt8, _ e1: UInt8) -> [Int] {
        var palette = [Int(e0), Int(e1)]
        guard e0 > e1 else {
            // Six-value mode: four interpolants then hard 0 and 255.
            for i in 0 ..< 4 { palette.append((Int(e0) * (4 - i) + Int(e1) * (i + 1)) / 5) }
            palette.append(0)
            palette.append(255)
            return palette
        }
        for i in 0 ..< 6 { palette.append((Int(e0) * (6 - i) + Int(e1) * (i + 1)) / 7) }
        return palette
    }

    /// Encodes 16 single-channel texels into an 8-byte BC4 block.
    static func encodeBC4(_ texels: [UInt8]) -> [UInt8] {
        precondition(texels.count == 16)
        let high = texels.max() ?? 0, low = texels.min() ?? 0
        // Flat block: endpoints equal, every index 0 reproduces it exactly.
        guard high > low else { return [high, low, 0, 0, 0, 0, 0, 0] }

        let palette = bc4Palette(high, low)
        var bits: UInt64 = 0
        for (pixel, value) in texels.enumerated() {
            var best = 0, bestError = Int.max
            for (index, candidate) in palette.enumerated() {
                let error = abs(candidate - Int(value))
                if error < bestError { bestError = error; best = index }
            }
            bits |= UInt64(best) << (3 * pixel)
        }
        var block: [UInt8] = [high, low]
        for byte in 0 ..< 6 { block.append(UInt8((bits >> (8 * byte)) & 0xFF)) }
        return block
    }

    static func decodeBC4(_ block: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = Array(block)
        precondition(bytes.count == 8)
        let palette = bc4Palette(bytes[0], bytes[1])
        var bits: UInt64 = 0
        for byte in 0 ..< 6 { bits |= UInt64(bytes[2 + byte]) << (8 * byte) }
        return (0 ..< 16).map { UInt8(clamping: palette[Int((bits >> (3 * $0)) & 0x7)]) }
    }

    // MARK: - Colour (BC1) blocks

    static func pack565(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt16 {
        let r5 = (UInt16(r) * 31 + 127) / 255
        let g6 = (UInt16(g) * 63 + 127) / 255
        let b5 = (UInt16(b) * 31 + 127) / 255
        return r5 << 11 | g6 << 5 | b5
    }

    /// Mirrors the hardware's bit-replication expansion, not a divide.
    static func unpack565(_ value: UInt16) -> (r: Int, g: Int, b: Int) {
        let r5 = Int((value >> 11) & 0x1F), g6 = Int((value >> 5) & 0x3F), b5 = Int(value & 0x1F)
        return (r5 << 3 | r5 >> 2, g6 << 2 | g6 >> 4, b5 << 3 | b5 >> 2)
    }

    /// Encodes 16 RGB texels (as RGBA bytes, alpha ignored) into 8 BC1 bytes.
    ///
    /// Endpoints come from the bounding box along the dominant colour axis,
    /// then one least-squares refinement pass against the assigned indices.
    /// That is markedly better than bounding box alone on the smooth gradients
    /// that dominate albedo and ORM maps, and far cheaper than an exhaustive
    /// search that would not change the result materially.
    static func encodeBC1(_ rgba: [UInt8]) -> [UInt8] {
        precondition(rgba.count == 64)
        var channelLow = [255, 255, 255], channelHigh = [0, 0, 0]
        for pixel in 0 ..< 16 {
            for c in 0 ..< 3 {
                let value = Int(rgba[pixel * 4 + c])
                channelLow[c] = min(channelLow[c], value)
                channelHigh[c] = max(channelHigh[c], value)
            }
        }
        var e0 = pack565(UInt8(channelHigh[0]), UInt8(channelHigh[1]), UInt8(channelHigh[2]))
        var e1 = pack565(UInt8(channelLow[0]), UInt8(channelLow[1]), UInt8(channelLow[2]))

        // Flat block: a single endpoint plus all-zero indices is exact, and
        // avoids selecting the punch-through mode by accident.
        if e0 == e1 { return [UInt8(e0 & 0xFF), UInt8(e0 >> 8), UInt8(e1 & 0xFF), UInt8(e1 >> 8), 0, 0, 0, 0] }
        // Four-colour mode requires e0 > e1; below that the hardware reads
        // index 3 as transparent black.
        if e0 < e1 { swap(&e0, &e1) }

        func assign(_ a: UInt16, _ b: UInt16) -> [Int] {
            let c0 = unpack565(a), c1 = unpack565(b)
            let palette = [c0, c1,
                           ((2 * c0.r + c1.r) / 3, (2 * c0.g + c1.g) / 3, (2 * c0.b + c1.b) / 3),
                           ((c0.r + 2 * c1.r) / 3, (c0.g + 2 * c1.g) / 3, (c0.b + 2 * c1.b) / 3)]
            return (0 ..< 16).map { pixel in
                let r = Int(rgba[pixel * 4]), g = Int(rgba[pixel * 4 + 1]), b = Int(rgba[pixel * 4 + 2])
                var best = 0, bestError = Int.max
                for (index, p) in palette.enumerated() {
                    let dr = p.0 - r, dg = p.1 - g, db = p.2 - b
                    let error = dr * dr + dg * dg + db * db
                    if error < bestError { bestError = error; best = index }
                }
                return best
            }
        }

        // Refine endpoints by least squares on the index weights, then keep the
        // result only if it actually lowered the error.
        var indices = assign(e0, e1)
        let weights: [Double] = [1, 0, 2.0 / 3.0, 1.0 / 3.0]
        var sumWW = 0.0, sumW = 0.0, count = 0.0
        var sumWC = [0.0, 0.0, 0.0], sumC = [0.0, 0.0, 0.0]
        for (pixel, index) in indices.enumerated() {
            let w = weights[index]
            sumWW += w * w; sumW += w; count += 1
            for c in 0 ..< 3 {
                let value = Double(rgba[pixel * 4 + c])
                sumWC[c] += w * value
                sumC[c] += value
            }
        }
        let determinant = sumWW * count - sumW * sumW
        if abs(determinant) > 1e-6 {
            var high = [UInt8](repeating: 0, count: 3), low = [UInt8](repeating: 0, count: 3)
            for c in 0 ..< 3 {
                let a = (sumWC[c] * count - sumW * sumC[c]) / determinant
                let b = (sumWW * sumC[c] - sumW * sumWC[c]) / determinant
                high[c] = UInt8(max(0, min(255, (a + b).rounded())))
                low[c] = UInt8(max(0, min(255, b.rounded())))
            }
            var r0 = pack565(high[0], high[1], high[2]), r1 = pack565(low[0], low[1], low[2])
            if r0 != r1 {
                if r0 < r1 { swap(&r0, &r1) }
                func error(_ a: UInt16, _ b: UInt16, _ assigned: [Int]) -> Int {
                    let c0 = unpack565(a), c1 = unpack565(b)
                    let palette = [c0, c1,
                                   ((2 * c0.r + c1.r) / 3, (2 * c0.g + c1.g) / 3, (2 * c0.b + c1.b) / 3),
                                   ((c0.r + 2 * c1.r) / 3, (c0.g + 2 * c1.g) / 3, (c0.b + 2 * c1.b) / 3)]
                    var total = 0
                    for (pixel, index) in assigned.enumerated() {
                        let p = palette[index]
                        let dr = p.0 - Int(rgba[pixel * 4]), dg = p.1 - Int(rgba[pixel * 4 + 1]), db = p.2 - Int(rgba[pixel * 4 + 2])
                        total += dr * dr + dg * dg + db * db
                    }
                    return total
                }
                let refined = assign(r0, r1)
                if error(r0, r1, refined) < error(e0, e1, indices) { e0 = r0; e1 = r1; indices = refined }
            }
        }

        var packed: UInt32 = 0
        for (pixel, index) in indices.enumerated() { packed |= UInt32(index) << (2 * pixel) }
        return [UInt8(e0 & 0xFF), UInt8(e0 >> 8), UInt8(e1 & 0xFF), UInt8(e1 >> 8),
                UInt8(packed & 0xFF), UInt8((packed >> 8) & 0xFF),
                UInt8((packed >> 16) & 0xFF), UInt8((packed >> 24) & 0xFF)]
    }

    /// Encodes 16 texels of three quantities that are not a colour — the
    /// channels of a data map, each with its own importance — into 8 BC1
    /// bytes, alpha ignored.
    ///
    /// A block is two endpoints and a line between them, and `encodeBC1`
    /// takes that line from the corner of the bounding box where every
    /// channel is low to the one where every channel is high. A colour
    /// mostly runs that way. Two unrelated quantities as often run against
    /// each other, so here the line is the principal axis of the block's
    /// texels, each channel scaled by its weight, and the endpoints are then
    /// refined by least squares against the indices, a few rounds, keeping a
    /// round only if it lowered the weighted error.
    static func encodeBC1(_ rgba: [UInt8], weights: SIMD3<Double>) -> [UInt8] {
        precondition(rgba.count == 64)
        let scale = SIMD3(weights.x.squareRoot(), weights.y.squareRoot(), weights.z.squareRoot())
        var points = [SIMD3<Double>](repeating: .zero, count: 16)
        var mean = SIMD3<Double>.zero, low = SIMD3<Double>(repeating: 255), high = SIMD3<Double>.zero
        for pixel in 0 ..< 16 {
            let value = SIMD3(Double(rgba[pixel * 4]), Double(rgba[pixel * 4 + 1]), Double(rgba[pixel * 4 + 2]))
            points[pixel] = value
            mean += value
            low = simd_min(low, value); high = simd_max(high, value)
        }
        mean /= 16
        func block(_ e0: UInt16, _ e1: UInt16, _ indices: [Int]) -> [UInt8] {
            var packed: UInt32 = 0
            for (pixel, index) in indices.enumerated() { packed |= UInt32(index) << (2 * pixel) }
            return [UInt8(e0 & 0xFF), UInt8(e0 >> 8), UInt8(e1 & 0xFF), UInt8(e1 >> 8),
                    UInt8(packed & 0xFF), UInt8((packed >> 8) & 0xFF),
                    UInt8((packed >> 16) & 0xFF), UInt8((packed >> 24) & 0xFF)]
        }
        func pack(_ value: SIMD3<Double>) -> UInt16 {
            func byte(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }
            return pack565(byte(value.x), byte(value.y), byte(value.z))
        }
        // The principal axis, by power iteration on the weighted covariance,
        // started along the bounding box so a block with one channel moving
        // converges at once.
        var covariance = simd_double3x3()
        for point in points {
            let d = (point - mean) * scale
            covariance += simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        var axis = (high - low) * scale + SIMD3(repeating: 1e-3)
        for _ in 0 ..< 8 {
            let next = covariance * axis
            let length = simd_length(next)
            if length < 1e-9 { break }
            axis = next / length
        }
        axis = simd_normalize(axis)
        var nearest = Double.infinity, farthest = -Double.infinity
        for point in points {
            let t = simd_dot((point - mean) * scale, axis)
            nearest = min(nearest, t); farthest = max(farthest, t)
        }
        var e0 = pack(mean + axis * farthest / scale), e1 = pack(mean + axis * nearest / scale)
        // Flat once quantized: one endpoint and index zero everywhere, which
        // also keeps clear of the punch-through mode.
        if e0 == e1 { return block(e0, e1, [Int](repeating: 0, count: 16)) }
        if e0 < e1 { swap(&e0, &e1) }

        func assign(_ a: UInt16, _ b: UInt16) -> (indices: [Int], error: Double) {
            let c0 = unpack565(a), c1 = unpack565(b)
            let palette = [c0, c1,
                           ((2 * c0.r + c1.r) / 3, (2 * c0.g + c1.g) / 3, (2 * c0.b + c1.b) / 3),
                           ((c0.r + 2 * c1.r) / 3, (c0.g + 2 * c1.g) / 3, (c0.b + 2 * c1.b) / 3)]
                .map { SIMD3(Double($0.0), Double($0.1), Double($0.2)) }
            var indices = [Int](repeating: 0, count: 16), total = 0.0
            for (pixel, point) in points.enumerated() {
                var best = 0, bestError = Double.infinity
                for (index, candidate) in palette.enumerated() {
                    let d = candidate - point
                    let error = simd_dot(d * d, weights)
                    if error < bestError { bestError = error; best = index }
                }
                indices[pixel] = best
                total += bestError
            }
            return (indices, total)
        }
        var (indices, error) = assign(e0, e1)
        let position: [Double] = [1, 0, 2.0 / 3.0, 1.0 / 3.0]
        for _ in 0 ..< 3 {
            var sumWW = 0.0, sumW = 0.0
            var sumWC = SIMD3<Double>.zero, sumC = SIMD3<Double>.zero
            for (pixel, index) in indices.enumerated() {
                let w = position[index]
                sumWW += w * w; sumW += w
                sumWC += points[pixel] * w
                sumC += points[pixel]
            }
            let determinant = sumWW * 16 - sumW * sumW
            guard abs(determinant) > 1e-6 else { break }
            let a = (sumWC * 16 - sumC * sumW) / determinant
            let b = (sumC * sumWW - sumWC * sumW) / determinant
            var r0 = pack(a + b), r1 = pack(b)
            guard r0 != r1 else { break }
            if r0 < r1 { swap(&r0, &r1) }
            let refined = assign(r0, r1)
            guard refined.error < error else { break }
            e0 = r0; e1 = r1; indices = refined.indices; error = refined.error
        }
        return block(e0, e1, indices)
    }

    static func decodeBC1(_ block: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = Array(block)
        precondition(bytes.count == 8)
        let e0 = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let e1 = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        let c0 = unpack565(e0), c1 = unpack565(e1)
        var palette = [c0, c1]
        if e0 > e1 {
            palette.append(((2 * c0.r + c1.r) / 3, (2 * c0.g + c1.g) / 3, (2 * c0.b + c1.b) / 3))
            palette.append(((c0.r + 2 * c1.r) / 3, (c0.g + 2 * c1.g) / 3, (c0.b + 2 * c1.b) / 3))
        } else {
            palette.append(((c0.r + c1.r) / 2, (c0.g + c1.g) / 2, (c0.b + c1.b) / 2))
            palette.append((0, 0, 0))
        }
        var packed: UInt32 = 0
        for byte in 0 ..< 4 { packed |= UInt32(bytes[4 + byte]) << (8 * byte) }
        var out = [UInt8](repeating: 255, count: 64)
        for pixel in 0 ..< 16 {
            let p = palette[Int((packed >> (2 * pixel)) & 0x3)]
            out[pixel * 4] = UInt8(clamping: p.0)
            out[pixel * 4 + 1] = UInt8(clamping: p.1)
            out[pixel * 4 + 2] = UInt8(clamping: p.2)
        }
        return out
    }
}

// MARK: - Image level

public extension BlockCompression {
    static func blocksWide(_ width: Int) -> Int { max(1, (width + 3) / 4) }
    static func blocksHigh(_ height: Int) -> Int { max(1, (height + 3) / 4) }

    static func encodedSize(width: Int, height: Int, format: Format) -> Int {
        blocksWide(width) * blocksHigh(height) * format.bytesPerBlock
    }

    /// Compresses a straight (non-premultiplied) RGBA8 image.
    ///
    /// Dimensions need not be multiples of four: partial blocks clamp to the
    /// last real texel rather than padding with black, which matters because
    /// every mip chain ends at 2x2 and 1x1. Padding with black would bleed dark
    /// edges into the smallest mips, and those are exactly the levels a distant
    /// road surface samples.
    ///
    /// - Parameter dataWeights: for BC1 and BC3 holding a data map rather
    ///   than a colour, the importance of the red, green and blue channels;
    ///   the colour block is then fitted as `encodeBC1(_:weights:)` does.
    static func encode(_ rgba: [UInt8], width: Int, height: Int, format: Format,
                       dataWeights: SIMD3<Double>? = nil) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw ACError.invalid("Block compression needs a nonempty image") }
        guard rgba.count == width * height * 4 else {
            throw ACError.invalid("Expected \(width * height * 4) RGBA bytes, got \(rgba.count)")
        }
        var output = [UInt8]()
        output.reserveCapacity(encodedSize(width: width, height: height, format: format))

        for blockY in 0 ..< blocksHigh(height) {
            for blockX in 0 ..< blocksWide(width) {
                // Gather the 4x4 neighbourhood with edge clamping.
                var texels = [UInt8](repeating: 0, count: 64)
                for row in 0 ..< 4 {
                    let y = min(blockY * 4 + row, height - 1)
                    for column in 0 ..< 4 {
                        let x = min(blockX * 4 + column, width - 1)
                        let source = (y * width + x) * 4, destination = (row * 4 + column) * 4
                        for c in 0 ..< 4 { texels[destination + c] = rgba[source + c] }
                    }
                }
                func channel(_ c: Int) -> [UInt8] { (0 ..< 16).map { texels[$0 * 4 + c] } }
                func colour() -> [UInt8] { dataWeights.map { encodeBC1(texels, weights: $0) } ?? encodeBC1(texels) }
                switch format {
                case .bc1: output.append(contentsOf: colour())
                case .bc3:
                    output.append(contentsOf: encodeBC4(channel(3)))
                    output.append(contentsOf: colour())
                case .bc4: output.append(contentsOf: encodeBC4(channel(0)))
                case .bc5:
                    output.append(contentsOf: encodeBC4(channel(0)))
                    output.append(contentsOf: encodeBC4(channel(1)))
                }
            }
        }
        return output
    }

    /// Reference decode, matching the hardware's fixed-point rules. Used to
    /// measure encoder error in tests and by asset verification tooling.
    static func decode(_ data: [UInt8], width: Int, height: Int, format: Format) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw ACError.invalid("Block decode needs a nonempty image") }
        guard data.count == encodedSize(width: width, height: height, format: format) else {
            throw ACError.invalid("Expected \(encodedSize(width: width, height: height, format: format)) compressed bytes, got \(data.count)")
        }
        // Unwritten channels read as opaque black, matching the shader's view.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< width * height { rgba[i * 4 + 3] = 255 }
        var offset = 0

        for blockY in 0 ..< blocksHigh(height) {
            for blockX in 0 ..< blocksWide(width) {
                var colour = [UInt8](repeating: 0, count: 64)
                var alpha: [UInt8]? = nil, green: [UInt8]? = nil
                switch format {
                case .bc1: colour = decodeBC1(data[offset ..< offset + 8])
                case .bc3:
                    alpha = decodeBC4(data[offset ..< offset + 8])
                    colour = decodeBC1(data[offset + 8 ..< offset + 16])
                case .bc4:
                    let red = decodeBC4(data[offset ..< offset + 8])
                    for i in 0 ..< 16 { colour[i * 4] = red[i] }
                case .bc5:
                    let red = decodeBC4(data[offset ..< offset + 8])
                    green = decodeBC4(data[offset + 8 ..< offset + 16])
                    for i in 0 ..< 16 { colour[i * 4] = red[i] }
                }
                offset += format.bytesPerBlock

                for row in 0 ..< 4 {
                    let y = blockY * 4 + row
                    guard y < height else { continue }
                    for column in 0 ..< 4 {
                        let x = blockX * 4 + column
                        guard x < width else { continue }
                        let source = row * 4 + column, destination = (y * width + x) * 4
                        rgba[destination] = colour[source * 4]
                        rgba[destination + 1] = green?[source] ?? colour[source * 4 + 1]
                        rgba[destination + 2] = colour[source * 4 + 2]
                        rgba[destination + 3] = alpha?[source] ?? 255
                    }
                }
            }
        }
        return rgba
    }
}
