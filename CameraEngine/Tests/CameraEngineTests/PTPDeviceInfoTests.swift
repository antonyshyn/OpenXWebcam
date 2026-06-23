import XCTest
@testable import CameraEngine

final class PTPDeviceInfoTests: XCTestCase {
    private func ptpString(_ s: String) -> Data {
        var out = Data()
        if s.isEmpty {
            out.append(0)
            return out
        }
        let chars = Array(s.utf16) + [0]
        out.append(UInt8(chars.count))
        for c in chars {
            out.appendLE(c)
        }
        return out
    }

    private func uint16Array(_ values: [UInt16]) -> Data {
        var out = Data()
        out.appendLE(UInt32(values.count))
        for v in values {
            out.appendLE(v)
        }
        return out
    }

    private func makeDeviceInfo() -> Data {
        var out = Data()
        out.appendLE(UInt16(100))
        out.appendLE(UInt32(6))
        out.appendLE(UInt16(100))
        out.append(ptpString("fujifilm.co.jp: 1.0; "))
        out.appendLE(UInt16(0))
        out.append(uint16Array([0x1001, 0x1002, 0x1016, 0x101C]))
        out.append(uint16Array([0x4002, 0xC006]))
        out.append(uint16Array([0xD173, 0xD174, 0xD207]))
        out.append(uint16Array([0x3801]))
        out.append(uint16Array([0x3801]))
        out.append(ptpString("FUJIFILM"))
        out.append(ptpString("X-T30"))
        out.append(ptpString("2.01"))
        out.append(ptpString("ABC123"))
        return out
    }

    func testParsesXT30ShapedDeviceInfo() {
        let info = PTPDeviceInfo(makeDeviceInfo())
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.standardVersion, 100)
        XCTAssertEqual(info?.vendorExtensionID, 6)
        XCTAssertEqual(info?.vendorExtensionDesc, "fujifilm.co.jp: 1.0; ")
        XCTAssertEqual(info?.operations, [0x1001, 0x1002, 0x1016, 0x101C])
        XCTAssertEqual(info?.events, [0x4002, 0xC006])
        XCTAssertEqual(info?.deviceProperties, [0xD173, 0xD174, 0xD207])
        XCTAssertEqual(info?.manufacturer, "FUJIFILM")
        XCTAssertEqual(info?.model, "X-T30")
        XCTAssertEqual(info?.deviceVersion, "2.01")
        XCTAssertEqual(info?.serialNumber, "ABC123")
    }

    func testSupportChecks() {
        let info = PTPDeviceInfo(makeDeviceInfo())
        XCTAssertEqual(info?.supportsOperation(0x101C), true)
        XCTAssertEqual(info?.supportsOperation(0x902B), false)
        XCTAssertEqual(info?.advertisesProperty(0xD207), true)
        XCTAssertEqual(info?.advertisesProperty(0xD38C), false)
    }

    func testMissingSerialIsEmpty() {
        var data = makeDeviceInfo()
        data.removeLast(ptpString("ABC123").count)
        let info = PTPDeviceInfo(data)
        XCTAssertEqual(info?.serialNumber, "")
    }

    func testTruncatedDataReturnsNil() {
        let data = makeDeviceInfo()
        XCTAssertNil(PTPDeviceInfo(data.prefix(10)))
        XCTAssertNil(PTPDeviceInfo(Data()))
    }

    func testParsesFromSlice() {
        var padded = Data([0x00, 0x00, 0x00])
        padded.append(makeDeviceInfo())
        let info = PTPDeviceInfo(padded.dropFirst(3))
        XCTAssertEqual(info?.model, "X-T30")
    }
}
