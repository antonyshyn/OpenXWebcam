import Foundation
import SystemExtensions

final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    enum Status: Equatable {
        case unknown
        case installing
        case needsApproval
        case installed
        case failed(String)
    }

    static let extensionIdentifier = "com.openxwebcam.app.Extension"

    var onStatusChange: ((Status) -> Void)?
    private var startsNewExtension = false
    private(set) var status: Status = .unknown {
        didSet {
            let status = status
            DispatchQueue.main.async { [onStatusChange] in
                onStatusChange?(status)
            }
        }
    }

    func install() {
        startsNewExtension = false
        status = .installing
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        startsNewExtension = true
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        startsNewExtension = true
        status = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            DispatchQueue.main.asyncAfter(deadline: .now() + (startsNewExtension ? 3 : 0)) { [weak self] in
                self?.status = .installed
            }
        case .willCompleteAfterReboot:
            status = .failed("Restart required to finish installing")
        @unknown default:
            status = .failed("Unexpected install result")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = .failed(error.localizedDescription)
    }
}
