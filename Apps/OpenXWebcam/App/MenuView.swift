import SwiftUI
import CameraEngine

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.showPreview {
                preview
            }
            Text(state.statusLine)
                .font(.callout)
            Text(state.extensionLine)
                .font(.callout)
                .foregroundStyle(.secondary)
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
            Divider()
            Toggle("Show Preview", isOn: $state.showPreview)
            Button("Install Camera Extension") { state.installExtension() }
            Button("Copy Diagnostics") { state.copyDiagnostics() }
            Divider()
            Button("Quit OpenXWebcam") { NSApplication.shared.terminate(nil) }
        }
        .pickerStyle(.menu)
        .padding(12)
        .frame(width: 300)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black)
            if let image = state.previewImage {
                Image(image, scale: 1, label: Text("Camera preview"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "video.slash")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 276, height: 207)
    }
}
