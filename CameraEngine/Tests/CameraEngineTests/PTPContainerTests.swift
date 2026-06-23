import XCTest
@testable import CameraEngine

final class PTPContainerTests: XCTestCase {
    func testCommandContainerLayout() {
        let data = PTP.container(type: .command, code: 0x101C, transactionID: 5, params: [0, 0])
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(Array(data.prefix(4)), [20, 0, 0, 0])
        XCTAssertEqual(Array(data[4..<6]), [0x01, 0x00])
        XCTAssertEqual(Array(data[6..<8]), [0x1C, 0x10])
        XCTAssertEqual(Array(data[8..<12]), [5, 0, 0, 0])
        XCTAssertEqual(Array(data[12..<20]), [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testDataContainerWithPayload() {
        let payload = Data([0x02, 0x00])
        let data = PTP.container(type: .data, code: 0x1016, transactionID: 3, payload: payload)
        XCTAssertEqual(data.count, 14)
        XCTAssertEqual(Array(data.prefix(4)), [14, 0, 0, 0])
        XCTAssertEqual(Array(data[4..<6]), [0x02, 0x00])
        XCTAssertEqual(Array(data.suffix(2)), [0x02, 0x00])
    }

    func testHeaderParsing() {
        var raw = Data()
        raw.appendLE(UInt32(16))
        raw.appendLE(PTPContainerType.response.rawValue)
        raw.appendLE(UInt16(0x2001))
        raw.appendLE(UInt32(7))
        raw.appendLE(UInt32(42))

        let header = PTPContainerHeader(raw)
        XCTAssertEqual(header?.length, 16)
        XCTAssertEqual(header?.type, .response)
        XCTAssertEqual(header?.code, 0x2001)
        XCTAssertEqual(header?.transactionID, 7)
    }

    func testResponseParams() {
        var raw = Data()
        raw.appendLE(UInt32(20))
        raw.appendLE(PTPContainerType.response.rawValue)
        raw.appendLE(UInt16(0x2019))
        raw.appendLE(UInt32(1))
        raw.appendLE(UInt32(0xAABBCCDD))
        raw.appendLE(UInt32(0x11223344))

        let response = PTPResponse(raw)
        XCTAssertEqual(response?.code, 0x2019)
        XCTAssertEqual(response?.params, [0xAABBCCDD, 0x11223344])
    }

    func testResponseRejectsNonResponseContainer() {
        let data = PTP.container(type: .data, code: 0x1001, transactionID: 1)
        XCTAssertNil(PTPResponse(data))
    }

    func testHeaderParsingOnSlicedData() {
        var raw = Data([0xFF, 0xFF])
        raw.append(PTP.container(type: .response, code: 0x2001, transactionID: 1))
        let slice = raw.dropFirst(2)
        let header = PTPContainerHeader(slice)
        XCTAssertEqual(header?.code, 0x2001)
    }

    func testShortDataReturnsNil() {
        XCTAssertNil(PTPContainerHeader(Data([1, 2, 3])))
    }
}
