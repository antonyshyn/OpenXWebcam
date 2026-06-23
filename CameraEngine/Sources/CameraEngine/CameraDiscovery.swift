import Foundation
import CPTPTransport

public struct DiscoveredCamera {
    public static let fujiVendorID: UInt16 = 0x04CB

    public let info: PTPUSBInterfaceInfo

    public var isFuji: Bool {
        info.vendorID == Self.fujiVendorID
    }
}

public enum CameraDiscovery {
    public static func ptpCameras() -> [DiscoveredCamera] {
        PTPUSBTransport.findPTPInterfaces().map { DiscoveredCamera(info: $0) }
    }

    public static func firstFuji() -> DiscoveredCamera? {
        ptpCameras().first { $0.isFuji }
    }

    @discardableResult
    public static func killPtpcamerad() -> Int {
        Int(PTPUSBTransport.killProcessesNamed("ptpcamerad"))
    }
}
