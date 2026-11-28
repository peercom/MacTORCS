// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSTrack
import TORCSTrackMesh
import TORCSMaterials

/// A garage's front, and the sets it is made of.
final class PitBuildingTests: XCTestCase {
    /// A garage fifteen metres long on level ground, its front along x and
    /// facing -y, so that seen from the lane its left end is at x = 0.
    private func garage(length: Float = 15, depth: Float = 7) -> PitGeneration.Garage {
        PitGeneration.Garage(floor: [SIMD3(0, 0, 0), SIMD3(length, 0, 0), SIMD3(length, depth, 0), SIMD3(0, depth, 0)])
    }

    private func built(number: Int = 2, length: Float = 15, _ change: (inout PitGeneration.Parameters) -> Void = { _ in })
        -> (groups: [String: GeneratedGeometry], parameters: PitGeneration.Parameters) {
        var parameters = PitGeneration.Parameters()
        change(&parameters)
        var groups = [GeneratedGeometry](repeating: GeneratedGeometry(), count: PitGeneration.materials.count)
        PitGeneration.build(garage(length: length), number: number, parameters: parameters, into: &groups)
        return (Dictionary(uniqueKeysWithValues: zip(PitGeneration.materials, groups)), parameters)
    }

    func testAFrontIsDividedIntoBaysAboutFiveMetresWide() {
        XCTAssertEqual(PitGeneration.bays(length: 15), 3)
        XCTAssertEqual(PitGeneration.bays(length: 14.7), 3)
        XCTAssertEqual(PitGeneration.bays(length: 8), 2)
        XCTAssertEqual(PitGeneration.bays(length: 5), 1)
        XCTAssertEqual(PitGeneration.bays(length: 1), 1)
    }

    func testDoorsStandBackBetweenPiers() {
        let (groups, p) = built()
        let doors = groups["roller-door"]!
        // Three doors, all down, each a quad: set back from the piers' face,
        // from the floor to the band, and narrower than its bay by a pier.
        XCTAssertEqual(doors.positions.count, 3 * 4)
        for quad in stride(from: 0, to: doors.positions.count, by: 4) {
            let corners = doors.positions[quad ..< quad + 4]
            XCTAssertTrue(corners.allSatisfy { abs($0.y - p.recess) < 1e-4 }, "set back")
            XCTAssertEqual(corners.map(\.z).min()!, 0, accuracy: 1e-5); XCTAssertEqual(corners.map(\.z).max()!, p.doorHeight, accuracy: 1e-5)
            XCTAssertEqual(corners.map(\.x).max()! - corners.map(\.x).min()!, 5 - p.pier, accuracy: 1e-3)
            // Its laths count up from the floor, in metres.
            for i in quad ..< quad + 4 { XCTAssertEqual(doors.uv0[i].y, doors.positions[i].z, accuracy: 1e-5) }
            XCTAssertTrue(doors.normals[quad ..< quad + 4].allSatisfy { $0.y < -0.99 }, "faces the lane")
        }
        // Piers stand at the piers' face, and the front runs on past the
        // footprint at both ends to meet the next garage's.
        let piers = groups["blockwork"]!
        let onFace = piers.positions.indices.filter { abs(piers.positions[$0].y) < 1e-4 && piers.normals[$0].y < -0.99 && piers.positions[$0].z <= p.doorHeight + 1e-4 }
        XCTAssertEqual(onFace.count, 4 * 4, "four piers to three doors")
        // They go on down below the floor, for ground that falls away.
        XCTAssertEqual(onFace.map { piers.positions[$0].z }.min()!, -p.footing, accuracy: 1e-5)
        // Under each door a sill, from the door to just in front of the
        // piers: the doorway's floor is the building's and not the grass.
        let sills = piers.positions.indices.filter { piers.normals[$0].z > 0.99 && abs(piers.positions[$0].z - 0.03) < 1e-4 }
        XCTAssertEqual(sills.count, 3 * 4)
        XCTAssertEqual(sills.map { piers.positions[$0].y }.max()!, p.recess, accuracy: 1e-4)
        XCTAssertLessThan(sills.map { piers.positions[$0].y }.min()!, 0)
        XCTAssertLessThan(onFace.map { piers.positions[$0].x }.min()!, -p.gap / 2)
        XCTAssertGreaterThan(onFace.map { piers.positions[$0].x }.max()!, 15 + p.gap / 2)
        // Nothing of a closed garage is inside it.
        XCTAssertTrue(groups["interior"]!.isEmpty)
    }

