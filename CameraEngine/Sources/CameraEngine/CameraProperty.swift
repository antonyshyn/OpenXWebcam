import Foundation

public struct CameraProperty: Equatable, Identifiable, Sendable {
    public struct Choice: Equatable, Sendable {
        public let value: PTPPropValue
        public let label: String
    }

    public let code: UInt16
    public let name: String
    public let dataType: PTPDataType
    public let isWritable: Bool
    public let currentValue: PTPPropValue
    public let choices: [Choice]

    public var id: UInt16 { code }

    public var currentLabel: String {
        FujiPropertyCatalog.label(code: code, value: currentValue)
    }

    public func asReadOnly() -> CameraProperty {
        CameraProperty(code: code, name: name, dataType: dataType,
                       isWritable: false, currentValue: currentValue, choices: choices)
    }
}

public enum FujiPropertyCatalog {
    static let names: [UInt16: String] = [
        0x5005: "White Balance",
        0x500F: "ISO",
        0x5010: "Exposure Compensation",
        0xD001: "Film Simulation",
        0xD017: "Color Temperature",
        0xD02A: "ISO",
        0xD02B: "Movie ISO",
        0xD173: "Live View Quality",
        0xD174: "Live View Size",
        0xD207: "USB Priority",
        0xD36A: "Battery",
    ]

    static let hidden: Set<UInt16> = [
        FujiProp.liveViewQuality,
        FujiProp.liveViewSize,
        FujiProp.releaseMode,
        FujiProp.priorityMode,
        FujiProp.currentState,
        FujiProp.forceMode,
    ]

    static let filmSimulations: [UInt64: String] = [
        1: "PROVIA/Standard",
        2: "Velvia/Vivid",
        3: "ASTIA/Soft",
        4: "PRO Neg. Hi",
        5: "PRO Neg. Std",
        6: "Black & White",
        7: "Black & White + Ye Filter",
        8: "Black & White + R Filter",
        9: "Black & White + G Filter",
        10: "Sepia",
        11: "Classic Chrome",
        12: "ACROS",
        13: "ACROS + Ye Filter",
        14: "ACROS + R Filter",
        15: "ACROS + G Filter",
        16: "ETERNA/Cinema",
        17: "Classic Neg",
        18: "ETERNA Bleach Bypass",
    ]

    static let whiteBalances: [UInt64: String] = [
        1: "Manual",
        2: "Auto",
        4: "Daylight",
        6: "Incandescent",
        0x8001: "Fluorescent 1",
        0x8002: "Fluorescent 2",
        0x8003: "Fluorescent 3",
        0x8004: "Fluorescent 4",
        0x8005: "Fluorescent 5",
        0x8006: "Shade",
        0x8007: "Color Temperature",
        0x8008: "Custom 1",
        0x8009: "Custom 2",
        0x800A: "Custom 3",
        0x800B: "Custom 4",
        0x800C: "Custom 5",
    ]

    public static func name(for code: UInt16) -> String {
        names[code] ?? String(format: "Property 0x%04X", code)
    }

    public static func isKnown(_ code: UInt16) -> Bool {
        names[code] != nil
    }

    public static func label(code: UInt16, value: PTPPropValue) -> String {
        switch code {
        case 0xD001:
            if case .uint(let v) = value, let name = filmSimulations[v] { return name }
        case 0x5005:
            if case .uint(let v) = value, let name = whiteBalances[v] { return name }
        case 0x5010:
            if case .int(let v) = value {
                return String(format: "%+.1f EV", Double(v) / 1000)
            }
        case 0xD207:
            if case .uint(let v) = value { return v == 2 ? "USB" : "Camera" }
        default:
            break
        }
        return value.description
    }

    public static func property(from desc: PTPPropDesc) -> CameraProperty? {
        if hidden.contains(desc.code) { return nil }
        var choices: [CameraProperty.Choice] = []
        if case .enumeration(let values) = desc.form {
            choices = values.map {
                CameraProperty.Choice(value: $0, label: label(code: desc.code, value: $0))
            }
        }
        return CameraProperty(code: desc.code,
                              name: name(for: desc.code),
                              dataType: desc.dataType,
                              isWritable: desc.isWritable,
                              currentValue: desc.currentValue,
                              choices: choices)
    }
}
