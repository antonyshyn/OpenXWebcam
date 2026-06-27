import SwiftUI

@main
struct OpenXWebcamApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("OpenXWebcam", systemImage: "camera.fill") {
            MenuView(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}
