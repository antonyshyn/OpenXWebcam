import SwiftUI
import CameraEngine

@main
struct OpenXWebcamApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("OpenXWebcam", systemImage: "camera.fill") {
            Text(state.statusLine)
            Text(state.extensionLine)
            Divider()
            if state.isStreaming {
                Button("Stop Streaming") { state.stopStreaming() }
            } else {
                Button("Start Streaming") { state.startStreaming() }
            }
            Picker("Resolution", selection: $state.liveViewSize) {
                Text("1024×768").tag(FujiLiveViewSize.xga)
                Text("640×480").tag(FujiLiveViewSize.vga)
                Text("320×240").tag(FujiLiveViewSize.qvga)
            }
            Picker("Quality", selection: $state.liveViewQuality) {
                Text("Smooth").tag(FujiLiveViewQuality.normal)
                Text("Fine").tag(FujiLiveViewQuality.fine)
            }
            if !state.configurableProperties.isEmpty {
                Divider()
                ForEach(state.configurableProperties) { property in
                    Picker(property.name, selection: Binding(
                        get: { property.currentValue },
                        set: { state.set(property, to: $0) }
                    )) {
                        ForEach(property.choices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                }
            }
            Divider()
            Button("Install Camera Extension") { state.installExtension() }
            Button("Copy Diagnostics") { state.copyDiagnostics() }
            Divider()
            Button("Quit OpenXWebcam") { NSApplication.shared.terminate(nil) }
        }
    }
}
