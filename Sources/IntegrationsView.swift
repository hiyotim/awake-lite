import AppKit
import SwiftUI

// MARK: - Store

/// Состояние окна интеграций.
///
/// Магазин читает комплектный каталог, квитанции установки и вызывает только
/// установщик. Он не держит блокировку сна, не читает события, не запускает
/// процессы и не знает форматов конфигурации продуктов.
@MainActor
final class IntegrationsStore: ObservableObject {
    /// Единственный корень, которым владеет приложение:
    /// `~/Library/Application Support/AwakeLite`.
    nonisolated static let defaultAppSupportRoot: URL = {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AwakeLite", isDirectory: true)
    }()

    enum CatalogState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// Всё, что карточка показывает. Поля — данные каталога, квитанции и
    /// результаты операций; ничего не выводится «на глаз».
    struct Card: Identifiable, Equatable {
        var family: String
        var displayName: String
        var packageVersion: String
        var targets: [TargetStatus]
        var requiresRestart: Bool
        var requiresHookTrust: Bool
        var notes: [String]
        var receipt: InstallReceipt?
        var receiptError: String?
        var recoveryRequired: Bool
        var busy: Bool
        var message: String?
        var errorText: String?

        var id: String { family }
    }

    struct PreviewSheet: Identifiable {
        enum Mode: Equatable {
            case install
            case review
        }

        let id = UUID()
        var mode: Mode
        var family: String
        var displayName: String
        var preview: InstallPreview
    }

    struct RemovalSheet: Identifiable {
        let id = UUID()
        var family: String
        var displayName: String
        var receipt: InstallReceipt
    }

    enum SheetRequest: Identifiable {
        case preview(PreviewSheet)
        case removal(RemovalSheet)

        var id: UUID {
            switch self {
            case .preview(let sheet): return sheet.id
            case .removal(let sheet): return sheet.id
            }
        }
    }

    @Published private(set) var catalogState: CatalogState = .loading
    @Published private(set) var cards: [Card] = []
    @Published private(set) var recoveryText = "Восстановление ещё не выполнялось."
    @Published var sheet: SheetRequest?

    private let resourceRoot: URL?
    private let homeRoot: URL
    private let appSupportRoot: URL

    private var catalog: Catalog?
    private var installer: Installer?
    private var discovery: ProductDiscovery
    private var manifests: [PackageManifest] = []
    private var targetStatuses: [String: [TargetStatus]] = [:]
    private var receipts: [String: InstallReceipt] = [:]
    private var receiptErrors: [String: String] = [:]
    private var recoveryFamilies: Set<String> = []
    private var busyFamilies: Set<String> = []
    private var messages: [String: String] = [:]
    private var errors: [String: String] = [:]

    init(
        resourceRoot: URL? = Bundle.main.resourceURL,
        homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSupportRoot: URL = IntegrationsStore.defaultAppSupportRoot
    ) {
        self.resourceRoot = resourceRoot
        self.homeRoot = homeRoot
        self.appSupportRoot = appSupportRoot
        self.discovery = ProductDiscovery(homeRoot: homeRoot)
        Task { self.start() }
    }

    // MARK: Загрузка

    /// Каталог читается один раз; восстановление выполняется один раз на
    /// магазин, как требует контракт установщика.
    private func start() {
        guard catalogState == .loading else { return }
        loadCatalog()
        performRecovery()
        refreshReceipts()
        rebuildCards()
    }

    private func loadCatalog() {
        guard let resourceRoot else {
            catalogState = .failed("Не удалось найти каталог ресурсов приложения: Bundle.main.resourceURL пуст.")
            return
        }
        let root = resourceRoot.appendingPathComponent("Integrations", isDirectory: true)
        do {
            let catalog = try Catalog(loading: root)
            self.catalog = catalog
            self.installer = Installer(catalog: catalog)
            self.manifests = catalog.allManifests
            var statuses: [String: [TargetStatus]] = [:]
            for manifest in manifests {
                statuses[manifest.family] = try catalog.targetStatuses(
                    for: manifest.family,
                    discovery: discovery
                )
            }
            self.targetStatuses = statuses
            catalogState = .ready
        } catch {
            catalogState = .failed("Каталог \(root.path) не загружен: \(Self.describe(error))")
        }
    }

