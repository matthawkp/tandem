import CoreMediaIO
import Foundation

let providerSource = CameraProvider(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
