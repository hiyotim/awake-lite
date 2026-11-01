import AppKit
import SwiftUI

@main
struct AwakeLiteApp: App {
    @StateObject private var controller = AwakeController()

    // Единственная сцена приложения — строка меню. Окно каталога создаётся
    // вручную при нажатии пункта «Интеграции…» и при запуске не существует.
    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            Image(systemName: controller.isHolding ? "cup.and.saucer.fill" : "moon.zzz")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var controller: AwakeController

    var body: some View {
        Text(controller.statusText)
        Divider()
        Toggle("Пауза", isOn: controller.pauseBinding)
        Toggle("Запускать при входе", isOn: LoginItem.binding)
        Divider()
        Button("Интеграции…") { IntegrationsWindowController.shared.show() }
        Divider()
        Button("Выйти") { controller.quit() }
    }
}