    private func performRecovery() {
        guard let installer else {
            recoveryText = "Восстановление не выполнялось: каталог интеграций не загружен."
            return
        }
        do {
            let reports = try installer.recoverPending(appSupportRoot: appSupportRoot)
            recoveryFamilies = Set(
                reports.filter { $0.outcome == .recoveryRequired }.map(\.family)
            )
            if reports.isEmpty {
                recoveryText = "Незавершённых операций нет."
            } else {
                recoveryText = reports.map(Self.describe(report:)).joined(separator: "\n")
            }
        } catch {
            recoveryFamilies = []
            recoveryText = "Восстановление не выполнено: \(Self.describe(error))"
        }
    }

    /// Статус берётся из квитанции, а не из догадки.
    private func refreshReceipts() {
        guard let catalog else { return }
        let storage = InstallerStorage(root: appSupportRoot)
        var loaded: [String: InstallReceipt] = [:]
        var failures: [String: String] = [:]
        for manifest in catalog.allManifests {
            do {
                if let receipt = try storage.loadReceipt(family: manifest.family) {
                    loaded[manifest.family] = receipt
                }
            } catch {
                failures[manifest.family] = Self.describe(error)
            }
        }
        receipts = loaded
        receiptErrors = failures
    }

    private func rebuildCards() {
        cards = manifests.map { manifest in
            Card(
                family: manifest.family,
                displayName: manifest.displayName,
                packageVersion: manifest.packageVersion,
                targets: targetStatuses[manifest.family] ?? [],
                requiresRestart: manifest.requiresRestart,
                requiresHookTrust: manifest.requiresHookTrust,
                notes: manifest.notes,
                receipt: receipts[manifest.family],
                receiptError: receiptErrors[manifest.family],
                recoveryRequired: recoveryFamilies.contains(manifest.family),
                busy: busyFamilies.contains(manifest.family),
                message: messages[manifest.family],
                errorText: errors[manifest.family]
            )
        }
    }

    // MARK: Намерения пользователя

    func beginInstall(family: String) {
        guard !busyFamilies.contains(family) else { return }
        errors[family] = nil
        messages[family] = nil
        guard let installer else {
            errors[family] = "Каталог интеграций не загружен."
            rebuildCards()
            return
        }
        do {
            let preview = try installer.preview(
                family: family,
                configRoot: homeRoot,
                appSupportRoot: appSupportRoot,
                discovery: discovery
            )
            sheet = .preview(
                PreviewSheet(
                    mode: .install,
                    family: family,
                    displayName: preview.displayName,
                    preview: preview
                )
            )
        } catch {
            errors[family] = Self.describe(error)
        }
        rebuildCards()
    }

    func beginReview(family: String) {
        guard !busyFamilies.contains(family) else { return }
        errors[family] = nil
        messages[family] = nil
        guard let installer else {
            errors[family] = "Каталог интеграций не загружен."
            rebuildCards()
            return
        }
        do {
            let preview = try installer.preview(
                family: family,
                configRoot: homeRoot,
                appSupportRoot: appSupportRoot,
                discovery: discovery
            )
            sheet = .preview(
                PreviewSheet(
                    mode: .review,
                    family: family,
                    displayName: preview.displayName,
                    preview: preview
                )
            )
        } catch {
            errors[family] = Self.describe(error)
        }
        rebuildCards()
    }

    func beginRemoval(family: String) {
        guard !busyFamilies.contains(family) else { return }
        errors[family] = nil
        messages[family] = nil
        if let receiptError = receiptErrors[family] {
            errors[family] = receiptError
            rebuildCards()
            return
        }
        guard let receipt = receipts[family] else {
            errors[family] = "Поддержка не установлена, удалять нечего."
            rebuildCards()
            return
        }
        let displayName = manifests.first { $0.family == family }?.displayName ?? family
        sheet = .removal(
            RemovalSheet(family: family, displayName: displayName, receipt: receipt)
        )
        rebuildCards()
    }

    /// Применяется ровно тот предпросмотр, который подтвердил пользователь.
    func apply(_ preview: InstallPreview) {
        let family = preview.family
        guard !busyFamilies.contains(family) else { return }
        busyFamilies.insert(family)
        errors[family] = nil
        messages[family] = nil
        rebuildCards()
        Task { self.performApply(preview) }
    }

    func remove(family: String) {
        guard !busyFamilies.contains(family) else { return }
        busyFamilies.insert(family)
        errors[family] = nil
        messages[family] = nil
        rebuildCards()
        Task { self.performRemoval(family) }
    }

