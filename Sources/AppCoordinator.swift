import Darwin
import Foundation

extension Notification.Name {
    /// Posted by the catalog store after an install, removal, or recovery.
    /// The coordinator re-reads receipts and journals; it never trusts the
    /// UI's in-memory copy of install state.
    static let awakeLiteActivationChanged = Notification.Name("AwakeLiteActivationChanged")
}

/// App-owned startup and observation path.
///
/// Order at startup: recover a pending install operation, load the model
/// checkpoint, apply committed activation generations, reconcile the inbox,
/// and deliver the aggregate decision. The model is kept in memory and the
/// checkpoint is written by this coordinator only. Inbox observation and the
/// periodic recovery pass exist only while the shipped family is active.
///
/// Main-thread affinity: `start`, `stop`, `reconcileNow`, and
/// `activationChanged` are expected on the main queue. The file watcher and
/// timer are main-queue sources, so the model is never touched concurrently.
final class AppCoordinator {
    static let observedFamily = "omp"

    struct Configuration {
        var appSupportRoot: URL
        /// Directory containing `<family>/manifest.json` packages. `nil` skips
        /// install recovery but still allows activation and inbox work.
        var catalogRoot: URL?
        var helperPath: String
        /// Recovery cadence for missed file notifications. The watcher handles
        /// the normal path; this is the bounded recovery pass.
        var reconcileInterval: TimeInterval = 30
        var storeLimits = LocalEventStore.Limits()
    }

    private(set) var isObserving = false
    private(set) var activationState: ActivationState?
    private(set) var lastDiagnostic: String?

    private let configuration: Configuration
    private let store: LocalEventStore
    private let activation: ActivationHandoff
    private let decisionHandler: (AggregateDecision) -> Void
    private let diagnosticHandler: (String?) -> Void

    private var model = ActivityModel()
    private var modelLoaded = false
    private var activationValid = true
    private var started = false
    private var inboxSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var activationToken: NSObjectProtocol?

    init(
        configuration: Configuration,
        decisionHandler: @escaping (AggregateDecision) -> Void,
        diagnosticHandler: @escaping (String?) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.store = LocalEventStore(
            root: configuration.appSupportRoot,
            limits: configuration.storeLimits
        )
        self.activation = ActivationHandoff(appSupportRoot: configuration.appSupportRoot)
        self.decisionHandler = decisionHandler
        self.diagnosticHandler = diagnosticHandler
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        do {
            try store.prepare()
            model = try store.loadModel()
            modelLoaded = true
        } catch {
            // Never replace an unreadable checkpoint with an empty model.
            report("Состояние не загружено: \(error). Блокировка сна не управляется.")
            deliverUnavailable("checkpointUnreadable")
            return
        }

        model.retireForeignBoots(currentBootID: OwnerIdentityProbe.bootToken())
        recoverInstallations()
        installActivationObserver()
        applyActivation(save: true)
        updateObservation()
        reconcileNow()
    }

    func stop() {
        started = false
        stopObserver()
        if let activationToken {
            NotificationCenter.default.removeObserver(activationToken)
            self.activationToken = nil
        }
    }

    // MARK: - Reconciliation

    /// Applies one bounded inbox pass and updates the power decision.
    func reconcileNow() {
        guard started, modelLoaded, activationValid else { return }
        do {
            let result = try store.reconcile(&model)
            if result.deleteFailures > 0 {
                report("\(result.deleteFailures) обработанных событий не удалось удалить; они будут повторены.")
            }
            decisionHandler(model.decision)
        } catch {
            // The store leaves every unprocessed file in place when the save
            // fails, so the next pass can retry without losing facts.
            report("События не применены: \(error)")
            deliverUnavailable("reconcileFailed")
        }
    }

    /// Re-reads install state after a catalog operation. The model's active
    /// generation follows the receipt; a removed family is deactivated and
    /// stops being observed.
    func activationChanged() {
        guard started, modelLoaded else { return }
        applyActivation(save: true)
        reconcileNow()
        updateObservation()
    }

    // MARK: - Install state

    private func recoverInstallations() {
        guard let catalogRoot = configuration.catalogRoot else {
            report("Каталог интеграций недоступен: восстановление установки не выполнено.")
            return
        }
        do {
            let catalog = try Catalog(loading: catalogRoot)
            let installer = Installer(catalog: catalog, helperPath: configuration.helperPath)
            let reports = try installer.recoverPending(appSupportRoot: configuration.appSupportRoot)
            let blocked = reports.filter { $0.outcome == .recoveryRequired }
            if !blocked.isEmpty {
                report(
                    "Установка требует восстановления: "
                        + blocked.map { "\($0.family) (\($0.operationId))" }.joined(separator: ", ")
                )
            }
        } catch {
            report("Восстановление установки не выполнено: \(error)")
        }
    }

    private func applyActivation(save: Bool) {
        do {
            let state = try activation.apply(to: &model)
            activationState = state
            activationValid = true
            if state.unresolved.isEmpty {
                clearDiagnostic()
            } else {
                report(
                    "Незавершённые операции: "
                        + state.unresolved
                        .map { "\($0.family) (\($0.stage))" }
                        .joined(separator: ", ")
                )
            }
            if save {
                do {
                    try store.saveModel(model)
                } catch {
                    report("Состояние не сохранено: \(error). Следующий проход повторит запись.")
                }
            }
        } catch {
            // Fail closed: without readable install state the app must not
            // observe a family or keep a decision derived from it.
            activationValid = false
            activationState = nil
            for family in Array(model.activeGenerations.keys) {
                model.deactivate(family: family)
            }
            report("Состояние активации не прочитано: \(error). Наблюдение остановлено.")
            deliverUnavailable("activationUnreadable")
            updateObservation()
        }
    }

    private func installActivationObserver() {
        guard activationToken == nil else { return }
        activationToken = NotificationCenter.default.addObserver(
            forName: .awakeLiteActivationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activationChanged()
        }
    }

    // MARK: - Observation

    private func updateObservation() {
        if activationState?.isActive(Self.observedFamily) == true {
            startObserver()
        } else {
            stopObserver()
        }
    }

    private func startObserver() {
        guard started, !isObserving else { return }
        try? store.prepare()

        let descriptor = store.inbox.path.withCString { open($0, O_EVTONLY) }
        guard descriptor >= 0 else {
            report("Inbox недоступен для наблюдения: \(store.inbox.path).")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            self.reconcileNow()
            if flags.contains(.delete) || flags.contains(.rename) {
                self.stopObserver()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self,
                          self.activationState?.isActive(Self.observedFamily) == true else { return }
                    self.startObserver()
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        inboxSource = source
        isObserving = true

        guard configuration.reconcileInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + configuration.reconcileInterval,
            repeating: configuration.reconcileInterval,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.reconcileNow()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopObserver() {
        timer?.cancel()
        timer = nil
        inboxSource?.cancel()
        inboxSource = nil
        isObserving = false
    }

    // MARK: - Reporting

    private func deliverUnavailable(_ reason: String) {
        decisionHandler(
            AggregateDecision(
                state: .unknown,
                holdAssertion: false,
                reasons: [reason]
            )
        )
    }

    private func report(_ text: String) {
        guard text != lastDiagnostic else { return }
        lastDiagnostic = text
        diagnosticHandler(text)
    }

    private func clearDiagnostic() {
        guard lastDiagnostic != nil else { return }
        lastDiagnostic = nil
        diagnosticHandler(nil)
    }
}
