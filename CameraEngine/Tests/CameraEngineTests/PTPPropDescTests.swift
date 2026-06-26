import XCTest
@testable import CameraEngine

final class PTPPropDescTests: XCTestCase {
    func testUint16EnumDescriptor() {
        var data = Data()
        data.appendLE(UInt16(0xD207))
        data.appendLE(UInt16(0x0004))
        data.append(1)
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(2))
        data.append(2)
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        let desc = PTPPropDesc(data)
        XCTAssertEqual(desc?.code, 0xD207)
        XCTAssertEqual(desc?.dataType, .uint16)
        XCTAssertEqual(desc?.isWritable, true)
        XCTAssertEqual(desc?.defaultValue, .uint(2))
        XCTAssertEqual(desc?.currentValue, .uint(2))
        XCTAssertEqual(desc?.form, .enumeration([.uint(1), .uint(2)]))
    }

    func testInt16RangeDescriptor() {
        var data = Data()
        data.appendLE(UInt16(0x5010))
        data.appendLE(UInt16(0x0003))
        data.append(0)
        data.appendLE(UInt16(UInt16(bitPattern: 0)))
        data.appendLE(UInt16(UInt16(bitPattern: -1000)))
        data.append(1)
        data.appendLE(UInt16(UInt16(bitPattern: -3000)))
        data.appendLE(UInt16(3000))
        data.appendLE(UInt16(500))

        let desc = PTPPropDesc(data)
        XCTAssertEqual(desc?.dataType, .int16)
        XCTAssertEqual(desc?.isWritable, false)
        XCTAssertEqual(desc?.currentValue, .int(-1000))
        XCTAssertEqual(desc?.form, .range(min: .int(-3000), max: .int(3000), step: .int(500)))
    }

    func testStringDescriptor() {
        var data = Data()
        data.appendLE(UInt16(0xD20B))
        data.appendLE(UInt16(0xFFFF))
        data.append(1)
        let name = "X-T30"
        let chars = Array(name.utf16) + [0]
        for part in [chars, chars] {
            data.append(UInt8(part.count))
            for c in part { data.appendLE(c) }
        }
        data.append(0)

        let desc = PTPPropDesc(data)
        XCTAssertEqual(desc?.dataType, .string)
        XCTAssertEqual(desc?.currentValue, .string("X-T30"))
        XCTAssertEqual(desc?.form, PTPPropDesc.Form.none)
    }

    private func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").compactMap { UInt8($0, radix: 16) })
    }

    func testXT30QualityEnumDeclaresThreeSendsTwo() {
        let desc = PTPPropDesc(bytes("73 D1 04 00 01 01 00 03 00 02 03 00 01 00 03 00"))
        XCTAssertEqual(desc?.code, 0xD173)
        XCTAssertEqual(desc?.currentValue, .uint(3))
        XCTAssertEqual(desc?.form, .enumeration([.uint(1), .uint(3)]))
    }

    func testXT30StringWithoutFormFlag() {
        let desc = PTPPropDesc(bytes("6B D3 FF FF 00 06 30 00 2C 00 30 00 2C 00 30 00 00 00 06 31 00 2C 00 30 00 2C 00 30 00 00 00"))
        XCTAssertEqual(desc?.code, 0xD36B)
        XCTAssertEqual(desc?.isWritable, false)
        XCTAssertEqual(desc?.currentValue, .string("1,0,0"))
        XCTAssertEqual(desc?.form, PTPPropDesc.Form.none)
    }

    func testXT30CurrentStateHasNoRealDescriptor() {
        XCTAssertNil(PTPPropDesc(bytes("12 D2 00 00 00")))
    }

    func testTruncatedReturnsNil() {
        var data = Data()
        data.appendLE(UInt16(0xD207))
        data.appendLE(UInt16(0x0004))
        XCTAssertNil(PTPPropDesc(data))
    }

    func testUnknownDataTypeReturnsNil() {
        var data = Data()
        data.appendLE(UInt16(0xD212))
        data.appendLE(UInt16(0x4002))
        data.append(0)
        XCTAssertNil(PTPPropDesc(data))
    }
}
