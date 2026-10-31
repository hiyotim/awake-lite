import AppKit
import SwiftUI

@main
struct AwakeLiteApp: App {
    @StateObject private var controller = AwakeController()

    var body: some Scene {
        MenuBarExtra {
            Text(controller.statusText)
            Divider()
            Button("Выйти") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "moon.zzz")
        }
        .menuBarExtraStyle(.menu)
    }
}
