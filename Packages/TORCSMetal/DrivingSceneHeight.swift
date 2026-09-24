// SPDX-License-Identifier: GPL-2.0-only
// Selected-scene port of TORCS grLoadScene/grInitCar/grDrawCar ordering.
// Copyright (C) 2000 Eric Espie; original GPL-2.0-or-later attribution retained.
import simd
import TORCSAssets
import TORCSSimulation
import TORCSRaceEngine

/// Height graph for the native single-car slice: landscape, projected shadow,
/// body/driver, four modeled wheels and optional generated brake parts. Other LODs and effects are not
/// present in this slice. Keeps original transform stages and selector bounds.
public struct DrivingSceneHeight: Sendable {
    private var graph: SceneHeightAssembly
    private let bodyTransform,bodySelector,bodyAsset,shadowAsset: Int
    private let wheelPosition,wheelRotation,wheelSelector: [Int]
    private let wheelSizes: [SIMD3<Float>]
    private let lightDefinitions: [CarLightDefinition]
    private let lightResource: Int
    public init(scenes: [ACScene],snapshot: VehicleVisualSnapshot,shadowVertices: [ShadowVertex],brakeScenes: [ACScene]=[],lights:[CarLightDefinition]=[]) throws {
        guard scenes.count==6 else { throw ACError.invalid("Driving height needs body, four wheel resources and track") }
        guard brakeScenes.isEmpty || brakeScenes.count==12 else { throw ACError.invalid("Height scene needs all twelve brake parts") }
        var resources=try scenes.enumerated().map { try SceneHeightQuery($0.element,driverSelector:$0.offset==0) }
        resources.append(try SceneHeightQuery(shadowVertices:shadowVertices))
        resources += try brakeScenes.map { try SceneHeightQuery($0) }
        lightDefinitions=lights;lightResource=resources.count
        resources.append(try SceneHeightQuery(lightPositions:[]))
        var nodes: [SceneHeightAssembly.Node]=[]
        func add(_ parent: Int,_ kind: SceneHeightAssembly.Kind) -> Int { nodes.append(.init(parent:parent,kind:kind));return nodes.count-1 }
        let root=add(-1,.branch)
        // Original anchor order; unsupported anchors remain empty.
        let anchors=(0..<8).map { _ in add(root,.branch) }
        _=add(anchors[0],.asset(5))
        let shadowAnchor=add(anchors[3],.branch);shadowAsset=add(shadowAnchor,.asset(6))
        _=add(anchors[4],.asset(lightResource))
        bodyTransform=add(anchors[5],.transform(matrix_identity_float4x4))
        bodySelector=add(bodyTransform,.selector(1));let body=add(bodySelector,.branch)
        bodyAsset=add(body,.asset(0))
        var positions: [Int]=[],rotations: [Int]=[],selectors: [Int]=[]
        for i in 0..<4 {
            let w=snapshot.wheels[i]
            let position=add(body,.transform(matrix_identity_float4x4))
            if !brakeScenes.isEmpty { for part in 0..<3 { _=add(position,.asset(7+i*3+part)) } }
            let rotation=add(position,.transform(matrix_identity_float4x4))
            let selector=add(rotation,.selector(1));positions.append(position);rotations.append(rotation);selectors.append(selector)
            for level in 0..<4 {
                var parent=add(selector,.branch)
                if i%2==0 { parent=add(parent,.transform(VehiclePresentation.matrix(CollisionTransform(position:.zero,orientation:SIMD3(0,0,Float.pi))))) }
                parent=add(parent,.transform(simd_float4x4(diagonal:SIMD4(w.radius*2,w.width,w.radius*2,1))))
                _=add(parent,.asset(level+1))
            }
        }
        wheelPosition=positions;wheelRotation=rotations;wheelSelector=selectors
        wheelSizes=(0..<4).map { SIMD3(snapshot.wheels[$0].radius,snapshot.wheels[$0].width,snapshot.wheels[$0].brakeRadius) }
        graph=try SceneHeightAssembly(nodes:nodes,resources:resources)
        try update(snapshot:snapshot,drawsCar:true,drawsDriver:true,shadowVertices:shadowVertices)
    }
    var referenceShadowSphere: SIMD4<Float> { graph.referenceSpheres[shadowAsset] }
    public func query(_ point: SIMD2<Float>) throws -> SceneHeightQuery.Result { try graph.query(x:point.x,y:point.y) }
    /// Called after camera update. Failed publication preserves the previous draw.
    public mutating func update(snapshot: VehicleVisualSnapshot,drawsCar: Bool,drawsDriver: Bool,shadowVertices: [ShadowVertex]) throws {
        let pose=try VehiclePresentation(snapshot)
        guard (0..<4).allSatisfy({ wheelSizes[$0]==SIMD3(snapshot.wheels[$0].radius,snapshot.wheels[$0].width,snapshot.wheels[$0].brakeRadius) }) else { throw ACError.invalid("Rebuild height scene when wheel configuration changes") }
        var next=graph
        try next.setTransform(pose.body,at:bodyTransform)
        try next.setSelection(drawsCar ? 1:0,at:bodySelector)
        if drawsCar { try next.setDriverVisible(drawsDriver,at:bodyAsset) }
        for i in 0..<4 {
            let w=snapshot.wheels[i],a=w.pose.orientation
            try next.setTransform(VehiclePresentation.matrix(CollisionTransform(position:w.pose.position,orientation:SIMD3(a.x,0,a.z))),at:wheelPosition[i])
            try next.setTransform(VehiclePresentation.matrix(CollisionTransform(position:.zero,orientation:SIMD3(0,a.y,0))),at:wheelRotation[i])
            try next.setSelection(UInt32(1)<<pose.wheels[i].level,at:wheelSelector[i])
        }
        // grDrawShadow removes the old leaf and adds a new one only if visible.
        // A selector would incorrectly retain hidden-shadow bounds.
        try next.replaceResource(6,with:SceneHeightQuery(shadowVertices:drawsCar ? shadowVertices:[]))
        let lights=try CarLightInstance.instances(definitions:lightDefinitions,body:pose.body,brakeCommand:snapshot.brakeCommand,lightCommand:snapshot.lightCommand,display:drawsCar)
        try next.replaceResource(lightResource,with:SceneHeightQuery(lightPositions:lights.map(\.position)))
        graph=next
    }
}

