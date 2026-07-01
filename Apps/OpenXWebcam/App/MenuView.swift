import SwiftUI
import CameraEngine

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.showPreview {
                preview
            }
            header
            extensionBanner
            settingRow("Resolution") {
                Picker("Resolution", selection: $state.liveViewSize) {
                    Text("1024×768").tag(FujiLiveViewSize.xga)
                    Text("640×480").tag(FujiLiveViewSize.vga)
                    Text("320×240").tag(FujiLiveViewSize.qvga)
                }
            }
            settingRow("Quality") {
                Picker("Quality", selection: $state.liveViewQuality) {
                    Text("Smooth — higher fps").tag(FujiLiveViewQuality.normal)
                    Text("Fine — sharper image").tag(FujiLiveViewQuality.fine)
                }
            }
            settingRow("Rotation") {
                Picker("Rotation", selection: $state.rotation) {
                    Text("Off").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
            }
            settingRow("Mirror") {
                Toggle("Mirror", isOn: $state.mirrored)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            ForEach(state.configurableProperties) { property in
                settingRow(property.name) {
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
            footer
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
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 96)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.fps > 0 {
                Text(String(format: "%.0f fps", state.fps))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
        }
        .frame(width: 276, height: 184)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(state.statusText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Toggle("Streaming", isOn: streaming)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private var statusColor: Color {
        switch state.streamerState {
        case .idle: return state.cameraConnected ? .blue : .gray
        case .waitingForCamera, .connecting: return .orange
        case .streaming: return .green
        case .failed: return .red
        }
    }

    private var streaming: Binding<Bool> {
        Binding(
            get: { state.isStreaming },
            set: { $0 ? state.startStreaming() : state.stopStreaming() }
        )
    }

    @ViewBuilder
    private var extensionBanner: some View {
        switch state.extensionStatus {
        case .installing:
            banner {
                ProgressView()
                    .controlSize(.small)
                Text("Installing camera extension…")
            }
        case .needsApproval:
            banner {
                Text("Approve the camera extension in System Settings")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open") { state.openExtensionApproval() }
            }
        case .failed(let message):
            banner {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry") { state.installExtension() }
            }
        case .installed, .unknown:
            EmptyView()
        }
    }

    private func banner<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.caption)
        .controlSize(.small)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func settingRow<Control: View>(_ name: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(name)
            Spacer()
            control()
                .labelsHidden()
                .fixedSize()
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Toggle("Launch at Login", isOn: $state.launchAtLogin)
                Toggle("Show Preview", isOn: $state.showPreview)
                Divider()
                Button("Copy Diagnostics") { state.copyDiagnostics() }
                Button("Reinstall Camera Extension") { state.installExtension() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
    }
}
