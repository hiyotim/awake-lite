import AppKit
import SwiftUI

@main
struct AwakeLiteApp: App {
    @StateObject private var controller = AwakeController()

    var body: some Scene {
        MenuBarExtra {
            Text(controller.statusText)
            Divider()
            Toggle("Пауза", isOn: controller.pauseBinding)
            Divider()
            Button("Выйти") { controller.quit() }
        } label: {
            Image(systemName: controller.isHolding ? "cup.and.saucer.fill" : "moon.zzz")
        }
        .menuBarExtraStyle(.menu)
    }
}