    /// Честный отчёт: адаптеров этапа 3 ещё нет, поэтому событий нет.
    func checkConnection(family: String) {
        guard !busyFamilies.contains(family) else { return }
        errors[family] = nil
        let recovery = recoveryFamilies.contains(family)
            || receipts[family]?.stage == .recoveryRequired
        if recovery {
            let recorded = receipts[family].map {
                "поддержка записана на поколении активации \($0.activationGeneration)"
            } ?? "квитанция установки не записана"
            messages[family] = """
            Требуется восстановление: \(recorded), но операция не завершена. \
            Источника событий нет, состояние работы не наблюдается. \
            Подключение не подтверждено.
            """
        } else if let receipt = receipts[family] {
            messages[family] = """
            Поддержка установлена на поколении активации \(receipt.activationGeneration). \
            Источника событий пока нет: адаптеры появятся на этапе 3, поэтому ни одно состояние работы \
            наблюдать нельзя. Подключение не подтверждено.
            """
        } else if let receiptError = receiptErrors[family] {
            messages[family] = "Квитанция установки не читается, состояние работы неизвестно: \(receiptError)"
        } else {
            messages[family] = "Поддержка не установлена. Источника событий нет, подключение не подтверждено."
        }
        rebuildCards()
    }

    // MARK: Операции

    private func performApply(_ preview: InstallPreview) {
        let family = preview.family
        defer {
            busyFamilies.remove(family)
            refreshReceipts()
            rebuildCards()
        }
        guard let installer else {
            errors[family] = "Каталог интеграций не загружен."
            return
        }
        do {
            let receipt = try installer.apply(preview)
            recoveryFamilies.remove(family)
            messages[family] = """
            Установлено. Поколение активации \(receipt.activationGeneration); \
            записей под контролем AwakeLite: \(receipt.entries.count). \
            Это инертные шаблоны: к продукту они ещё не подключены.
            """
        } catch {
            errors[family] = Self.describe(error)
        }
    }

    private func performRemoval(_ family: String) {
        defer {
            busyFamilies.remove(family)
            refreshReceipts()
            rebuildCards()
        }
        guard let installer else {
            errors[family] = "Каталог интеграций не загружен."
            return
        }
        do {
            let report = try installer.remove(family: family, appSupportRoot: appSupportRoot)
            recoveryFamilies.remove(family)
            var lines = ["Поддержка удалена."]
            lines.append(
                report.removedPaths.isEmpty
                    ? "Изменённых путей нет."
                    : "Удалённые пути: " + report.removedPaths.joined(separator: ", ")
            )
            if !report.preservedPaths.isEmpty {
                lines.append("Сохранённые пути: " + report.preservedPaths.joined(separator: ", "))
            }
            if !report.warnings.isEmpty {
                lines.append("Предупреждения: " + report.warnings.joined(separator: "; "))
            }
            messages[family] = lines.joined(separator: "\n")
        } catch {
            errors[family] = Self.describe(error)
        }
    }

    // MARK: Форматирование

    /// Описание ошибки из самого типа: `CustomStringConvertible` для ошибок
    /// установщика, иначе стандартное описание.
    nonisolated static func describe(_ error: Error) -> String {
        String(describing: error)
    }

    private static func describe(report: RecoveryReport) -> String {
        let action = report.action == .install ? "установка" : "удаление"
        switch report.outcome {
        case .forwardCommitted:
            return "Операция \(report.operationId) (\(report.family), \(action)) завершена вперёд: изменения применены."
        case .rolledBack:
            return "Операция \(report.operationId) (\(report.family), \(action)) откачена: изменения не применены."
        case .recoveryRequired:
            let conflicts = report.conflicts.isEmpty
                ? "конфликты не описаны"
                : report.conflicts.joined(separator: "; ")
            return "Операция \(report.operationId) (\(report.family), \(action)) требует восстановления: \(conflicts)"
        }
    }
}

// MARK: - Window

/// Хост окна каталога. Единственное окно создаётся при первом вызове
/// `show()`, то есть только по нажатию пункта меню. При запуске приложения
/// этого типа никто не инстанцирует окно: `NSWindow` только создаётся
/// внутри `makeWindow()`.
@MainActor
final class IntegrationsWindowController {
    /// Общий экземпляр. Создание контроллера окна не создаёт.
    static let shared = IntegrationsWindowController()

    private static let frameAutosaveName = "AwakeLiteIntegrationsWindow"

    private var window: NSWindow?

    private init() {}

