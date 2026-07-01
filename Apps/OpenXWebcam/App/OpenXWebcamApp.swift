import SwiftUI

@main
struct OpenXWebcamApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(systemName: state.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