    func testTheBandIsOneTileUpAndCarriesTheNumber() {
        let (groups, p) = built(number: 27)
        let band = groups["fascia"]!
        XCTAssertEqual(band.positions.count, 4)
        XCTAssertEqual(Set(band.uv0.map(\.y)), [0, 1], "once up it, whatever its height")
        XCTAssertEqual(band.positions.map(\.z).min()!, p.doorHeight, accuracy: 1e-5); XCTAssertEqual(band.positions.map(\.z).max()!, p.height, accuracy: 1e-5)
        // Two figures, two plates, side by side in the middle of the garage,
        // just proud of the band, in the band's clear part.
        let plates = groups["numbers"]!
        XCTAssertEqual(plates.positions.count, 2 * 4)
        XCTAssertEqual(plates.positions.map(\.x).reduce(0, +) / 8, 7.5, accuracy: 1e-3)
        XCTAssertTrue(plates.positions.allSatisfy { $0.y < 0 && $0.y > -0.05 })
        XCTAssertGreaterThan(plates.positions.map(\.z).min()!, p.doorHeight + 0.21 * (p.height - p.doorHeight))
        XCTAssertLessThan(plates.positions.map(\.z).max()!, p.doorHeight + 0.92 * (p.height - p.doorHeight))
        // The 2 is to the left of the 7 as the front is looked at, and each
        // shows its own figure's part of the sheet, the right way up.
        for (index, digit) in [2, 7].enumerated() {
            let corners = Array(index * 4 ..< index * 4 + 4)
            let plate = MaterialRecipes.figurePlate(digit)
            let us = corners.map { plates.uv0[$0].x }, vs = corners.map { plates.uv0[$0].y }
            XCTAssertEqual(us.min()!, plate.origin.x, accuracy: 1e-5); XCTAssertEqual(us.max()!, plate.origin.x + plate.size.x, accuracy: 1e-5)
            XCTAssertEqual(vs.min()!, plate.origin.y, accuracy: 1e-5); XCTAssertEqual(vs.max()!, plate.origin.y + plate.size.y, accuracy: 1e-5)
            for i in corners {
                // The front faces -y: a viewer in the lane looks along +y,
                // and their right is +x.
                let leftmost = abs(plates.positions[i].x - corners.map { plates.positions[$0].x }.min()!) < 1e-4
                XCTAssertEqual(plates.uv0[i].x == us.min()!, leftmost, "u runs left to right as seen")
                let lowest = abs(plates.positions[i].z - corners.map { plates.positions[$0].z }.min()!) < 1e-4
                XCTAssertEqual(plates.uv0[i].y == vs.min()!, lowest)
            }
        }
        // The 2's plate is the one the viewer sees on the left: at smaller x.
        XCTAssertLessThan(plates.positions[0 ..< 4].map(\.x).max()!, plates.positions[4 ..< 8].map(\.x).max()!)
    }

    func testTheRoofComesOutOverTheLane() {
        let (groups, p) = built()
        let roof = groups["roofing"]!
        XCTAssertEqual(roof.positions.count, 4)
        XCTAssertEqual(roof.positions.map(\.y).min()!, -p.overhang, accuracy: 1e-4, "out over the lane")
        XCTAssertEqual(roof.positions.map(\.y).max()!, p.depth, accuracy: 1e-4, "back to the back wall")
        XCTAssertTrue(roof.positions.allSatisfy { abs($0.z - (p.height + p.roofThickness)) < 1e-4 })
        XCTAssertTrue(roof.normals.allSatisfy { $0.z == 1 })
        // Its underside looks down, over the lane, at the band's top.
        let blocks = groups["blockwork"]!
        let under = blocks.positions.indices.filter { blocks.normals[$0].z < -0.99 && abs(blocks.positions[$0].z - p.height) < 1e-4 }
        XCTAssertEqual(under.count, 4)
        XCTAssertEqual(under.map { blocks.positions[$0].y }.min()!, -p.overhang, accuracy: 1e-4)
    }

