import Foundation

public enum PTPContainerType: UInt16 {
    case command = 1
    case data = 2
    case response = 3
}

public enum PTP {
    public static let headerLength = 12

    public static func container(type: PTPContainerType, code: UInt16, transactionID: UInt32,
                                 params: [UInt32] = [], payload: Data = Data()) -> Data {
        var out = Data(capacity: headerLength + params.count * 4 + payload.count)
        out.appendLE(UInt32(headerLength + params.count * 4 + payload.count))
        out.appendLE(type.rawValue)
        out.appendLE(code)
        out.appendLE(transactionID)
        for p in params { out.appendLE(p) }
        out.append(payload)
        return out
    }
}

public struct PTPContainerHeader {
    public let length: UInt32
    public let type: PTPContainerType
    public let code: UInt16
    public let transactionID: UInt32

    public init?(_ data: Data) {
        guard data.count >= PTP.headerLength else { return nil }
        length = data.readLE(at: 0)
        guard let t = PTPContainerType(rawValue: data.readLE(at: 4) as UInt16) else { return nil }
        type = t
        code = data.readLE(at: 6)
        transactionID = data.readLE(at: 8)
    }
}

public struct PTPResponse {
    public let code: UInt16
    public let params: [UInt32]

    public init?(_ data: Data) {
        guard let header = PTPContainerHeader(data), header.type == .response else { return nil }
        code = header.code
        var params: [UInt32] = []
        var offset = PTP.headerLength
        while offset + 4 <= data.count && params.count < 5 {
            params.append(data.readLE(at: offset))
            offset += 4
        }
        self.params = params
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func readLE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func readLE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8) | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
}
