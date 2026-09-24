import Foundation

public enum FujiProp {
    public static let liveViewQuality: UInt16 = 0xD173
    public static let liveViewSize: UInt16 = 0xD174
    public static let releaseMode: UInt16 = 0xD201
    public static let priorityMode: UInt16 = 0xD207
    public static let currentState: UInt16 = 0xD212
    public static let forceMode: UInt16 = 0xD230
    /// Standard PTP focus mode; 1 means manual on Fuji bodies.
    public static let focusMode: UInt16 = 0x500A
    /// Writing a focus code here and pulsing InitiateCapture drives autofocus.
    public static let afTrigger: UInt16 = 0xD208
    /// 1 = focusing, 2 = locked, 3 = failed to lock.
    public static let afStatus: UInt16 = 0xD209
    /// 1 = off, 2 = on. Only writable before live view starts.
    public static let faceDetection: UInt16 = 0xD020
    /// Battery charge as a string, e.g. "49,0,0": body, then the two grip batteries.
    public static let batteryInfo: UInt16 = 0xD36B
    /// Action codes written to `afTrigger` then latched with InitiateCapture.
    public enum Action {
        /// Autofocus: hold, poll afStatus, then release with `afRelease`.
        public static let autofocus: UInt16 = 0x9300
        public static let afRelease: UInt16 = 0x0005
        /// Auto exposure lock: latch, and release with `aeUnlock`.
        public static let aeLock: UInt16 = 0x9000
        public static let aeUnlock: UInt16 = 0x0002
    }
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
    /// How long to wait for the live view delete to be acknowledged before moving on.
    private static let deleteAckTimeout: TimeInterval = 0.005
    /// How long to spend absorbing a late delete response.
    private static let deleteDrainTimeout: TimeInterval = 0.01
    /// How long to wait for a live view property write to be acknowledged.
    private static let propertyAckTimeout: TimeInterval = 0.005
    /// How long to spend absorbing a late property-write response.
    private static let propertyDrainTimeout: TimeInterval = 0.05
    /// Give up waiting for focus to settle after this long.
    private static let autofocusTimeout: TimeInterval = 3.0
    /// How long to wait for the camera to acknowledge an action write or latch.
    private static let actionAckTimeout: TimeInterval = 0.3
    /// Give up waiting for the exposure lock state to settle after this long.
    private static let exposureLockSettleTimeout: TimeInterval = 1.0

    public init(session: PTPSession) {
        self.session = session
    }

    public func prepare(size: FujiLiveViewSize? = nil, quality: FujiLiveViewQuality? = nil) throws {
        clearStaleCapture()
        let rc = try setPropRetryingBusy(FujiProp.priorityMode, 2)
        guard rc == PTPRC.ok else {
            throw FujiCameraError.propertyWriteFailed(FujiProp.priorityMode, rc: rc)
        }
        if let size {
            let rc = try setPropRetryingBusy(FujiProp.liveViewSize, size.rawValue)
            if rc != PTPRC.ok {
                EngineLog.add(String(format: "live view size write rc 0x%04X", rc))
            }
        }
        if let quality {
            writeLiveViewQuality(quality)
        }
        enableFaceDetection()
    }

    /// Turns on the camera's face detection, which is what makes autofocus aim at
    /// the subject rather than whatever happens to sit under the centre AF point.
    ///
    /// This must happen before live view starts - once a capture is open the camera
    /// answers DeviceBusy to this property and keeps doing so. Without it the
    /// autofocus trigger still reports a lock, it just locks on the background.
    private func enableFaceDetection() {
        if (try? session.getPropU16(FujiProp.faceDetection))?.value == 2 {
            return
        }
        guard let rc = try? setPropRetryingBusy(FujiProp.faceDetection, 2) else { return }
        if rc != PTPRC.ok {
            EngineLog.add(String(format: "face detection write rc 0x%04X", rc))
        }
    }

    /// Clears a live view session left running by a previous client.
    ///
    /// If an earlier run exited without calling TerminateOpenCapture - a crash, a
    /// SIGKILL, a yanked cable - the camera keeps the capture open and answers
    /// DeviceBusy (0x2019) to every subsequent property write, so setup fails and
    /// the app never recovers on its own. Tearing the old session down first costs
    /// one round trip and makes startup idempotent.
    private func clearStaleCapture() {
        _ = try? session.command(code: PTPOp.terminateOpenCapture)
        _ = try? setPropRetryingBusy(FujiProp.priorityMode, 1)
    }

