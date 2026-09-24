import Foundation
import os
import CPTPTransport

public enum CameraState: Equatable {
    case stopped
    case waitingForCamera
    case connecting
    case streaming(model: String)
    case cameraError(String)
}

public enum CameraManagerError: Error {
    case sessionOpenFailed(UInt16)
}

public final class CameraManager {
    public var onState: ((CameraState) -> Void)?
    public var onFrame: ((Data) -> Void)?
    public var onFPS: ((Double) -> Void)?
    public var onProperties: (([CameraProperty]) -> Void)?
    /// Reports whether a requested autofocus locked. Called on the main queue.
    public var onAutofocusResult: ((Bool) -> Void)?
    /// Reports the auto exposure lock state after a change. Called on the main queue.
    public var onExposureLockChanged: ((Bool) -> Void)?
    /// Reports the body battery in percent, on connect and then every 30 seconds.
    /// Called on the main queue.
    public var onBattery: ((Int) -> Void)?

    public private(set) var liveViewSize: FujiLiveViewSize
    public private(set) var liveViewQuality: FujiLiveViewQuality

    private let controlQueue = DispatchQueue(label: "com.openxwebcam.camera-manager")
    private let watcher = PTPUSBWatcher()
    private var running = false

    private var streamThread: Thread?
    private var activeRegistryID: UInt64 = 0
    private var deviceGone = false
    private var lockedProps: Set<UInt16> = []
    private let stopStreamFlag = OSAllocatedUnfairLock(initialState: false)
    private let latestDeviceInfo = OSAllocatedUnfairLock<PTPDeviceInfo?>(initialState: nil)
    private let pendingWrites = OSAllocatedUnfairLock<[PropertyWrite]>(initialState: [])
    private let autofocusRequested = OSAllocatedUnfairLock(initialState: false)
    private let exposureLockRequest = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    /// When the current session started delivering frames.
    private let streamingSince = OSAllocatedUnfairLock<Date?>(initialState: nil)
    /// A session that streamed at least this long before failing counts as healthy,
    /// and refills the retry budget rather than drawing it down.
    private static let healthySessionDuration: TimeInterval = 30
    /// How often to read the battery. It changes slowly, and each read is one more
    /// transaction sharing the session with the frame loop.
    private static let batteryPollInterval: TimeInterval = 30

    private struct PropertyWrite: Sendable {
        let code: UInt16
        let value: PTPPropValue
        let type: PTPDataType
    }

    public init(size: FujiLiveViewSize = .xga, quality: FujiLiveViewQuality = .normal) {
        liveViewSize = size
        liveViewQuality = quality
        watcher.onAttach = { [weak self] info in
            self?.cameraAttached(info)
        }
        watcher.onDetach = { [weak self] registryID in
            self?.cameraDetached(registryID)
        }
    }

    public func start() {
        controlQueue.async {
            guard !self.running else { return }
            self.running = true
            self.setState(.waitingForCamera)
            _ = self.watcher.start(on: self.controlQueue)
        }
    }

    public func stop() {
        controlQueue.async {
            guard self.running else { return }
            self.running = false
            self.watcher.stop()
            self.requestStreamStop()
            if self.streamThread == nil {
                self.setState(.stopped)
            }
        }
    }