    func testOneGarageInThreeHasADoorPartRaised() {
        XCTAssertEqual(PitGeneration.raisedBay(number: 1, bays: 3), 0)
        XCTAssertNil(PitGeneration.raisedBay(number: 2, bays: 3)); XCTAssertNil(PitGeneration.raisedBay(number: 3, bays: 3))
        XCTAssertEqual(PitGeneration.raisedBay(number: 4, bays: 3), 1)
        XCTAssertEqual(PitGeneration.raisedBay(number: 7, bays: 3), 2)
        XCTAssertEqual(PitGeneration.raisedBay(number: 10, bays: 3), 0)
        var never = PitGeneration.Parameters(); never.openEvery = 0
        XCTAssertNil(PitGeneration.raisedBay(number: 1, bays: 3, parameters: never))

        let (groups, p) = built(number: 4)
        let doors = groups["roller-door"]!
        XCTAssertEqual(doors.positions.count, 3 * 4)
        // The middle door hangs from the band with its foot part way up; its
        // laths still count from the floor.
        let feet = stride(from: 0, to: 12, by: 4).map { doors.positions[$0 ..< $0 + 4].map(\.z).min()! }
        XCTAssertEqual(feet.filter { $0 == 0 }.count, 2)
        let raised = try! XCTUnwrap(feet.first { $0 > 0 })
        XCTAssertEqual(raised, p.doorHeight * p.raised, accuracy: 1e-4)
        XCTAssertTrue(doors.uv0.indices.allSatisfy { abs(doors.uv0[$0].y - doors.positions[$0].z) < 1e-5 })
        // Behind it: a back wall, two sides, a floor and a ceiling, all
        // looking into the room, none of it outside the building.
        let room = groups["interior"]!
        XCTAssertEqual(room.positions.count, 5 * 4)
        XCTAssertTrue(room.positions.allSatisfy { $0.y >= p.recess - 1e-4 && $0.y <= p.depth && $0.z >= 0 && $0.z <= p.doorHeight + 1e-4 })
        // Its floor is just above the ground at the door and rises to the
        // back, over ground that was not levelled for it.
        let floor = room.positions.indices.filter { room.normals[$0].z > 0.9 }
        XCTAssertEqual(floor.count, 4)
        XCTAssertEqual(floor.map { room.positions[$0].z }.min()!, 0.03, accuracy: 1e-4)
        XCTAssertEqual(floor.map { room.positions[$0].z }.max()!, 0.03 + p.room * p.floorRise, accuracy: 1e-3)
        let centre = room.positions.reduce(SIMD3<Float>.zero, +) / Float(room.positions.count)
        for quad in stride(from: 0, to: room.positions.count, by: 4) {
            let middle = room.positions[quad ..< quad + 4].reduce(SIMD3<Float>.zero, +) / 4
            XCTAssertGreaterThan(simd_dot(room.normals[quad], centre - middle), 0, "a wall of the room looks into it")
        }
    }

    func testWindingAgreesWithTheNormalsWhicheverWayTheGarageFaces() {
        // The same garage turned to face +y, as on the other side of a track.
        for flipped in [false, true] {
            let floor: [SIMD3<Float>] = flipped
                ? [SIMD3(0, 0, 0), SIMD3(15, 0, 0), SIMD3(15, -7, 0), SIMD3(0, -7, 0)]
                : [SIMD3(0, 0, 0), SIMD3(15, 0, 0), SIMD3(15, 7, 0), SIMD3(0, 7, 0)]
            var groups = [GeneratedGeometry](repeating: GeneratedGeometry(), count: PitGeneration.materials.count)
            PitGeneration.build(PitGeneration.Garage(floor: floor), number: 14, parameters: .init(), into: &groups)
            for g in groups {
                for i in stride(from: 0, to: g.indices.count, by: 3) {
                    let a = g.positions[Int(g.indices[i])], b = g.positions[Int(g.indices[i + 1])], c = g.positions[Int(g.indices[i + 2])]
                    XCTAssertGreaterThan(simd_dot(simd_cross(b - a, c - a), g.normals[Int(g.indices[i])]), 0)
                }
            }
            // The 1 is on the viewer's left either way: the viewer looks
            // along the front's own direction reversed.
            let plates = groups[3]
            let front: Float = flipped ? 1 : -1                    // the front faces this way along y
            let one = plates.positions[0 ..< 4].map(\.x).reduce(0, +) / 4, four = plates.positions[4 ..< 8].map(\.x).reduce(0, +) / 4
            // Facing -y the viewer looks along +y and their right is +x.
            XCTAssertEqual(one < four, front < 0, "\(flipped)")
            XCTAssertTrue(plates.normals.allSatisfy { $0.y * front > 0.99 })
        }
    }
}