    /// Показывает окно каталога, создавая его при первом обращении.
    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: IntegrationsView())
        )
        window.title = "Интеграции"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Закрытие только убирает окно; приложение и наблюдение остаются.
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 780, height: 640))
        window.center()
        // Восстанавливает запомненный кадр, если он есть.
        window.setFrameAutosaveName(Self.frameAutosaveName)
        return window
    }
}

struct IntegrationsView: View {
    @StateObject private var store = IntegrationsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(minWidth: 720, minHeight: 560)
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .preview(let request):
                InstallPreviewSheet(store: store, request: request)
            case .removal(let request):
                RemovalSheetView(store: store, request: request)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Интеграции")
                .font(.largeTitle.bold())
            Text("Поддержка устанавливается только для выбранного продукта. Наличие продукта не означает проверенную совместимость.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(store.recoveryText)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch store.catalogState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Загрузка каталога…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ScrollView {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .ready:
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.cards) { card in
                        IntegrationCardView(store: store, card: card)
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Card

private struct IntegrationCardView: View {
    @ObservedObject var store: IntegrationsStore
    let card: IntegrationsStore.Card

    private var statusText: String {
        if card.receiptError != nil { return "Статус неизвестен" }
        if card.recoveryRequired { return "Требуется восстановление" }
        guard let receipt = card.receipt else { return "Не установлена" }
        if receipt.stage == .recoveryRequired { return "Требуется восстановление" }
        return "Установлена, поколение активации \(receipt.activationGeneration)"
    }

    private var statusColor: Color {
        if card.receiptError != nil || card.recoveryRequired { return .orange }
        return card.receipt == nil ? .secondary : .green
    }

    private var requiredActions: [String] {
        var actions: [String] = []
        if card.receipt == nil {
            if card.receiptError != nil {
                actions.append("Устранить ошибку чтения квитанции и проверить статус заново.")
            }
            actions.append("Установить поддержку для \(card.displayName).")
        } else {
            actions.append("Проверить подключение после запуска \(card.displayName).")
            if card.requiresRestart {
                actions.append("Перезапустить \(card.displayName), чтобы он перечитал конфигурацию.")
            }
            if card.requiresHookTrust {
                actions.append("Подтвердить доверие к установленному хуку в \(card.displayName).")
            }
            actions.append("Удалить поддержку, когда она больше не нужна.")
        }
        if card.targets.contains(where: { $0.verificationLevel == .unverified }) {
            actions.append("Проверить совместимость на реальном продукте: уровень достоверности остаётся объявленным манифестом.")
        }
        return actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.displayName)
                    .font(.title3.bold())
                Text("версия пакета \(card.packageVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusText)
                    .font(.callout.bold())
                    .foregroundStyle(statusColor)
                    .textSelection(.enabled)
            }

            targetsSection

            Text("Уровень достоверности объявлен манифестом. Обнаружение продукта его не повышает.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if card.requiresRestart {
                Label("После установки требуется перезапуск \(card.displayName).", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            if card.requiresHookTrust {
                Label("\(card.displayName) требует подтверждения доверия к установленному хуку.", systemImage: "checkmark.shield")
                    .font(.callout)
            }

            if !card.notes.isEmpty {
                bulletSection("Примечания пакета", card.notes)
            }
            bulletSection("Требуемые действия", requiredActions)

            if let receiptError = card.receiptError {
                Text("Квитанция установки не читается: \(receiptError)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = card.message {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText = card.errorText {
                Text("Ошибка: \(errorText)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    @ViewBuilder
    private var targetsSection: some View {
        if card.targets.isEmpty {
            Text("Манифест не объявляет целей совместимости.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.targets, id: \.id) { target in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(target.id)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Text(Self.modeLabel(target.mode))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(target.isAvailable ? "продукт найден" : "продукт не найден")
                            .font(.callout)
                            .foregroundStyle(target.isAvailable ? Color.primary : Color.secondary)
                        if target.isAvailable {
                            Text(target.presentPaths.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(Self.verificationLabel(target.verificationLevel))
                            .font(.callout)
                    }
                }
            }
        }
    }

    private func bulletSection(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.bold())
            ForEach(values.indices, id: \.self) { index in
                Text("• " + values[index])
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Установить поддержку") { store.beginInstall(family: card.family) }
            Button("Удалить поддержку") { store.beginRemoval(family: card.family) }
                .disabled(card.receipt == nil || card.receiptError != nil)
            Button("Проверить подключение") { store.checkConnection(family: card.family) }
            Button("Показать изменения") { store.beginReview(family: card.family) }
            if card.busy {
                ProgressView()
                    .controlSize(.small)
                Text("Выполняется…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .disabled(card.busy)
    }

    static func modeLabel(_ mode: IntegrationTargetMode) -> String {
        switch mode {
        case .cli: return "CLI"
        case .desktop: return "Настольное приложение"
        }
    }

    static func verificationLabel(_ level: VerificationLevel) -> String {
        switch level {
        case .unverified: return "Не проверено"
        case .fixture: return "Проверено фикстурами"
        case .live: return "Проверено в реальном продукте"
        }
    }

    static func actionLabel(_ action: PreviewAction) -> String {
        switch action {
        case .create: return "создать"
        case .update: return "обновить"
        case .unchanged: return "без изменений"
        case .conflict: return "конфликт"
        }
    }
}

// MARK: - Preview sheet

private struct InstallPreviewSheet: View {
    @ObservedObject var store: IntegrationsStore
    let request: IntegrationsStore.PreviewSheet
    @Environment(\.dismiss) private var dismiss

    private var preview: InstallPreview { request.preview }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    facts
                    section("Корень конфигурации", [preview.configRoot], emptyText: nil)
                    section("Данные приложения", [preview.appSupportRoot], emptyText: nil)
                    generation
                    targets
                    section("Точные пути", preview.paths, emptyText: "Путей нет.")
                    entries
                    section("Конфликты", preview.conflicts, emptyText: "Нет.")
                    section("Предупреждения", preview.warnings, emptyText: "Нет.")
                    section("Примечания пакета", preview.notes, emptyText: "Нет.")
                    section("Путь помощника", [preview.helperPath], emptyText: nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if request.mode == .install && !preview.canApply {
                Text("Применение невозможно: в предпросмотре есть конфликты. Устраните их и постройте предпросмотр заново.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(18)
        .frame(width: 760, height: 640)
    }

    private var title: String {
        switch request.mode {
        case .install: return "Установка поддержки: \(request.displayName)"
        case .review: return "Изменения: \(request.displayName)"
        }
    }

    @ViewBuilder
    private var facts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Пакет \(preview.packageVersion) · поколение активации, которое будет выдано: \(preview.activationGeneration)")
            Text("Предыдущее поколение: \(preview.previousGeneration.map(String.init) ?? "нет")")
            Text("Перезапуск продукта: \(preview.requiresRestart ? "требуется" : "не требуется")")
            Text("Доверие к хуку: \(preview.requiresHookTrust ? "требуется" : "не требуется")")
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var generation: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Поколение активации")
                .font(.headline)
            Text("Будет выдано поколение \(preview.activationGeneration); записи шаблонов получат это значение.")
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var targets: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Настраиваемые цели")
                .font(.headline)
            if preview.resolvedTargets.isEmpty {
                Text("Целей нет.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(preview.resolvedTargets, id: \.self) { id in
                    Text(id)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Записи под контролем AwakeLite")
                .font(.headline)
            if preview.entries.isEmpty {
                Text("Пакет не добавляет записей.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(preview.entries, id: \.marker) { entry in
                    Text(
                        "\(IntegrationCardView.actionLabel(entry.action)) · \(entry.marker) · "
                            + "цель \(entry.target) · формат \(entry.format.rawValue) · "
                            + "\(entry.kind.rawValue) · \(entry.path)"
                    )
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch request.mode {
            case .install:
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if preview.canApply {
                    Button("Применить") {
                        store.apply(preview)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .review:
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ values: [String], emptyText: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if values.isEmpty {
                if let emptyText {
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(values.indices, id: \.self) { index in
                    Text(values[index])
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Removal sheet

private struct RemovalSheetView: View {
    @ObservedObject var store: IntegrationsStore
    let request: IntegrationsStore.RemovalSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Удаление поддержки: \(request.displayName)")
                .font(.title2.bold())
            Text("Удаляются только записи из квитанции установки. Посторонние настройки, хуки и файлы сохраняются.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Поколение активации: \(request.receipt.activationGeneration)")
                .font(.callout)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(request.receipt.entries, id: \.marker) { entry in
                        Text(
                            "• \(entry.marker) · цель \(entry.target) · формат \(entry.format.rawValue) · "
                                + "\(entry.kind.rawValue) · \(entry.path)"
                                + (entry.createdFile ? " · файл создан установкой и будет удалён" : "")
                        )
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Удалить поддержку") {
                    store.remove(family: request.family)
                    dismiss()
                }
            }
        }
        .padding(18)
        .frame(width: 720, height: 540)
    }
}
