import Foundation
import CPTPTransport

public final class CameraPresence {
    public var onChange: ((String?) -> Void)?

    private let watcher = PTPUSBWatcher()
    private let queue = DispatchQueue(label: "com.openxwebcam.camera-presence")
    private var attached: [UInt64: String] = [:]

    public init() {
        watcher.onAttach = { [weak self] info in
            guard let self, info.vendorID == DiscoveredCamera.fujiVendorID else { return }
            attached[info.registryID] = info.productName ?? "Camera"
            onChange?(attached.values.first)
        }
        watcher.onDetach = { [weak self] registryID in
            guard let self, attached.removeValue(forKey: registryID) != nil else { return }
            onChange?(attached.values.first)
        }
    }

    public func start() {
        queue.async {
            _ = self.watcher.start(on: self.queue)
        }
    }
}