/// The sets a pit building is made of.
extension PitBuildingTests {
    private func rows(_ material: GeneratedMaterial, channel: Int, of map: KeyPath<GeneratedMaterial, [UInt8]>) -> [Float] {
        let size = material.size
        return (0 ..< size).map { y in
            (0 ..< size).reduce(Float(0)) { $0 + Float(material[keyPath: map][(y * size + $1) * 4 + channel]) } / Float(size) / 255
        }
    }

    func testARollerDoorIsTenLathsToTheMetre() throws {
        let door = try MaterialRecipes.generate("roller-door", size: 200, seed: 1)
        XCTAssertEqual(door.worldSize, 1)
        // Each lath's joint is a dark row in the colour: ten of them up a tile.
        let light = rows(door, channel: 1, of: \.albedo)
        let mean = light.reduce(0, +) / Float(light.count)
        var joints = 0
        for y in 0 ..< light.count where light[y] < mean * 0.85 && light[(y + light.count - 1) % light.count] >= mean * 0.85 { joints += 1 }
        XCTAssertEqual(joints, 10)
        // Painted steel: light, no metal in the map, not a mirror.
        XCTAssertGreaterThan(mean, 0.55)
        XCTAssertFalse(door.isMetal)
    }

    func testBlockworkIsTenCoursesInRunningBond() throws {
        let wall = try MaterialRecipes.generate("blockwork", size: 200, seed: 1)
        XCTAssertEqual(wall.worldSize, 2)
        let light = rows(wall, channel: 1, of: \.albedo)
        let mean = light.reduce(0, +) / Float(light.count)
        var beds = 0
        for y in 0 ..< light.count where light[y] < mean * 0.93 && light[(y + light.count - 1) % light.count] >= mean * 0.93 { beds += 1 }
        XCTAssertEqual(beds, 10, "ten courses to two metres")
        // Running bond: a course's upright joints are half a block from the next's.
        func joint(_ x: Int, _ y: Int) -> Bool { Float(wall.albedo[(y * 200 + x) * 4 + 1]) / 255 < mean * 0.9 }
        XCTAssertTrue(joint(0, 10) || joint(1, 10) || joint(199, 10)); XCTAssertFalse(joint(20, 10))
        XCTAssertTrue(joint(20, 30) || joint(19, 30) || joint(21, 30)); XCTAssertFalse(joint(0, 30) || joint(1, 30))
    }

    func testTheBandHasItsStripeAtItsFootAndItsCopingOnTop() throws {
        let band = try MaterialRecipes.generate("pit-fascia", size: 200, seed: 1)
        XCTAssertEqual(band.worldSize, 1)
        let red = rows(band, channel: 0, of: \.albedo), green = rows(band, channel: 1, of: \.albedo)
        // Rows are top first: the foot of the band is the last of them.
        let stripe = (0 ..< 200).filter { red[$0] > green[$0] * 2 }
        XCTAssertFalse(stripe.isEmpty)
        XCTAssertGreaterThan(stripe.min()!, 150, "the stripe is at the foot"); XCTAssertLessThan(stripe.max()!, 190)
        XCTAssertLessThan(green[5], 0.4, "a dark coping along the top")
        XCTAssertGreaterThan(green[100], 0.6, "white between")
    }

