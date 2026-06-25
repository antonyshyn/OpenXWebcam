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
    private(set) var status: Status = .unknown {
        didSet {
            let status = status
            DispatchQueue.main.async { [onStatusChange] in
                onStatusChange?(status)
            }
        }
    }

    func install() {
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
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            status = .installed
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
