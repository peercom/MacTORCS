// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSConfiguration
import TORCSRaceEngine
import TORCSSimulation
@testable import TORCSMetal

final class CarLightTests:XCTestCase {
    private func floats<T>(_ v:T)->[Float] { withUnsafeBytes(of:v) { Array($0.bindMemory(to:Float.self)) } }
    private func xml(_ body:String)->String { "<?xml version=\"1.0\"?><params name=\"lights\"><section name=\"Graphic Objects\"><section name=\"Light\">\(body)</section></section></params>" }
    func testConfigurationAgainstOriginalNumberedLookup() throws {
        var fixtures=[xml("")]
        for (i,type) in ["head1","head2","rear","brake","brake2","rear2","reverse","","BRAKE","unknown"].enumerated() {
            fixtures.append(xml("<section name=\"1\"><attstr name=\"type\" val=\"\(type)\"/><attnum name=\"xpos\" val=\"\(i).125\"/><attnum name=\"ypos\" val=\"-0.7\"/><attnum name=\"size\" val=\"-0.15\"/></section>"))
        }
        // Original counts children but looks up names 1...count, even with gaps,
        // nonnumeric names and reordered entries. Missing numbered entries default.
        fixtures += [xml("<section name=\"3\"><attstr name=\"type\" val=\"brake\"/></section><section name=\"1\"><attnum name=\"size\" val=\"0\"/></section>"),xml("<section name=\"arbitrary\"/>"),xml((1...14).reversed().map { "<section name=\"\($0)\"><attstr name=\"type\" val=\"brake2\"/><attnum name=\"size\" val=\"0.25\"/></section>" }.joined())]
        let car=try String(contentsOf:Bundle.module.url(forResource:"155-DTM",withExtension:"xml",subdirectory:"Fixtures")!,encoding:.utf8)
        // Original fixture declares an external DTD, which the test adapter
        // deliberately rejects. Parsing this local fixture needs no DTD contents.
        let sanitized=car.replacingOccurrences(of:"<!DOCTYPE[^>]*>",with:"",options:.regularExpression)
        fixtures.append(sanitized)
        var entries=0
        for fixture in fixtures {
            let native=try CarLightDefinition.load(ParameterDocument.parse(Data(fixture.utf8)))
            var reference=Array(repeating:RefCarLightConfig(),count:14)
            let count=fixture.withCString { ref_carlight_config_xml($0,&reference,14) };XCTAssertEqual(count,Int32(native.count))
            for i in native.indices {
                XCTAssertEqual(native[i].type.rawValue,Int(reference[i].type));XCTAssertEqual(native[i].size,reference[i].size)
                XCTAssertEqual([native[i].position.x,native[i].position.y,native[i].position.z],floats(reference[i].position));entries += 1
            }
        }
        let selected=try CarLightDefinition.load(ParameterDocument.parse(Data(sanitized.utf8)))
        XCTAssertEqual(selected.count,2);XCTAssertTrue(selected.allSatisfy { $0.type == .brake2 && $0.type.textureName == "breaklight2.rgb" })
        XCTAssertThrowsError(try CarLightDefinition.load(ParameterDocument.parse(Data(xml((1...15).map { "<section name=\"\($0)\"/>" }.joined()).utf8))))
        print("CAR_LIGHT_CONFIG fixtures=\(fixtures.count) entries=\(entries) maximum=0 numberedDefaults=1 overflowRejected=1")
    }
    func testOriginalEnablementAndWorldPosition() throws {
        var maximum:Float=0,cases=0
        for type in CarLightType.allCases { for brake:Float in [-1,-0.0,0,.leastNonzeroMagnitude,0.2,1,.infinity,-.infinity,.nan] { for command:UInt32 in [0,1,2,3,4,0x80000001,0xffffffff] { for visible in [false,true] {
            let definition=try CarLightDefinition(type:type,position:SIMD3(-2.18,0.68,0.68),size:0.15)
            let body=VehiclePresentation.matrix(CollisionTransform(position:SIMD3(Float(cases%17)*1.13,-45.6,1.2),orientation:SIMD3(0.13,-0.24,Float(cases)*0.031)))
            let native=try CarLightInstance.instances(definitions:[definition],body:body,brakeCommand:brake,lightCommand:command,display:visible)
            var state=[Int32](repeating:0,count:2),world=[Float](repeating:0,count:3)
            ref_carlight_update(Int32(type.rawValue),brake,command,visible ? 1:0,[definition.position.x,definition.position.y,definition.position.z],definition.size,floats(body),&state,&world)
            XCTAssertEqual(native.count,Int(state[0]))
            if let instance=native.first {
                XCTAssertEqual(instance.isOn,state[1] != 0)
                for axis in 0..<3 { maximum=max(maximum,abs(instance.position[axis]-world[axis]));XCTAssertEqual(instance.position[axis],world[axis]) }
            }
            cases += 1
        } } } }
        print("CAR_LIGHT_UPDATE cases=\(cases) worldMaximum=\(maximum) enablementAndHiddenChildren=exact")
    }
    func testOriginalBillboardVerticesTextureRotationAndState() throws {
        var maximum:Float=0,matrixMaximum:Float=0,cases=0
        for i in 0..<2400 {
            let position=SIMD3(Float(i%21)*13.1-98.2,Float(i%17)*(-6.47),Float(i%11)*0.21)
            let size=Float(i%31-15)*0.037,factor=Double(i%17-8)*0.131
            let camera=SceneCamera(eye:SIMD3(Float(i%31)-10,Float(i%17)+2,Float(i%29)+1),target:SIMD3(-23,0.2,-1),up:SIMD3(0.1,0.2,1))
            let view=camera.view(),random=UInt32((UInt64(i)*1234567)%2147483648)
            let native=try CarLightGeometry(position:position,size:size,factor:factor,view:view,randomValue:random)
            var ref=RefCarLightDraw();ref_carlight_draw([position.x,position.y,position.z],size,factor,floats(view),random,1,&ref)
            let vertices=native.positions.flatMap { [$0.x,$0.y,$0.z] }
            for (a,b) in zip(vertices,floats(ref.vertices)) { maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b) }
            XCTAssertEqual(native.textureCoordinates.flatMap { [$0.x,$0.y] },floats(ref.uv));XCTAssertEqual(floats(native.color),floats(ref.color))
            for (a,b) in zip(floats(native.textureMatrix),floats(ref.textureMatrix)) { matrixMaximum=max(matrixMaximum,abs(a-b));XCTAssertEqual(a,b) }
            XCTAssertEqual(ref.count,4);XCTAssertEqual(ref.primitive,5);XCTAssertEqual(ref.randomDraws,1)
            XCTAssertEqual(ref.depthMaskCount,2);XCTAssertEqual(ref.depthMask.0,0);XCTAssertEqual(ref.depthMask.1,1)
            XCTAssertEqual(floats(ref.offset),[-15,-20]);XCTAssertEqual(ref.offsetEnabled,0);XCTAssertEqual(ref.finalMatrixMode,9)
            XCTAssertEqual(floats(ref.finalTextureMatrix),floats(matrix_identity_float4x4))
            XCTAssertFalse(native.depthWrites);XCTAssertFalse(native.cullsFaces)
            cases += 1
        }
        print("CAR_LIGHT_DRAW cases=\(cases) vertexScalars=\(cases*12) maximum=\(maximum) textureMatrixMaximum=\(matrixMaximum) colorUVDrawState=exact")
    }
    func testRandomEndpointsAndDisabledDraw() throws {
        for value:UInt32 in [0,1,2147483646,2147483647] {
            let native=try CarLightGeometry(position:.zero,size:0.2,view:matrix_identity_float4x4,randomValue:value)
            XCTAssertEqual(native.angleDegrees,Float(value)/Float(2147483647)*45)
            var ref=RefCarLightDraw();ref_carlight_draw([0,0,0],0.2,1,floats(matrix_identity_float4x4),value,0,&ref)
            XCTAssertEqual(ref.count,0);XCTAssertEqual(ref.randomDraws,0);XCTAssertEqual(ref.depthMaskCount,0)
        }
        XCTAssertThrowsError(try CarLightGeometry(position:.zero,size:0.2,view:matrix_identity_float4x4,randomValue:2147483648))
        for value:Float in [.nan,.infinity,-.infinity] {
            XCTAssertThrowsError(try CarLightDefinition(type:.brake,position:.zero,size:value))
            XCTAssertThrowsError(try CarLightGeometry(position:.zero,size:value,view:matrix_identity_float4x4,randomValue:0))
        }
        XCTAssertThrowsError(try CarLightGeometry(position:.zero,size:Float.greatestFiniteMagnitude,factor:Double.greatestFiniteMagnitude,view:matrix_identity_float4x4,randomValue:0))
        print("CAR_LIGHT_RANDOM endpoints=4 disabledDraws=0 invalidDrawInputRejected=1")
    }
    func testDrawRandomSequenceAndRollback() throws {
        let definition=try CarLightDefinition(type:.brake,position:SIMD3(-2,0,0.7),size:0.15)
        let on=try CarLightInstance(definition:definition,body:matrix_identity_float4x4,brakeCommand:1,lightCommand:0)
        let off=try CarLightInstance(definition:definition,body:matrix_identity_float4x4,brakeCommand:0,lightCommand:0)
        var compared=0
        for seed:UInt32 in [0,1,12345,2147483647] {
            var reference=[UInt32](repeating:0,count:2000);ref_carlight_random(seed,2000,&reference)
            var stream=try CarLightDrawing(seed:seed)
            for i in 0..<2000 {
                if i%3==0 { XCTAssertNil(try stream.draw(off,view:matrix_identity_float4x4)) }
                let geometry=try XCTUnwrap(stream.draw(on,view:matrix_identity_float4x4))
                XCTAssertEqual(geometry.angleDegrees,Float(reference[i])/Float(2147483647)*45)
                XCTAssertEqual(stream.randomDraws,UInt64(i+1));compared += 1
                if i%71==0 {
                    var invalid=matrix_identity_float4x4;invalid[0].x = .nan
                    XCTAssertThrowsError(try stream.draw(on,view:invalid));XCTAssertEqual(stream.randomDraws,UInt64(i+1))
                }
            }
        }
        XCTAssertThrowsError(try CarLightDrawing(seed:2147483648))
        print("CAR_LIGHT_RANDOM_SEQUENCE samples=\(compared) seeds=4 angleMaximum=0 disabledAndInvalidDrawsDoNotAdvance=1")
    }
    func testNativeCommandPublicationAndPhysicsIsolation() throws {
        let (content,definition)=try VehiclePresentationTests().setup();defer { withExtendedLifetime(content){} }
        let road=try ChassisTestContext.road()
        var withLights=try SingleVehicleSimulation(definition:definition,road:road),control=withLights
        try withLights.settle();try control.settle()
        var stream=try CarLightDrawing(),draws=0
        let definitionLight=try CarLightDefinition(type:.brake2,position:SIMD3(-2.18,0.68,0.68),size:0.15)
        for tick in 0..<2000 {
            let brake:Float=tick%200<100 ? 0:0.7
            let base=DriverCommand(throttle:brake==0 ? 0.4:0,brake:brake,steering:0.02,gear:1)
            var lit=base;lit.lightCommand=UInt32(tick%4)
            try withLights.step(command:lit);try control.step(command:base)
            let snapshot=withLights.visualSnapshot
            XCTAssertEqual(snapshot.brakeCommand,withLights.vehicle.driverCommand.brake)
            XCTAssertEqual(snapshot.lightCommand,lit.lightCommand)
            let pose=try VehiclePresentation(snapshot)
            let instances=try CarLightInstance.instances(definitions:[definitionLight],body:pose.body,brakeCommand:snapshot.brakeCommand,lightCommand:snapshot.lightCommand,display:tick%5 != 0)
            for instance in instances { if try stream.draw(instance,view:matrix_identity_float4x4) != nil { draws += 1 } }
            XCTAssertEqual(withLights.vehicle.chassis.body.position,control.vehicle.chassis.body.position)
            XCTAssertEqual(withLights.vehicle.chassis.body.velocity,control.vehicle.chassis.body.velocity)
            XCTAssertEqual(withLights.vehicle.engine.speed,control.vehicle.engine.speed)
            XCTAssertEqual(withLights.random.state,control.random.state);XCTAssertEqual(withLights.random.draws,control.random.draws)
        }
        XCTAssertGreaterThan(draws,0)
        print("CAR_LIGHT_PUBLICATION ticks=2000 presentationDraws=\(draws) bodyPositionVelocityEngineSpeedAndPhysicsRNGUnchanged=1")
    }

}