    func testEveryFigureHasItsPlateAndIsItself() throws {
        // Ten figures, each unlike the others, each filling a sensible part of its box.
        var shapes: [[Bool]] = []
        for digit in 0 ... 9 {
            var shape: [Bool] = []
            for row in 0 ..< 28 { for column in 0 ..< 20 {
                shape.append(MaterialRecipes.figure(digit, along: (Float(column) + 0.5) / 20, up: 1 - (Float(row) + 0.5) / 28) > 0.5)
            } }
            let filled = Float(shape.filter { $0 }.count) / Float(shape.count)
            XCTAssertGreaterThan(filled, 0.15, "\(digit)"); XCTAssertLessThan(filled, 0.6, "\(digit)")
            shapes.append(shape)
        }
        for a in 0 ... 9 { for b in 0 ..< a {
            let differing = zip(shapes[a], shapes[b]).filter { $0 != $1 }.count
            XCTAssertGreaterThan(differing, 30, "\(a) and \(b) look alike")
        } }
        XCTAssertEqual(MaterialRecipes.figure(10, along: 0.5, up: 0.5), 0); XCTAssertEqual(MaterialRecipes.figure(3, along: 1.2, up: 0.5), 0)
        // A 1 is a stroke down its middle; a 7 has a bar along its top and nothing at its foot's left.
        XCTAssertGreaterThan(MaterialRecipes.figure(1, along: 0.5, up: 0.5), 0.5); XCTAssertLessThan(MaterialRecipes.figure(1, along: 0.1, up: 0.5), 0.5)
        XCTAssertGreaterThan(MaterialRecipes.figure(7, along: 0.5, up: 0.93), 0.5); XCTAssertLessThan(MaterialRecipes.figure(7, along: 0.1, up: 0.07), 0.5)

        // On the sheet: four plates across and three up, the 0 at the top left,
        // white where the figure is and dark blue round it.
        let sheet = try MaterialRecipes.generate("pit-numbers", size: 240, seed: 1)
        func light(_ u: Float, _ v: Float) -> Float {
            let x = min(Int(u * 240), 239), y = min(Int((1 - v) * 240), 239)
            return Float(sheet.albedo[(y * 240 + x) * 4 + 1]) / 255
        }
        for digit in 0 ... 9 {
            let plate = MaterialRecipes.figurePlate(digit)
            XCTAssertEqual(plate.size, SIMD2(0.25, 1.0 / 3))
            var white = 0, dark = 0
            for row in 0 ..< 28 { for column in 0 ..< 20 {
                // The figure's own box inside its plate.
                let along = (Float(column) + 0.5) / 20, up = 1 - (Float(row) + 0.5) / 28
                let u = plate.origin.x + plate.size.x * (0.195 + along * 0.61), v = plate.origin.y + plate.size.y * (0.18 + up * 0.64)
                let expected = shapes[digit][row * 20 + column]
                if light(u, v) > 0.5 { white += expected ? 1 : 0 } else { dark += expected ? 0 : 1 }
            } }
            XCTAssertGreaterThan(white + dark, 20 * 28 * 85 / 100, "\(digit) is not on its plate")
        }
        XCTAssertEqual(MaterialRecipes.figurePlate(0).origin.x, 0); XCTAssertEqual(MaterialRecipes.figurePlate(0).origin.y, 2.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(MaterialRecipes.figurePlate(9).origin.x, 0.25); XCTAssertEqual(MaterialRecipes.figurePlate(9).origin.y, 0, accuracy: 1e-6)
        XCTAssertLessThan(light(0.875, 0.16), 0.3, "the two spare plates are blank")
    }

    func testARoofIsDarkFeltLaidInStrips() throws {
        let roof = try MaterialRecipes.generate("roofing", size: 200, seed: 1)
        XCTAssertEqual(roof.worldSize, 2)
        let light = rows(roof, channel: 1, of: \.albedo), rough = rows(roof, channel: 1, of: \.orm)
        let mean = light.reduce(0, +) / Float(light.count)
        XCTAssertLessThan(mean, 0.4, "dark")
        // Two laps to the tile: rows of tar, darker and smoother than the felt.
        var laps = 0
        for y in 0 ..< 200 where light[y] < mean * 0.7 && light[(y + 199) % 200] >= mean * 0.7 { laps += 1 }
        XCTAssertEqual(laps, 2)
        XCTAssertLessThan(rough.min()!, rough.reduce(0, +) / 200 - 0.1)
    }
}
