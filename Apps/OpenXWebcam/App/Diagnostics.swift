import Foundation
import CameraEngine

enum Diagnostics {
    static func report(statusLine: String, extensionLine: String,
                       deviceInfo: PTPDeviceInfo?, properties: [CameraProperty]) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = [
            "OpenXWebcam \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            statusLine,
            extensionLine,
        ]
        if let info = deviceInfo {
            lines.append("")
            lines.append("camera: \(info.manufacturer) \(info.model) \(info.deviceVersion)")
            lines.append("operations: \(hexList(info.operations))")
            lines.append("properties: \(hexList(info.deviceProperties))")
        }
        if !properties.isEmpty {
            lines.append("")
            for property in properties {
                lines.append("\(property.name): \(property.currentLabel)")
            }
        }
        let log = EngineLog.dump()
        if !log.isEmpty {
            lines.append("")
            lines.append("log:")
            lines.append(contentsOf: log.suffix(100))
        }
        return lines.joined(separator: "\n")
    }

    private static func hexList(_ codes: [UInt16]) -> String {
        codes.map { String(format: "0x%04X", $0) }.joined(separator: " ")
    }
}
