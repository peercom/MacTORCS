// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSTrack
import TORCSConfiguration
import TORCSAssets
@testable import TORCSRender

/// Trackgen bakes each strip under the texture its surface declares. The
/// strip rule takes those names from the track itself, so a circuit whose
/// surfaces are textured `road1.rgb` loses its baked road to the generated
/// one just as Aalborg loses its `tr-` strips.
final class SurfaceStripTests: XCTestCase {
    func testSurfacesCarryTheirTextureNames() throws {
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let parameters = try ParameterDocument.parse(Data(contentsOf: fixtures.appendingPathComponent("aalborg.xml")),
                                                     entities: ["default-surfaces": Data(contentsOf: fixtures.appendingPathComponent("surfaces.xml")),
                                                                "default-objects": Data(contentsOf: fixtures.appendingPathComponent("objects.xml"))],
                                                     allowLegacyLatin1: true)
        let road = try TrackBuilder.buildRoad(parameters: parameters)
        let textures = road.geometry.surfaceTextures
        XCTAssertTrue(textures.contains("tr-asphalt-aa-bw1_n.rgb"), "\(textures)")
        XCTAssertTrue(textures.contains { $0.hasPrefix("tr-barrier") || $0.hasPrefix("tr-curb") || $0.hasPrefix("tr-grass") }, "\(textures)")
        XCTAssertTrue(textures.allSatisfy { $0.hasPrefix("tr-") || $0.contains("tarmac-wall") },
                      "Aalborg's surfaces are exactly what the prefix rule already stripped: \(textures)")
    }

    private func batch(_ texture: String) throws -> RenderBatch {
        let mesh = try RenderMesh.build(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)],
                                        normals: Array(repeating: SIMD3(0, 0, 1), count: 3),
                                        uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1)], indices: [0, 1, 2])
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: texture, flags: 0, alphaClamp: 0)
        return RenderBatch(mesh: mesh, baseTexture: texture, blends: false, isDeferred: false, alphaTestThreshold: nil,
                           culls: true, isDriver: false, sourceMaterial: state,
                           material: ResolvedMaterial(baseColour: SIMD4(0.5, 0.5, 0.5, 1), roughness: 0.9, metallic: 0))
    }

    func testBakedRoadIsStrippedByItsSurfaceTextureOnAnyCircuit() throws {
        let scene = RenderScene(batches: [try batch("road1.rgb"), try batch("ROAD4.RGB"), try batch("house.rgb"),
                                          try batch("tr-asphalt-p_nmm.rgb"), try batch("textures/mur2.rgb")],
                                minimum: .zero, maximum: SIMD3(1, 1, 0))
        let prefixOnly = TrackSurfaceAssembly.strippingTrackgen(scene)
        XCTAssertEqual(prefixOnly.batches.map { $0.baseTexture! }, ["road1.rgb", "ROAD4.RGB", "house.rgb", "textures/mur2.rgb"],
                       "without the surfaces only the tr- strip goes")
        let withSurfaces = TrackSurfaceAssembly.strippingTrackgen(scene, surfaceTextures: ["road1.rgb", "road4.rgb", "mur2.rgb"])
        XCTAssertEqual(withSurfaces.batches.map { $0.baseTexture! }, ["house.rgb"],
                       "the road, its second surface and the barrier wall go; the house stays")
    }
}