/// Owns F10 state and the preceding draw's query scene. Picker changes preserve
/// motion/RNG state, as original selectCamera does. No simulation state is owned.
public struct DrivingFlyCamera: Sendable {
    private(set) var motion: FlyCamera
    private(set) var height: DrivingSceneHeight
    private let vegetation:VegetationForest?
    public init(height: DrivingSceneHeight,seed: UInt32=12345,vegetation:VegetationForest?=nil) throws { self.height=height;self.vegetation=vegetation;motion=try FlyCamera(seed:seed) }
    /// Equal simulation timestamps hold motion even when redraws publish geometry.
    /// A nil view means the caller retains the preceding valid camera.
    public mutating func draw(time: Double,selected: Bool,snapshot: VehicleVisualSnapshot,drawsCar: Bool,drawsDriver: Bool,shadowVertices: [ShadowVertex],zoom: Float=67.5,enhancedVegetation:Bool=false) throws -> SceneCamera? {
        var nextMotion=motion
        if selected { try nextMotion.update(time:time,carIndex:0,position:snapshot.body.position) { point in
            let original=try height.query(point).height
            return enhancedVegetation ? max(original,vegetation?.height(at:point) ?? -1_000_000):original
        } }
        let camera=selected ? try nextMotion.camera(zoom:zoom):nil
        try height.update(snapshot:snapshot,drawsCar:drawsCar,drawsDriver:drawsDriver,shadowVertices:shadowVertices)
        motion=nextMotion;return camera
    }
}
