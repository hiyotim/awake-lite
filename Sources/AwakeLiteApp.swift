import AppKit
import SwiftUI

@main
struct AwakeLiteApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("Агентов нет")
            Divider()
            Button("Выйти") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "moon.zzz")
        }
        .menuBarExtraStyle(.menu)
    }
}
