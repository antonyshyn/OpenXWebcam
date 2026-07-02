import SwiftUI
import CameraEngine

struct MenuView: View {
    @ObservedObject var state: AppState
    @State private var dragTranslation = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            header
            extensionBanner
            settingRow("Aspect ratio") {
                Picker("Aspect ratio", selection: $state.aspect) {
                    Text("3:2").tag(OutputAspect.native)
                    Text("16:9").tag(OutputAspect.wide)
                    Text("4:3").tag(OutputAspect.classic)
                    Text("1:1").tag(OutputAspect.square)
                }
            }
            HStack {
                Text("Zoom")
                Slider(value: $state.zoom, in: 1...2)
                Text(String(format: "%.1f×", state.zoom))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                previewButton("rotate.right", active: state.rotation != 0) {
                    state.rotation = (state.rotation + 90) % 360
                }
                previewButton("arrow.left.and.right.righttriangle.left.righttriangle.right", active: state.mirrored) {
                    state.mirrored.toggle()
                }
            }
            .padding(6)
        }
        .frame(width: 276, height: 184)
        .gesture(DragGesture()
            .onChanged { value in
                state.pan(dx: Double(value.translation.width - dragTranslation.width) / 276,
                          dy: Double(value.translation.height - dragTranslation.height) / 184)
                dragTranslation = value.translation
            }
            .onEnded { _ in dragTranslation = .zero })
    }

    private func previewButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(active ? Color.accentColor : .white)
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
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
        case .idle: return state.connectedCameraName != nil ? .blue : .gray
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
