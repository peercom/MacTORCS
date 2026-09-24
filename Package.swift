// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-2.0-only
import PackageDescription

let package = Package(
    name: "TORCSMac", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "torcs-assetc", targets: ["TORCSAssetCompiler"]),
        .executable(name: "TORCSMac", targets: ["TORCSMac"]),
        .executable(name: "torcs-reference", targets: ["TORCSReference"]),
        .executable(name: "torcs-sim", targets: ["TORCSSim"]),
        .executable(name: "torcs-diff", targets: ["TORCSDiff"]),
        .executable(name: "torcs-rendershot", targets: ["TORCSRenderShot"]),
        .executable(name: "torcs-matgen", targets: ["TORCSMaterialGenerator"])
    ],
    targets: [
        .target(name: "TORCSAssets", path: "Packages/TORCSAssets"),
        .target(name: "TORCSCore", path: "Packages/TORCSCore"),
        .target(name: "TORCSMath", path: "Packages/TORCSMath"),
        .target(name: "TORCSConfiguration", path: "Packages/TORCSConfiguration"),
        .target(name: "TORCSTrack", dependencies: ["TORCSConfiguration"], path: "Packages/TORCSTrack"),
        .target(name: "TORCSSimulation", dependencies: ["TORCSCore", "TORCSConfiguration", "TORCSTrack"], path: "Packages/TORCSSimulation"),
        .target(name: "TORCSRobots", dependencies: ["TORCSSimulation", "TORCSConfiguration", "TORCSTrack"], path: "Packages/TORCSRobots"),
        .target(name: "TORCSInput", dependencies: ["TORCSCore", "TORCSSimulation"], path: "Packages/TORCSInput"),
        .target(name: "TORCSRaceEngine", dependencies: ["TORCSRobots", "TORCSCore", "TORCSTelemetry", "TORCSSimulation", "TORCSTrack", "TORCSConfiguration", "TORCSAssets"], path: "Packages/TORCSRaceEngine"),
        .target(name: "TORCSTelemetry", dependencies: ["TORCSSimulation", "TORCSTrack"], path: "Packages/TORCSTelemetry"),
        .target(name: "TORCSMaterials", dependencies: ["TORCSMath", "TORCSAssets"], path: "Packages/TORCSMaterials"),
        .target(name: "TORCSTrackMesh", dependencies: ["TORCSTrack", "TORCSMath", "TORCSConfiguration"], path: "Packages/TORCSTrackMesh"),
        .target(name: "TORCSRender", dependencies: ["TORCSCore", "TORCSMath", "TORCSAssets", "TORCSTrack", "TORCSTrackMesh", "TORCSMaterials", "TORCSSimulation", "TORCSRaceEngine"], path: "Packages/TORCSRender", resources: [.copy("Shaders")]),
        .target(name: "TORCSMetal", dependencies: ["TORCSCore", "TORCSSimulation", "TORCSAssets", "TORCSTrack", "TORCSRaceEngine"], path: "Packages/TORCSMetal", resources: [.copy("Scene.metal")]),
        .target(name: "PNGReference", path: "Upstream/PNGReference", exclude: ["LICENSE"], publicHeadersPath: "include", cSettings: [.define("PNG_ARM_NEON_OPT", to: "0"), .unsafeFlags(["-ffp-contract=off"])], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CReference", dependencies: ["PNGReference"], path: "Upstream/Reference",
                sources: ["susp.cpp", "brake.cpp", "steer.cpp", "bridge.cpp", "platform.cpp", "world.cpp",
                          "simulation-instrumentation.cpp", "race-instrumentation.cpp", "asset-instrumentation.cpp", "texture-instrumentation.cpp", "png-instrumentation.cpp", "graphics-instrumentation.cpp", "carlight-instrumentation.cpp", "height-instrumentation.cpp", "draw-order-instrumentation.cpp", "alpha-state-instrumentation.cpp", "input-instrumentation.cpp", "convex-instrumentation.cpp", "car.cpp", "aero.cpp", "engine.cpp", "axle.cpp", "wheel.cpp",
                          "robots/bt", "transmission.cpp", "differential.cpp", "collision-instrumentation.cpp", "categories.cpp", "atmosphere.cpp",
                          "params.cpp", "hash.cpp", "rttrack.cpp", "track", "solid", "plib"],
                publicHeadersPath: "include",
                cxxSettings: [.headerSearchPath("assets/shims"), .headerSearchPath("race/shims"), .headerSearchPath("private"), .headerSearchPath("private/plib"),
                             .define("HAVE_STRNDUP"), .define("NDEBUG"),
                             .unsafeFlags(["-ffp-contract=off"])], linkerSettings: [.linkedLibrary("expat"), .linkedLibrary("z")]),
        .target(name: "TORCSReferenceSupport", dependencies: ["CReference", "TORCSTelemetry", "TORCSTrack"], path: "Tools/TORCSReferenceSupport"),
        .executableTarget(name: "TORCSReference", dependencies: ["CReference", "TORCSTelemetry", "TORCSReferenceSupport"], path: "Tools/torcs-reference"),
        .executableTarget(name: "TORCSSim", dependencies: ["TORCSRaceEngine", "TORCSSimulation", "TORCSTelemetry", "TORCSConfiguration", "TORCSTrack"], path: "Tools/torcs-sim"),
        .executableTarget(name: "TORCSAssetCompiler", dependencies: ["TORCSAssets"], path: "Tools/torcs-assetc"),
        .executableTarget(name: "TORCSDiff", dependencies: ["TORCSTelemetry"], path: "Tools/torcs-diff"),
        .executableTarget(name: "TORCSMaterialGenerator", dependencies: ["TORCSMaterials"], path: "Tools/torcs-matgen"),
        .executableTarget(name: "TORCSRenderShot", dependencies: ["TORCSRender", "TORCSAssets"], path: "Tools/torcs-rendershot"),
        .executableTarget(name: "TORCSMac", dependencies: ["TORCSCore", "TORCSSimulation", "TORCSMetal", "TORCSRender", "TORCSTrackMesh", "TORCSConfiguration", "TORCSTrack", "TORCSAssets", "TORCSRaceEngine", "TORCSTelemetry", "TORCSInput"], path: "App"),
        .testTarget(name: "UnitTests", dependencies: ["TORCSRobots", "TORCSCore", "TORCSMath", "TORCSConfiguration", "TORCSSimulation", "TORCSTelemetry", "CReference", "TORCSReferenceSupport", "TORCSTrack", "TORCSRaceEngine", "TORCSAssets", "TORCSMetal", "TORCSRender", "TORCSTrackMesh", "TORCSMaterials", "TORCSInput"], path: "Tests/UnitTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "PhysicsGoldenTests", dependencies: ["TORCSSimulation", "TORCSTelemetry", "CReference"], path: "Tests/PhysicsGoldenTests", resources: [.copy("Fixtures")])
    ], cxxLanguageStandard: .cxx17
)
