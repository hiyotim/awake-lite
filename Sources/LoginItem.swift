import ServiceManagement
import SwiftUI

/// Пункт «Запускать при входе». Состояние читается у системы, а не хранится
/// самим приложением: пользователь может снять галочку в настройках macOS.
enum LoginItem {
    static var binding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("AwakeLite: автозапуск не переключился: \(error.localizedDescription)")
                }
            }
        )
    }
}
