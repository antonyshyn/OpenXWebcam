import Foundation

public enum FujiProp {
    public static let liveViewQuality: UInt16 = 0xD173
    public static let liveViewSize: UInt16 = 0xD174
    public static let priorityMode: UInt16 = 0xD207
    public static let currentState: UInt16 = 0xD212
    public static let forceMode: UInt16 = 0xD230
}

public enum FujiLiveViewSize: UInt16, CaseIterable, Sendable {
    case xga = 1
    case vga = 2
    case qvga = 3

    public var pixelSize: (width: Int, height: Int) {
        switch self {
        case .xga: return (1024, 768)
        case .vga: return (640, 480)
        case .qvga: return (320, 240)
        }
    }
}

public enum FujiLiveViewQuality: UInt16, CaseIterable, Sendable {
    case fine = 1
    case normal = 3
}

public enum FujiCameraError: Error {
    case notAFujiCamera
    case liveViewStartFailed(UInt16)
    case propertyWriteFailed(UInt16, rc: UInt16)
    case valueNotEncodable(UInt16)
}

public final class FujiCamera {
    public static let liveViewHandle: UInt32 = 0x8000_0001

    private let session: PTPSession
    private let busyRetries = 10
    private let busyRetryDelay: UInt32 = 300_000

    public init(session: PTPSession) {
        self.session = session
    }

    public func prepare(size: FujiLiveViewSize? = nil, quality: FujiLiveViewQuality? = nil) throws {
        let rc = try setPropRetryingBusy(FujiProp.priorityMode, 2)
        guard rc == PTPRC.ok else {
            throw FujiCameraError.propertyWriteFailed(FujiProp.priorityMode, rc: rc)
        }
        if let size {
            _ = try setPropRetryingBusy(FujiProp.liveViewSize, size.rawValue)
        }
        if let quality {
            _ = try setPropRetryingBusy(FujiProp.liveViewQuality, quality.rawValue)
        }
    }

    public func startLiveView() throws {
        var rc: UInt16 = 0
        for _ in 0..<(busyRetries * 2) {
            rc = try session.command(code: PTPOp.initiateOpenCapture, params: [0, 0]).responseCode
            if rc == PTPRC.ok { return }
            usleep(busyRetryDelay)
        }
        throw FujiCameraError.liveViewStartFailed(rc)
    }

    public func nextFrame() throws -> Data? {
        let info = try session.command(code: PTPOp.getObjectInfo, params: [Self.liveViewHandle])
        if info.responseCode == PTPRC.invalidObjectHandle { return nil }

        let object = try session.command(code: PTPOp.getObject, params: [Self.liveViewHandle])
        defer {
            _ = try? session.command(code: PTPOp.deleteObject, params: [Self.liveViewHandle, 0])
        }
        guard object.responseCode == PTPRC.ok,
              let jpeg = object.data,
              jpeg.count > 3, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8
        else { return nil }
        return jpeg
    }

    public func stopLiveView() throws {
        _ = try session.command(code: PTPOp.terminateOpenCapture)
        _ = try setPropRetryingBusy(FujiProp.priorityMode, 1)
    }

    public func readProperties(advertised: [UInt16]) -> [CameraProperty] {
        var result: [CameraProperty] = []
        for code in advertised {
            guard let (rc, desc) = try? session.propertyDescription(code),
                  rc == PTPRC.ok, let desc,
                  let property = FujiPropertyCatalog.property(from: desc)
            else { continue }
            result.append(property)
        }
        return result
    }

    public func setProperty(_ code: UInt16, to value: PTPPropValue, type: PTPDataType) throws -> UInt16 {
        guard let payload = value.encoded(as: type) else {
            throw FujiCameraError.valueNotEncodable(code)
        }
        var rc: UInt16 = 0
        for _ in 0..<busyRetries {
            rc = try session.setProp(code, payload: payload)
            if rc != PTPRC.deviceBusy { return rc }
            usleep(busyRetryDelay)
        }
        return rc
    }

    private func setPropRetryingBusy(_ property: UInt16, _ value: UInt16) throws -> UInt16 {
        var rc: UInt16 = 0
        for _ in 0..<busyRetries {
            rc = try session.setPropU16(property, value)
            if rc != PTPRC.deviceBusy { return rc }
            usleep(busyRetryDelay)
        }
        return rc
    }
}