    /// Applies live view quality without blocking on the acknowledgement.
    ///
    /// The X-T3 accepts this write but routinely never sends its response container.
    /// Waiting the full read timeout for one leaves the late reply to be picked up by
    /// the next command, which misaligns every transaction after it and wedges the
    /// camera until it is power cycled. Issuing the write and absorbing a late reply
    /// keeps the setting working on bodies that do answer, without stalling the ones
    /// that don't.
    private func writeLiveViewQuality(_ quality: FujiLiveViewQuality) {
        // Reads are acknowledged normally; this write isn't. Every unacknowledged
        // write leaves a late reply in the pipe, so don't send one on every reconnect
        // when the camera already has the value.
        if (try? session.getPropU16(FujiProp.liveViewQuality))?.value == quality.rawValue {
            return
        }
        do {
            let rc = try session.setPropU16(FujiProp.liveViewQuality, quality.rawValue,
                                            timeout: Self.propertyAckTimeout)
            if rc != PTPRC.ok {
                EngineLog.add(String(format: "live view quality write rc 0x%04X", rc))
            }
        } catch {
            session.drain(timeout: Self.propertyDrainTimeout)
            EngineLog.add("live view quality write not acknowledged, continuing")
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
        defer { releaseLiveViewFrame() }
        guard object.responseCode == PTPRC.ok,
              let jpeg = object.data,
              jpeg.count > 3, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8
        else { return nil }
        return jpeg
    }

    /// Releases the live view object so the camera renders the next frame.
    ///
    /// The delete cannot be skipped: it is what advances the live view buffer, and
    /// without it the camera keeps handing back the same JPEG forever. But some
    /// bodies (confirmed on the X-T3) routinely fail to answer it, and waiting for
    /// the response costs a full read timeout per frame - which is the difference
    /// between ~0 fps and ~30 fps. So issue it, give the camera a brief moment, and
    /// absorb a late reply rather than blocking on one.
    private func releaseLiveViewFrame() {
        do {
            _ = try session.command(code: PTPOp.deleteObject,
                                    params: [Self.liveViewHandle, 0],
                                    timeout: Self.deleteAckTimeout)
        } catch {
            session.drain(timeout: Self.deleteDrainTimeout)
        }
    }

    /// Fires a one-shot autofocus - the equivalent of half-pressing the shutter.
    ///
    /// Mirrors the sequence libgphoto2 uses for Fuji bodies: write a focus-start
    /// code to 0xD208, pulse InitiateCapture to assert the S1 (half-press) lock,
    /// poll AFStatus until it stops reporting "focusing", then release the lock the
    /// same way. The codes differ between manual and autofocus mode. Nothing is
    /// written to the card - this drives focus only.
    ///
    /// Must be called on the stream thread: it shares the PTP session with the
    /// frame loop, and two threads interleaving transactions desynchronises it.
    @discardableResult
    public func triggerAutofocus() -> Bool {
        let manual = (try? session.getPropU16(FujiProp.focusMode))?.value == 1
        let startCode: UInt16 = manual ? 0xA000 : FujiProp.Action.autofocus
        let stopCode: UInt16 = manual ? 0x0006 : FujiProp.Action.afRelease

        var locked = false
        var lastStatus: UInt16 = 0
        sendAction(startCode)
        // Poll until focus settles, even if the action went unacknowledged - it
        // usually still takes effect. A single unreadable status is not a failure
        // either: a late reply from an earlier command can swallow one.
        let deadline = Date(timeIntervalSinceNow: Self.autofocusTimeout)
        while Date() < deadline {
            if let status = (try? session.getPropU16(FujiProp.afStatus))?.value {
                lastStatus = status
                if status != 1 {
                    locked = (status == 2)
                    break
                }
            }
            usleep(30_000)
        }

        // Release the S1 lock whatever happened - leaving it asserted stops the
        // camera focusing again and can stall the next capture.
        sendAction(stopCode)
        EngineLog.add(String(format: "autofocus %@ (status %u, %@ mode)",
                             locked ? "locked" : "did not lock", lastStatus,
                             manual ? "manual" : "auto"))
        return locked
    }

    /// Writes an action code to 0xD208 and latches it with InitiateCapture.
    ///
    /// The camera doesn't always acknowledge either step - during a long stream,
    /// about every other autofocus went unanswered - and waiting the default five
    /// seconds for a reply froze the video for that long. The action still takes
    /// effect, so wait briefly for each acknowledgement and absorb a late one
    /// instead of blocking the frame loop on it.
    private func sendAction(_ code: UInt16) {
        var rc: UInt16 = PTPRC.deviceBusy
        for _ in 0..<busyRetries where rc == PTPRC.deviceBusy {
            do {
                rc = try session.setPropU16(FujiProp.afTrigger, code, timeout: Self.actionAckTimeout)
            } catch {
                session.drain(timeout: Self.propertyDrainTimeout)
                EngineLog.add(String(format: "action 0x%04X write not acknowledged", code))
                break
            }
            if rc == PTPRC.deviceBusy { usleep(busyRetryDelay) }
        }
        do {
            _ = try session.command(code: PTPOp.initiateCapture, params: [0, 0],
                                    timeout: Self.actionAckTimeout)
        } catch {
            session.drain(timeout: Self.propertyDrainTimeout)
            EngineLog.add(String(format: "action 0x%04X latch not acknowledged", code))
        }
    }

    /// Locks or releases auto exposure - the AE-L button Fujifilm's own X Webcam
    /// had, and the reason exposure otherwise drifts as the scene changes.
    ///
    /// Uses the same action channel as autofocus: write the code to 0xD208 and
    /// latch it with InitiateCapture. The camera reports the result in
    /// `currentState` (0xD212): 1 while metering normally, 0 while exposure is
    /// held. The code pair comes from traces of Fuji's own webcam software,
    /// recorded in libgphoto2's ptp2 driver.
    ///
    /// Must be called on the stream thread - it shares the PTP session with the
    /// frame loop.
    @discardableResult
    public func setAutoExposureLock(_ locked: Bool) -> Bool {
        let code = locked ? FujiProp.Action.aeLock : FujiProp.Action.aeUnlock
        sendAction(code)
        // The camera takes a moment to reflect the change, and the first read
        // after the latch often fails outright, so poll rather than trusting one
        // immediate read.
        let wantedState: UInt16 = locked ? 0 : 1
        var state: UInt16? = nil
        let deadline = Date(timeIntervalSinceNow: Self.exposureLockSettleTimeout)
        while Date() < deadline {
            if let value = (try? session.getPropU16(FujiProp.currentState))?.value {
                state = value
                if value == wantedState { break }
            }
            usleep(30_000)
        }
        let nowLocked = (state == 0)
        EngineLog.add("auto exposure \(nowLocked ? "locked" : "released") (state \(state.map(String.init) ?? "?"))")
        return nowLocked
    }

    /// Body battery charge in percent, or nil if the camera doesn't report it.
    ///
    /// Read from BatteryInfo2 (0xD36B), a string like "49,0,0": the body battery
    /// first, then the two batteries of the optional vertical grip, 0 when absent.
    /// The standard BatteryLevel (0x5001) is advertised by the X-T3 but not
    /// implemented. Readable during live view without disturbing it.
    public func batteryLevel() -> Int? {
        guard let result = try? session.command(code: PTPOp.getDevicePropValue,
                                                params: [UInt32(FujiProp.batteryInfo)]),
              result.responseCode == PTPRC.ok, let data = result.data else { return nil }
        var reader = PTPReader(data)
        guard let text = reader.string(),
              let first = text.split(separator: ",").first,
              let level = Int(first.trimmingCharacters(in: .whitespaces)),
              (0...100).contains(level)
        else { return nil }
        return level
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

    public func setProperty(_ code: UInt16, to value: PTPPropValue, type: PTPDataType, retries: Int? = nil) throws -> UInt16 {
        guard let payload = value.encoded(as: type) else {
            throw FujiCameraError.valueNotEncodable(code)
        }
        var rc: UInt16 = 0
        for _ in 0..<(retries ?? busyRetries) {
            rc = try session.setProp(code, payload: payload)
            if rc != PTPRC.deviceBusy { return rc }
            usleep(busyRetryDelay)
        }
        return rc
    }

    public func applyProperty(_ code: UInt16, to value: PTPPropValue, type: PTPDataType) throws -> UInt16 {
        var rc = try setProperty(code, to: value, type: type, retries: 2)
        if rc == PTPRC.deviceBusy {
            _ = try session.command(code: PTPOp.terminateOpenCapture)
            rc = try setProperty(code, to: value, type: type)
            try startLiveView()
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
