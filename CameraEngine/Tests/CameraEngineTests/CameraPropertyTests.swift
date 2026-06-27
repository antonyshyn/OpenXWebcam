import XCTest
@testable import CameraEngine

final class CameraPropertyTests: XCTestCase {
    func testFilmSimulationLabels() {
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0xD001, value: .uint(1)), "PROVIA/Standard")
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0xD001, value: .uint(11)), "Classic Chrome")
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0xD001, value: .uint(99)), "99")
    }

    func testWhiteBalanceLabels() {
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0x5005, value: .uint(2)), "Auto")
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0x5005, value: .uint(0x8006)), "Shade")
    }

    func testExposureCompensationLabel() {
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0x5010, value: .int(-667)), "-0.7 EV")
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0x5010, value: .int(1000)), "+1.0 EV")
        XCTAssertEqual(FujiPropertyCatalog.label(code: 0x5010, value: .int(0)), "+0.0 EV")
    }

    func testUnknownPropertyGetsHexName() {
        XCTAssertEqual(FujiPropertyCatalog.name(for: 0xD38C), "Property 0xD38C")
    }

    func testHiddenPropertyMakesNoMenuEntry() {
        var data = Data()
        data.appendLE(UInt16(0xD207))
        data.appendLE(UInt16(0x0004))
        data.append(1)
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(2))
        data.append(0)
        let desc = PTPPropDesc(data)
        XCTAssertNotNil(desc)
        XCTAssertNil(FujiPropertyCatalog.property(from: desc!))
    }

    func testEnumDescriptorMakesChoices() {
        var data = Data()
        data.appendLE(UInt16(0xD001))
        data.appendLE(UInt16(0x0004))
        data.append(1)
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(11))
        data.append(2)
        data.appendLE(UInt16(3))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(11))

        let property = FujiPropertyCatalog.property(from: PTPPropDesc(data)!)
        XCTAssertEqual(property?.name, "Film Simulation")
        XCTAssertEqual(property?.isWritable, true)
        XCTAssertEqual(property?.currentValue, .uint(11))
        XCTAssertEqual(property?.choices.map(\.label), ["PROVIA/Standard", "Velvia/Vivid", "Classic Chrome"])
        XCTAssertEqual(property?.choices.map(\.value), [.uint(1), .uint(2), .uint(11)])
    }

    func testValueEncoding() {
        XCTAssertEqual(PTPPropValue.uint(2).encoded(as: .uint16), Data([0x02, 0x00]))
        XCTAssertEqual(PTPPropValue.int(-1000).encoded(as: .int16), Data([0x18, 0xFC]))
        XCTAssertEqual(PTPPropValue.uint(0x12345678).encoded(as: .uint32), Data([0x78, 0x56, 0x34, 0x12]))
        XCTAssertNil(PTPPropValue.string("x").encoded(as: .uint16))
        XCTAssertNil(PTPPropValue.uint(1).encoded(as: .int16))
    }
}
