import Foundation

public struct PTPDeviceInfo {
    public let standardVersion: UInt16
    public let vendorExtensionID: UInt32
    public let vendorExtensionVersion: UInt16
    public let vendorExtensionDesc: String
    public let functionalMode: UInt16
    public let operations: [UInt16]
    public let events: [UInt16]
    public let deviceProperties: [UInt16]
    public let captureFormats: [UInt16]
    public let imageFormats: [UInt16]
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    public init?(_ data: Data) {
        var reader = PTPReader(data)
        guard let std: UInt16 = reader.uint16(),
              let vext: UInt32 = reader.uint32(),
              let vver: UInt16 = reader.uint16(),
              let vdesc = reader.string(),
              let fmode: UInt16 = reader.uint16(),
              let ops = reader.uint16Array(),
              let events = reader.uint16Array(),
              let props = reader.uint16Array(),
              let capFormats = reader.uint16Array(),
              let imgFormats = reader.uint16Array(),
              let manufacturer = reader.string(),
              let model = reader.string(),
              let deviceVersion = reader.string()
        else { return nil }

        standardVersion = std
        vendorExtensionID = vext
        vendorExtensionVersion = vver
        vendorExtensionDesc = vdesc
        functionalMode = fmode
        operations = ops
        self.events = events
        deviceProperties = props
        captureFormats = capFormats
        imageFormats = imgFormats
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        serialNumber = reader.string() ?? ""
    }

    public func supportsOperation(_ code: UInt16) -> Bool {
        operations.contains(code)
    }

    public func advertisesProperty(_ code: UInt16) -> Bool {
        deviceProperties.contains(code)
    }
}

public struct PTPReader {
    private let data: Data
    private var offset = 0

    public init(_ data: Data) {
        self.data = data
    }

    private mutating func take(_ count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + count)
        offset += count
        return data.subdata(in: range)
    }

    public mutating func uint8() -> UInt8? {
        take(1)?.first
    }

    public mutating func uint16() -> UInt16? {
        take(2).map { $0.readLE(at: 0) }
    }

    public mutating func uint32() -> UInt32? {
        take(4).map { $0.readLE(at: 0) }
    }

    public mutating func string() -> String? {
        guard let charCount = uint8() else { return nil }
        if charCount == 0 { return "" }
        guard let bytes = take(Int(charCount) * 2) else { return nil }
        let s = String(data: bytes, encoding: .utf16LittleEndian) ?? ""
        return s.trimmingCharacters(in: .controlCharacters)
    }

    public mutating func uint16Array() -> [UInt16]? {
        guard let count = uint32() else { return nil }
        var result: [UInt16] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let v: UInt16 = uint16() else { return nil }
            result.append(v)
        }
        return result
    }
}