    /// Stops live view and hands control back to the camera body.
    ///
    /// Live view runs with the camera in USB priority (0xD207 = 2), where the host
    /// owns the session and the body's own power switch is subordinate to it. A
    /// clean stop restores camera priority, but a crash or a force quit does not,
    /// and the camera then stays powered until its battery is pulled. This restores
    /// it without one. `completion` is called on the main queue.
    public func releaseCamera(completion: @escaping (Bool) -> Void) {
        stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The stream thread can be inside a 5 second read when this is pressed.
            // Taking the camera before it lets go means two connections fighting
            // over one interface, so wait long enough for it to finish.
            self?.waitUntilIdle(timeout: 8)
            let restored = Self.handControlBackToCamera()
            DispatchQueue.main.async { completion(restored) }
        }
    }

    private static func handControlBackToCamera() -> Bool {
        guard let camera = CameraDiscovery.firstFuji() else {
            EngineLog.add("release: no camera found")
            return false
        }
        CameraDiscovery.killPtpcamerad()
        let transport = PTPUSBTransport(service: camera.info.service)
        do {
            try transport.openSeizing()
        } catch {
            EngineLog.add("release: \(error.localizedDescription)")
            return false
        }
        defer { transport.close() }

        let session = PTPSession(transport: transport)
        session.clearPipe()
        guard let rc = try? session.open(), rc == PTPRC.ok else {
            EngineLog.add("release: camera is not answering - switch it off and on; if its screen stays lit, remove the battery")
            return false
        }
        try? FujiCamera(session: session).stopLiveView()
        let restored = (try? session.getPropU16(FujiProp.priorityMode))?.value == 1
        _ = try? session.close()
        EngineLog.add(restored ? "release: control returned to camera"
                               : "release: priority mode not restored")
        return restored
    }

    /// Queues a one-shot autofocus.
    ///
    /// The camera shares one PTP session with the frame loop, so this only sets a
    /// flag; the stream thread performs the focus between frames. Requesting again
    /// while one is pending is a no-op rather than a queue, so holding the button
    /// down cannot flood the camera.
    public func requestAutofocus() {
        autofocusRequested.withLock { $0 = true }
    }

    /// Queues an auto exposure lock change, applied by the stream thread.
    public func setAutoExposureLock(_ locked: Bool) {
        exposureLockRequest.withLock { $0 = locked }
    }

    public func apply(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        controlQueue.async {
            self.liveViewSize = size
            self.liveViewQuality = quality
            self.requestStreamStop()
        }
    }

    public var deviceInfo: PTPDeviceInfo? {
        latestDeviceInfo.withLock { $0 }
    }

    public func waitUntilIdle(timeout: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if controlQueue.sync(execute: { streamThread == nil }) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    public func set(property: CameraProperty, to value: PTPPropValue) {
        pendingWrites.withLock {
            $0.append(PropertyWrite(code: property.code, value: value, type: property.dataType))
        }
    }

    private var streamStopRequested: Bool {
        stopStreamFlag.withLock { $0 }
    }

    private func requestStreamStop() {
        stopStreamFlag.withLock { $0 = true }
    }

    private func cameraAttached(_ info: PTPUSBInterfaceInfo) {
        guard running, streamThread == nil, info.vendorID == DiscoveredCamera.fujiVendorID else { return }
        startStream(with: info)
    }

    private func cameraDetached(_ registryID: UInt64) {
        guard registryID == activeRegistryID else { return }
        activeRegistryID = 0
        deviceGone = true
        requestStreamStop()
    }

    private func startStream(with info: PTPUSBInterfaceInfo) {
        stopStreamFlag.withLock { $0 = false }
        pendingWrites.withLock { $0.removeAll() }
        deviceGone = false
        activeRegistryID = info.registryID
        setState(.connecting)
        let thread = Thread { [weak self] in
            self?.streamLoop(info: info)
        }
        thread.name = "camera-stream"
        thread.qualityOfService = .userInteractive
        streamThread = thread
        thread.start()
    }

    private func streamLoop(info: PTPUSBInterfaceInfo) {
        let size = liveViewSize
        let quality = liveViewQuality
        // Waits of 1, 2, 4, 4, 4 seconds: a camera that has just been cancelled out of
        // a stuck transfer needs a moment before it takes new commands.
        var retry = RetryPolicy(maxAttempts: 5, baseDelay: 1.0, maxDelay: 4.0)
        var lastError: String?

        while !streamStopRequested {
            do {
                try streamOnce(info: info, size: size, quality: quality)
                lastError = nil
                break
            } catch {
                lastError = describe(error)
                EngineLog.add("stream error: \(lastError ?? "")")
                // Glitches minutes apart are not a failing camera. Without this, five of
                // them spread over an afternoon ended the stream for good.
                if let since = streamingSince.withLock({ $0 }),
                   -since.timeIntervalSinceNow >= Self.healthySessionDuration {
                    retry.reset()
                }
                guard !streamStopRequested, let delay = retry.nextDelay() else { break }
                CameraDiscovery.killPtpcamerad()
                Thread.sleep(forTimeInterval: delay)
            }
        }

        onProperties?([])
        controlQueue.async {
            self.streamThread = nil
            self.activeRegistryID = 0
            if !self.running {
                self.setState(.stopped)
            } else if self.deviceGone {
                self.deviceGone = false
                self.setState(.waitingForCamera)
            } else if let lastError {
                self.setState(.cameraError(lastError))
            } else if let camera = CameraDiscovery.firstFuji() {
                self.startStream(with: camera.info)
            } else {
                self.setState(.waitingForCamera)
            }
        }
    }

    private func streamOnce(info: PTPUSBInterfaceInfo, size: FujiLiveViewSize, quality: FujiLiveViewQuality) throws {
        streamingSince.withLock { $0 = nil }
        CameraDiscovery.killPtpcamerad()
        let transport = PTPUSBTransport(service: info.service)
        try transport.openSeizing()
        defer { transport.close() }

        let session = PTPSession(transport: transport)
        // A previous session may have failed with the camera mid-transfer. Get it out
        // of that before sending anything, or the first command simply times out.
        session.clearPipe()
        do {
            try runSession(session, size: size, quality: quality)
        } catch {
            // Empty the pipe while the connection is still open, so nothing the camera
            // was still sending is cut off by the close.
            session.clearPipe()
            throw error
        }
    }

    private func runSession(_ session: PTPSession, size: FujiLiveViewSize, quality: FujiLiveViewQuality) throws {
        let rc = try session.open()
        guard rc == PTPRC.ok else {
            throw CameraManagerError.sessionOpenFailed(rc)
        }
        let info = try session.deviceInfo()
        latestDeviceInfo.withLock { $0 = info }
        let model = info?.model ?? "camera"
        let advertised = info?.deviceProperties ?? []
        let fuji = FujiCamera(session: session)
        try fuji.prepare(size: size, quality: quality)
        try fuji.startLiveView()
        setState(.streaming(model: model))
        streamingSince.withLock { $0 = Date() }
        lockedProps = []
        publishProperties(from: fuji, advertised: advertised)

        var frames = 0
        var windowStart = Date()
        autofocusRequested.withLock { $0 = false }
        exposureLockRequest.withLock { $0 = nil }
        var nextBatteryRead = Date()
        var lastBattery: Int? = nil
        while !streamStopRequested {
            // This is a bare Thread, so nothing drains its autorelease pool on its own:
            // every object the transport and the frame consumer autorelease would live
            // until the thread ends. Drain once per frame instead.
            let delivered = try autoreleasepool { () throws -> Bool in
                applyPendingWrites(to: fuji, advertised: advertised)
                if autofocusRequested.withLock({ pending -> Bool in
                    defer { pending = false }
                    return pending
                }) {
                    let locked = fuji.triggerAutofocus()
                    DispatchQueue.main.async { [onAutofocusResult] in onAutofocusResult?(locked) }
                }
                if let wanted = exposureLockRequest.withLock({ pending -> Bool? in
                    defer { pending = nil }
                    return pending
                }) {
                    let locked = fuji.setAutoExposureLock(wanted)
                    DispatchQueue.main.async { [onExposureLockChanged] in onExposureLockChanged?(locked) }
                }
                if Date() >= nextBatteryRead {
                    nextBatteryRead = Date(timeIntervalSinceNow: Self.batteryPollInterval)
                    if let level = fuji.batteryLevel() {
                        if level != lastBattery {
                            EngineLog.add("battery \(level)%")
                            lastBattery = level
                        }
                        DispatchQueue.main.async { [onBattery] in onBattery?(level) }
                    }
                }
                guard let jpeg = try fuji.nextFrame() else { return false }
                onFrame?(jpeg)
                return true
            }
            guard delivered else {
                usleep(5000)
                continue
            }
            frames += 1
            let elapsed = -windowStart.timeIntervalSinceNow
            if elapsed >= 2 {
                onFPS?(Double(frames) / elapsed)
                frames = 0
                windowStart = Date()
            }
        }
        try? fuji.stopLiveView()
        _ = try? session.close()
    }

    private func applyPendingWrites(to fuji: FujiCamera, advertised: [UInt16]) {
        let writes = pendingWrites.withLock { pending in
            defer { pending.removeAll() }
            return pending
        }
        guard !writes.isEmpty else { return }
        for write in writes {
            do {
                let rc = try fuji.applyProperty(write.code, to: write.value, type: write.type)
                EngineLog.add(String(format: "set 0x%04X = %@, rc 0x%04X", write.code, write.value.description, rc))
            } catch {
                EngineLog.add(String(format: "set 0x%04X failed: %@", write.code, String(describing: error)))
            }
        }
        let properties = fuji.readProperties(advertised: advertised)
        for write in writes {
            guard let property = properties.first(where: { $0.code == write.code }),
                  property.currentValue != write.value
            else { continue }
            lockedProps.insert(write.code)
            EngineLog.add(String(format: "0x%04X kept its old value, treating as read-only", write.code))
        }
        publish(properties)
    }

    private func publishProperties(from fuji: FujiCamera, advertised: [UInt16]) {
        publish(fuji.readProperties(advertised: advertised))
    }

    private func publish(_ properties: [CameraProperty]) {
        onProperties?(properties.map { lockedProps.contains($0.code) ? $0.asReadOnly() : $0 })
    }

    private func describe(_ error: Error) -> String {
        if case CameraManagerError.sessionOpenFailed(let rc) = error {
            return String(format: "Session open failed (0x%04X)", rc)
        }
        if let fujiError = error as? FujiCameraError {
            switch fujiError {
            case .notAFujiCamera:
                return "Connected camera is not a Fujifilm"
            case .liveViewStartFailed(let rc):
                return String(format: "Live view refused (0x%04X). Check the camera's USB mode.", rc)
            case .propertyWriteFailed(let prop, let rc):
                return String(format: "Camera setup failed (prop 0x%04X, rc 0x%04X)", prop, rc)
            case .valueNotEncodable(let prop):
                return String(format: "Unsupported value for prop 0x%04X", prop)
            }
        }
        return (error as NSError).localizedDescription
    }

    private func setState(_ state: CameraState) {
        EngineLog.add("state: \(state)")
        onState?(state)
    }
}
