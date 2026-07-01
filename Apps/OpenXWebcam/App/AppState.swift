import AppKit
import Combine
import ServiceManagement
import CameraEngine

@MainActor
final class AppState: ObservableObject {
    @Published var extensionStatus: ExtensionInstaller.Status = .unknown
    @Published var streamerState: CameraStreamer.State = .idle
    @Published var connectedCameraName: String?
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                EngineLog.add("launch at login: \(error.localizedDescription)")
            }
        }
    }
    @Published var mirrored: Bool {
        didSet {
            UserDefaults.standard.set(mirrored, forKey: "mirrored")
            streamer.setOrientation(mirrored: mirrored, rotation: rotation)
        }
    }
    @Published var rotation: Int {
        didSet {
            UserDefaults.standard.set(rotation, forKey: "rotation")
            streamer.setOrientation(mirrored: mirrored, rotation: rotation)
        }
    }
    @Published var liveViewSize: FujiLiveViewSize {
        didSet {
            UserDefaults.standard.set(Int(liveViewSize.rawValue), forKey: "liveViewSize")
            streamer.apply(size: liveViewSize, quality: liveViewQuality)
        }
    }
    @Published var liveViewQuality: FujiLiveViewQuality {
        didSet {
            UserDefaults.standard.set(Int(liveViewQuality.rawValue), forKey: "liveViewQuality")
            streamer.apply(size: liveViewSize, quality: liveViewQuality)
        }
    }
    @Published var cameraProperties: [CameraProperty] = []
    @Published var previewImage: CGImage?

    private let installer = ExtensionInstaller()
    private let streamer = CameraStreamer()
    private let presence = CameraPresence()
    private var connectedProductID: UInt16?

    init() {
        liveViewSize = FujiLiveViewSize(rawValue: UInt16(UserDefaults.standard.integer(forKey: "liveViewSize"))) ?? .xga
        liveViewQuality = FujiLiveViewQuality(rawValue: UInt16(UserDefaults.standard.integer(forKey: "liveViewQuality"))) ?? .normal
        launchAtLogin = SMAppService.mainApp.status == .enabled
        mirrored = UserDefaults.standard.bool(forKey: "mirrored")
        rotation = UserDefaults.standard.integer(forKey: "rotation")
        installer.onStatusChange = { [weak self] status in
            self?.extensionStatus = status
        }
        streamer.onStateChange = { [weak self] state in
            self?.streamerState = state
            if case .streaming(let model, _) = state {
                self?.rememberCameraName(model)
            } else {
                self?.previewImage = nil
            }
        }
        streamer.onPropertiesChange = { [weak self] properties in
            self?.cameraProperties = properties
        }
        streamer.onPreviewFrame = { [weak self] image in
            self?.previewImage = image
        }
        streamer.setOrientation(mirrored: mirrored, rotation: rotation)
        presence.onChange = { [weak self] productID in
            DispatchQueue.main.async {
                self?.connectedProductID = productID
                self?.connectedCameraName = productID.map {
                    UserDefaults.standard.string(forKey: Self.cameraNameKey($0)) ?? "Camera"
                }
            }
        }
        presence.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [streamer] _ in
            streamer.stopAndWait(timeout: 2)
        }
        DispatchQueue.main.async { [installer] in
            installer.install()
        }
        if UserDefaults.standard.bool(forKey: "autoStart") {
            startStreaming()
        }
    }

    var configurableProperties: [CameraProperty] {
        cameraProperties.filter {
            $0.isWritable && $0.choices.count > 1 && FujiPropertyCatalog.isKnown($0.code)
        }
    }

    func set(_ property: CameraProperty, to value: PTPPropValue) {
        streamer.set(property: property, to: value)
    }

    private static func cameraNameKey(_ productID: UInt16) -> String {
        String(format: "cameraName.%04X", productID)
    }

    private func rememberCameraName(_ model: String) {
        guard let productID = connectedProductID, connectedCameraName != model else { return }
        UserDefaults.standard.set(model, forKey: Self.cameraNameKey(productID))
        connectedCameraName = model
    }

    func copyDiagnostics() {
        let report = Diagnostics.report(statusLine: statusLine,
                                        extensionLine: extensionLine,
                                        deviceInfo: streamer.deviceInfo,
                                        properties: cameraProperties)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    var isStreaming: Bool {
        if case .idle = streamerState { return false }
        if case .failed = streamerState { return false }
        return true
    }

    func installExtension() {
        installer.install()
    }

    func startStreaming() {
        UserDefaults.standard.set(true, forKey: "autoStart")
        streamer.start(size: liveViewSize, quality: liveViewQuality)
    }

    func stopStreaming() {
        UserDefaults.standard.set(false, forKey: "autoStart")
        streamer.stop()
    }

    func openExtensionApproval() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    var menuBarIcon: String {
        if case .streaming = streamerState { return "video.fill" }
        return connectedCameraName != nil ? "video" : "video.slash"
    }

    var statusText: String {
        switch streamerState {
        case .idle: return connectedCameraName.map { "\($0) ready" } ?? "No camera"
        case .waitingForCamera: return "Waiting for camera…"
        case .connecting: return "Connecting to camera…"
        case .streaming(let model, _): return model
        case .failed(let message): return message
        }
    }

    var fps: Double {
        if case .streaming(_, let fps) = streamerState { return fps }
        return 0
    }

    var statusLine: String {
        switch streamerState {
        case .idle: return "Not streaming"
        case .waitingForCamera: return "Waiting for camera…"
        case .connecting: return "Connecting to camera…"
        case .streaming(let model, let fps):
            return fps > 0 ? String(format: "%@ — %.0f fps", model, fps) : "\(model) — starting…"
        case .failed(let message): return message
        }
    }

    var extensionLine: String {
        switch extensionStatus {
        case .unknown: return "Camera extension: unknown"
        case .installing: return "Camera extension: installing…"
        case .needsApproval: return "Approve in System Settings → Login Items & Extensions"
        case .installed: return "Camera extension: installed"
        case .failed(let message): return "Camera extension: \(message)"
        }
    }
}
