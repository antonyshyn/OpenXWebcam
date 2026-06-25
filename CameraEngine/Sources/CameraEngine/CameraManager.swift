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

    public private(set) var liveViewSize: FujiLiveViewSize
    public private(set) var liveViewQuality: FujiLiveViewQuality

    private let controlQueue = DispatchQueue(label: "com.openxwebcam.camera-manager")
    private let watcher = PTPUSBWatcher()
    private var running = false

    private var streamThread: Thread?
    private var activeRegistryID: UInt64 = 0
    private let stopStreamFlag = OSAllocatedUnfairLock(initialState: false)

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

    public func apply(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        controlQueue.async {
            self.liveViewSize = size
            self.liveViewQuality = quality
            self.requestStreamStop()
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
        requestStreamStop()
    }

    private func startStream(with info: PTPUSBInterfaceInfo) {
        stopStreamFlag.withLock { $0 = false }
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
        var retry = RetryPolicy()
        var lastError: String?

        while !streamStopRequested {
            do {
                try streamOnce(info: info, size: size, quality: quality)
                lastError = nil
                break
            } catch {
                lastError = describe(error)
                guard !streamStopRequested, let delay = retry.nextDelay() else { break }
                CameraDiscovery.killPtpcamerad()
                Thread.sleep(forTimeInterval: delay)
            }
        }

        controlQueue.async {
            self.streamThread = nil
            self.activeRegistryID = 0
            if !self.running {
                self.setState(.stopped)
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
        CameraDiscovery.killPtpcamerad()
        let transport = PTPUSBTransport(service: info.service)
        try transport.openSeizing()
        defer { transport.close() }

        let session = PTPSession(transport: transport)
        let rc = try session.open()
        guard rc == PTPRC.ok else {
            throw CameraManagerError.sessionOpenFailed(rc)
        }
        let model = try session.deviceInfo()?.model ?? "camera"
        let fuji = FujiCamera(session: session)
        try fuji.prepare(size: size, quality: quality)
        try fuji.startLiveView()
        setState(.streaming(model: model))

        var frames = 0
        var windowStart = Date()
        while !streamStopRequested {
            guard let jpeg = try fuji.nextFrame() else {
                usleep(5000)
                continue
            }
            onFrame?(jpeg)
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
            }
        }
        return (error as NSError).localizedDescription
    }

    private func setState(_ state: CameraState) {
        onState?(state)
    }
}
