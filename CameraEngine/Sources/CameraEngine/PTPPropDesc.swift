import Foundation

public enum PTPDataType: UInt16, Sendable {
    case int8 = 0x0001
    case uint8 = 0x0002
    case int16 = 0x0003
    case uint16 = 0x0004
    case int32 = 0x0005
    case uint32 = 0x0006
    case int64 = 0x0007
    case uint64 = 0x0008
    case string = 0xFFFF
}

public enum PTPPropValue: Hashable, Sendable {
    case int(Int64)
    case uint(UInt64)
    case string(String)

    public var description: String {
        switch self {
        case .int(let v): return String(v)
        case .uint(let v): return String(v)
        case .string(let s): return "\"\(s)\""
        }
    }

    public func encoded(as type: PTPDataType) -> Data? {
        var data = Data()
        switch (type, self) {
        case (.int8, .int(let v)):
            data.append(UInt8(bitPattern: Int8(clamping: v)))
        case (.uint8, .uint(let v)):
            data.append(UInt8(clamping: v))
        case (.int16, .int(let v)):
            data.appendLE(UInt16(bitPattern: Int16(clamping: v)))
        case (.uint16, .uint(let v)):
            data.appendLE(UInt16(clamping: v))
        case (.int32, .int(let v)):
            data.appendLE(UInt32(bitPattern: Int32(clamping: v)))
        case (.uint32, .uint(let v)):
            data.appendLE(UInt32(clamping: v))
        case (.int64, .int(let v)):
            data.appendLE(UInt32(UInt64(bitPattern: v) & 0xFFFF_FFFF))
            data.appendLE(UInt32(UInt64(bitPattern: v) >> 32))
        case (.uint64, .uint(let v)):
            data.appendLE(UInt32(v & 0xFFFF_FFFF))
            data.appendLE(UInt32(v >> 32))
        default:
            return nil
        }
        return data
    }
}

public struct PTPPropDesc: Equatable {
    public enum Form: Equatable {
        case none
        case range(min: PTPPropValue, max: PTPPropValue, step: PTPPropValue)
        case enumeration([PTPPropValue])
    }

    public let code: UInt16
    public let dataType: PTPDataType
    public let isWritable: Bool
    public let defaultValue: PTPPropValue
    public let currentValue: PTPPropValue
    public let form: Form

    public init?(_ data: Data) {
        var reader = PTPReader(data)
        guard let code: UInt16 = reader.uint16(),
              let rawType: UInt16 = reader.uint16(),
              let type = PTPDataType(rawValue: rawType),
              let getSet = reader.uint8(),
              let defaultValue = reader.value(of: type),
              let currentValue = reader.value(of: type)
        else { return nil }

        self.code = code
        dataType = type
        isWritable = getSet == 1
        self.defaultValue = defaultValue
        self.currentValue = currentValue

        // Fuji firmware omits the trailing form flag on string props and
        // declares enum counts larger than the values it sends.
        let formFlag = reader.uint8() ?? 0
        switch formFlag {
        case 1:
            guard let min = reader.value(of: type),
                  let max = reader.value(of: type),
                  let step = reader.value(of: type)
            else { return nil }
            form = .range(min: min, max: max, step: step)
        case 2:
            guard let count: UInt16 = reader.uint16() else { return nil }
            var values: [PTPPropValue] = []
            for _ in 0..<count {
                guard let v = reader.value(of: type) else { break }
                values.append(v)
            }
            if values.isEmpty && count > 0 { return nil }
            form = .enumeration(values)
        default:
            form = .none
        }
    }
}

extension PTPReader {
    public mutating func value(of type: PTPDataType) -> PTPPropValue? {
        switch type {
        case .int8:
            return uint8().map { .int(Int64(Int8(bitPattern: $0))) }
        case .uint8:
            return uint8().map { .uint(UInt64($0)) }
        case .int16:
            return uint16().map { .int(Int64(Int16(bitPattern: $0))) }
        case .uint16:
            return uint16().map { .uint(UInt64($0)) }
        case .int32:
            return uint32().map { .int(Int64(Int32(bitPattern: $0))) }
        case .uint32:
            return uint32().map { .uint(UInt64($0)) }
        case .int64:
            return uint64().map { .int(Int64(bitPattern: $0)) }
        case .uint64:
            return uint64().map { .uint($0) }
        case .string:
            return string().map { .string($0) }
        }
    }

    public mutating func uint64() -> UInt64? {
        guard let low = uint32(), let high = uint32() else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }
}
