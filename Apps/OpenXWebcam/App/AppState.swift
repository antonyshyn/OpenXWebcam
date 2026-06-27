import AppKit
import Combine
import CameraEngine

@MainActor
final class AppState: ObservableObject {
    @Published var extensionStatus: ExtensionInstaller.Status = .unknown
    @Published var streamerState: CameraStreamer.State = .idle
    @Published var liveViewSize: FujiLiveViewSize = .xga
    @Published var liveViewQuality: FujiLiveViewQuality = .normal
    @Published var cameraProperties: [CameraProperty] = []

    private let installer = ExtensionInstaller()
    private let streamer = CameraStreamer()

    init() {
        installer.onStatusChange = { [weak self] status in
            self?.extensionStatus = status
        }
        streamer.onStateChange = { [weak self] state in
            self?.streamerState = state
        }
        streamer.onPropertiesChange = { [weak self] properties in
            self?.cameraProperties = properties
        }
    }

    var configurableProperties: [CameraProperty] {
        cameraProperties.filter { $0.isWritable && $0.choices.count > 1 }
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
        streamer.start(size: liveViewSize, quality: liveViewQuality)
    }

    func stopStreaming() {
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
