import Foundation
import CPTPTransport

public enum PTPOp {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let deleteObject: UInt16 = 0x100B
    public static let getDevicePropDesc: UInt16 = 0x1014
    public static let getDevicePropValue: UInt16 = 0x1015
    public static let setDevicePropValue: UInt16 = 0x1016
    public static let terminateOpenCapture: UInt16 = 0x1018
    public static let initiateOpenCapture: UInt16 = 0x101C
}

public enum PTPRC {
    public static let ok: UInt16 = 0x2001
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let accessDenied: UInt16 = 0x200F
    public static let deviceBusy: UInt16 = 0x2019
    public static let sessionAlreadyOpen: UInt16 = 0x201E
}

public enum PTPSessionError: Error {
    case shortRead
    case unexpectedContainer(UInt16)
    case malformedResponse
}

public struct PTPCommandResult {
    public let responseCode: UInt16
    public let responseParams: [UInt32]
    public let data: Data?
}

public final class PTPSession {
    private let transport: PTPUSBTransport
    private var transactionID: UInt32 = 0
    private var replyPending = false
    private var discarded = 0
    private let readTimeout: TimeInterval = 5

    public init(transport: PTPUSBTransport) {
        self.transport = transport
    }

    public func open(sessionID: UInt32 = 1) throws -> UInt16 {
        var rc = try bareCommand(code: PTPOp.openSession, params: [sessionID])
        if rc == PTPRC.sessionAlreadyOpen {
            _ = try bareCommand(code: PTPOp.closeSession, params: [])
            rc = try bareCommand(code: PTPOp.openSession, params: [sessionID])
        }
        transactionID = 0
        return rc
    }

    public func close() throws -> UInt16 {
        try bareCommand(code: PTPOp.closeSession, params: [])
    }

    private func bareCommand(code: UInt16, params: [UInt32]) throws -> UInt16 {
        drainLateReply()
        let cmd = PTP.container(type: .command, code: code, transactionID: 0, params: params)
        try write(cmd)
        replyPending = true
        let response = try read(readTimeout)
        replyPending = false
        guard response.count >= PTP.headerLength else { throw PTPSessionError.shortRead }
        return response.readLE(at: 6)
    }

    public func command(code: UInt16, params: [UInt32] = [], dataOut: Data? = nil, timeout: TimeInterval? = nil) throws -> PTPCommandResult {
        let timeout = timeout ?? readTimeout
        drainLateReply()
        transactionID += 1
        let cmd = PTP.container(type: .command, code: code, transactionID: transactionID, params: params)
        try write(cmd)

        if let dataOut {
            let dataContainer = PTP.container(type: .data, code: code, transactionID: transactionID, payload: dataOut)
            try write(dataContainer)
        }

        replyPending = true
        var first = try readContainer(timeout)
        guard let header = PTPContainerHeader(first) else {
            throw PTPSessionError.malformedResponse
        }

        var dataIn: Data? = nil
        if header.type == .data {
            let declared = Int(header.length)
            var acc = first
            while acc.count < declared {
                let more = try read(timeout)
                if more.isEmpty { break }
                acc.append(more)
            }
            let dataEnd = min(acc.count, declared)
            dataIn = dataEnd > PTP.headerLength ? acc.subdata(in: (acc.startIndex + PTP.headerLength)..<(acc.startIndex + dataEnd)) : Data()
            if acc.count > declared {
                first = acc.subdata(in: (acc.startIndex + declared)..<acc.endIndex)
            } else {
                first = try readContainer(timeout)
            }
        }
        replyPending = false

        guard let response = PTPResponse(first) else {
            if let h = PTPContainerHeader(first) { throw PTPSessionError.unexpectedContainer(h.type.rawValue) }
            throw PTPSessionError.malformedResponse
        }
        return PTPCommandResult(responseCode: response.code, responseParams: response.params, data: dataIn)
    }

    public func deviceInfo() throws -> PTPDeviceInfo? {
        let result = try command(code: PTPOp.getDeviceInfo)
        guard result.responseCode == PTPRC.ok, let data = result.data else { return nil }
        return PTPDeviceInfo(data)
    }

    public func propertyDescription(_ property: UInt16) throws -> (rc: UInt16, desc: PTPPropDesc?) {
        let result = try command(code: PTPOp.getDevicePropDesc, params: [UInt32(property)])
        guard result.responseCode == PTPRC.ok, let data = result.data else {
            return (result.responseCode, nil)
        }
        return (result.responseCode, PTPPropDesc(data))
    }

    public func getPropU16(_ property: UInt16) throws -> (rc: UInt16, value: UInt16?) {
        let result = try command(code: PTPOp.getDevicePropValue, params: [UInt32(property)])
        guard result.responseCode == PTPRC.ok, let data = result.data, data.count >= 2 else {
            return (result.responseCode, nil)
        }
        return (result.responseCode, data.readLE(at: 0))
    }

    public func setPropU16(_ property: UInt16, _ value: UInt16) throws -> UInt16 {
        var payload = Data()
        payload.appendLE(value)
        return try setProp(property, payload: payload)
    }

    public func setProp(_ property: UInt16, payload: Data) throws -> UInt16 {
        let result = try command(code: PTPOp.setDevicePropValue, params: [UInt32(property)], dataOut: payload)
        return result.responseCode
    }

    private func write(_ data: Data) throws {
        try transport.write(data)
    }

    private func read(_ timeout: TimeInterval) throws -> Data {
        try transport.read(withTimeout: timeout)
    }

    private func readContainer(_ timeout: TimeInterval) throws -> Data {
        for _ in 0..<8 {
            let data = try read(timeout)
            if PTPContainerHeader(data)?.transactionID == transactionID {
                return data
            }
            discard(data)
        }
        throw PTPSessionError.malformedResponse
    }

    private func drainLateReply() {
        guard replyPending else { return }
        replyPending = false
        while let data = try? read(0.02) {
            discard(data)
        }
    }

    private func discard(_ data: Data) {
        guard !data.isEmpty else { return }
        discarded += 1
        if discarded & (discarded - 1) == 0 {
            let from = PTPContainerHeader(data).map { " from transaction \($0.transactionID)" } ?? ""
            EngineLog.add("discarded \(data.count) bytes\(from), current transaction \(transactionID) (\(discarded) so far)")
        }
    }
}
