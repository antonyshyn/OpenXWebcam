import Foundation
import CPTPTransport

public final class CameraPresence {
    public var onChange: ((Bool) -> Void)?

    private let watcher = PTPUSBWatcher()
    private let queue = DispatchQueue(label: "com.openxwebcam.camera-presence")
    private var attached: Set<UInt64> = []

    public init() {
        watcher.onAttach = { [weak self] info in
            guard let self, info.vendorID == DiscoveredCamera.fujiVendorID else { return }
            let wasEmpty = attached.isEmpty
            attached.insert(info.registryID)
            if wasEmpty {
                onChange?(true)
            }
        }
        watcher.onDetach = { [weak self] registryID in
            guard let self, attached.remove(registryID) != nil else { return }
            if attached.isEmpty {
                onChange?(false)
            }
        }
    }

    public func start() {
        queue.async {
            _ = self.watcher.start(on: self.queue)
        }
    }
}
