import AppKit
import Combine
import CameraEngine

@MainActor
final class AppState: ObservableObject {
    @Published var extensionStatus: ExtensionInstaller.Status = .unknown
    @Published var streamerState: CameraStreamer.State = .idle
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
    @Published var showPreview: Bool {
        didSet {
            UserDefaults.standard.set(showPreview, forKey: "showPreview")
            streamer.setPreviewEnabled(showPreview)
            if !showPreview {
                previewImage = nil
            }
        }
    }

    private let installer = ExtensionInstaller()
    private let streamer = CameraStreamer()

    init() {
        showPreview = UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true
        liveViewSize = FujiLiveViewSize(rawValue: UInt16(UserDefaults.standard.integer(forKey: "liveViewSize"))) ?? .xga
        liveViewQuality = FujiLiveViewQuality(rawValue: UInt16(UserDefaults.standard.integer(forKey: "liveViewQuality"))) ?? .normal
        installer.onStatusChange = { [weak self] status in
            self?.extensionStatus = status
        }
        streamer.onStateChange = { [weak self] state in
            self?.streamerState = state
            if case .streaming = state {} else {
                self?.previewImage = nil
            }
        }
        streamer.onPropertiesChange = { [weak self] properties in
            self?.cameraProperties = properties
        }
        streamer.onPreviewFrame = { [weak self] image in
            self?.previewImage = image
        }
        streamer.setPreviewEnabled(showPreview)
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
