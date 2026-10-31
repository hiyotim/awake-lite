import Foundation

/// Отвечает на единственный вопрос: запущен ли процесс с таким именем.
///
/// Точного имени недостаточно: CLI может называться `opencode.exe` или жить за
/// интерпретатором. Поэтому сначала пробуем точное имя, а если пусто — якорный
/// поиск по командной строке: он принимает путь перед именем и суффикс `.exe`,
/// но не совпадает с `vim opencode.swift`.
enum ProcessScanner {
    static func running(_ names: [String]) -> [String] {
        names.filter { name in
            pgrep(["-x", name]) || pgrep(["-f", pattern(for: name)])
        }
    }

    private static func pattern(for name: String) -> String {
        "(^|/)\(name)(\\.exe)?( |$)"
    }

    private static func pgrep(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
