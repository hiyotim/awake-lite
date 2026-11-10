import AppKit
import SwiftUI

@main
struct AwakeLiteApp: App {
    @StateObject private var controller: AwakeController

    /// Startup, activation, inbox observation, and decision delivery. It is
    /// created once and lives with the app; the menu only displays its result.
    private let coordinator: AppCoordinator

    init() {
        let controller = AwakeController()
        _controller = StateObject(wrappedValue: controller)

        let helperPath = (try? HelperResolver.resolve(appBundle: Bundle.main.bundleURL))
            ?? IntegrationPaths.helperPath
        let catalogRoot = Bundle.main.resourceURL?
            .appendingPathComponent("Integrations", isDirectory: true)
        coordinator = AppCoordinator(
            configuration: AppCoordinator.Configuration(
                appSupportRoot: IntegrationsStore.defaultAppSupportRoot,
                catalogRoot: catalogRoot,
                helperPath: helperPath
            ),
            decisionHandler: { decision in
                controller.update(decision: decision)
            },
            diagnosticHandler: { text in
                controller.setDiagnostic(text)
            }
        )
        coordinator.start()
    }

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
        if let diagnostic = controller.diagnostic {
            Text(diagnostic)
                .font(.caption)
                .foregroundColor(.red)
        }
        Divider()
        Toggle("Пауза", isOn: controller.pauseBinding)
        Toggle("Запускать при входе", isOn: LoginItem.binding)
        Divider()
        Button("Настроить OMP…") { IntegrationsWindowController.shared.show(setupFamily: "omp") }
        Button("Интеграции…") { IntegrationsWindowController.shared.show() }
        Divider()
        Button("Выйти") { controller.quit() }
    }
}
