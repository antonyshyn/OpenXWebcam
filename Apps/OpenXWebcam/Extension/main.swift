import Foundation
import CoreMediaIO

let providerSource = ProviderSource()
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
