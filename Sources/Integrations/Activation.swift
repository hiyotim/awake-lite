import Foundation

// MARK: - Activation state

/// One family the app should observe, at the generation it was installed with.
struct ActiveFamily: Equatable {
    var family: String
    var generation: UInt64
}

/// A journal that has not reached `committed`.
struct UnresolvedOperation: Equatable {
    var family: String
    var operationId: String
    var stage: InstallStage
}

/// What app-owned install state says about observation.
///
/// Built only from committed receipts and operation journals. It contains no
/// work state, no power decision, and no event.
struct ActivationState: Equatable {
    /// Families with a committed receipt and no unfinished operation.
    var active: [ActiveFamily]
    /// Families known to storage that must not be observed, including any
    /// family with an unfinished or conflicted operation.
    var inactive: [String]
    /// Journals that still need recovery.
    var unresolved: [UnresolvedOperation]

    var activeGenerations: [String: UInt64] {
        Dictionary(uniqueKeysWithValues: active.map { ($0.family, $0.generation) })
    }

    func generation(for family: String) -> UInt64? {
        active.first { $0.family == family }?.generation
    }

    func isActive(_ family: String) -> Bool {
        generation(for: family) != nil
    }

    func unresolvedOperation(for family: String) -> UnresolvedOperation? {
        unresolved.first { $0.family == family }
    }
}

// MARK: - Handoff

/// Reads install state and hands it to the Stage 1 model.
///
/// Boundaries: no power policy, no IOKit, no observers, no timers, and no
/// writes of any kind. It only reads receipts and journals and calls
/// `ActivityModel.activate(family:generation:)` or
/// `ActivityModel.deactivate(family:)`.
///
/// Startup (Stage 5):
///
///     try ActivationHandoff(appSupportRoot: root).apply(to: &model)
///
/// After a successful removal:
///
///     try ActivationHandoff(appSupportRoot: root).revoke(family: family, in: &model)
///
/// `apply` is authoritative: it also deactivates every family that is active
/// in the model but has no committed receipt, so a stale checkpoint cannot keep
/// observing a package that was removed while the app was not running.
struct ActivationHandoff {
    let appSupportRoot: URL

    init(appSupportRoot: URL) {
        self.appSupportRoot = appSupportRoot
    }

    /// Reads state without mutating anything.
    func readState() throws -> ActivationState {
        let storage = InstallerStorage(root: appSupportRoot)
        guard storage.exists() else {
            return ActivationState(active: [], inactive: [], unresolved: [])
        }

        var unresolved: [UnresolvedOperation] = []
        for journal in try storage.loadJournals() where journal.stage.isUnresolved {
            unresolved.append(
                UnresolvedOperation(
                    family: journal.family,
                    operationId: journal.operationId,
                    stage: journal.stage
                )
            )
        }
        // An unfinished or conflicted operation excludes its family: a
        // half-installed package never receives events, and `recoveryRequired`
        // in particular must not activate while its conflict is unresolved.
        let blocked = Set(unresolved.map(\.family))

        var active: [ActiveFamily] = []
        var inactive = blocked

        let manager = FileManager.default
        var receiptNames: [String] = []
        if manager.fileExists(atPath: storage.receipts.path) {
            do {
                receiptNames = try manager.contentsOfDirectory(atPath: storage.receipts.path)
                    .filter { $0.hasSuffix(".json") }
                    .sorted()
            } catch {
                throw InstallerError.writeFailed(
                    path: storage.receipts.path,
                    detail: error.localizedDescription
                )
            }
        }

        for name in receiptNames {
            let family = String(name.dropLast(".json".count))
            guard PathRules.isCanonicalComponent(family) else {
                throw InstallerError.receiptUnreadable(
                    path: storage.receipts.appendingPathComponent(name).path,
                    detail: "file name is not a canonical family identifier"
                )
            }
            guard let receipt = try storage.loadReceipt(family: family) else { continue }
            guard receipt.stage == .committed, receipt.activationGeneration > 0 else {
                inactive.insert(family)
                continue
            }
            guard !blocked.contains(family) else {
                inactive.insert(family)
                continue
            }
            active.append(
                ActiveFamily(family: family, generation: receipt.activationGeneration)
            )
            inactive.remove(family)
        }

        return ActivationState(
            active: active.sorted { $0.family < $1.family },
            inactive: inactive.sorted(),
            unresolved: unresolved.sorted { lhs, rhs in
                (lhs.family, lhs.operationId) < (rhs.family, rhs.operationId)
            }
        )
    }

    /// Applies the state to the model. Activation issues a new generation only
    /// when it differs from the one the model already holds, which drops work
    /// from a previous installation.
    @discardableResult
    func apply(to model: inout ActivityModel) throws -> ActivationState {
        let state = try readState()
        let generations = state.activeGenerations
        for family in Array(model.activeGenerations.keys).sorted() where generations[family] == nil {
            model.deactivate(family: family)
        }
        for entry in state.active {
            model.activate(family: entry.family, generation: entry.generation)
        }
        return state
    }

    /// Handoff for the removal path: drops the family's work and gaps.
    ///
    /// Refuses while a committed receipt still exists, so an accidental call
    /// cannot silently stop observing an installed package.
    @discardableResult
    func revoke(family: String, in model: inout ActivityModel) throws -> ActivationState {
        let state = try readState()
        if state.isActive(family) {
            throw InstallerError.conflict(
                summary: "\(family) still has a committed receipt; remove it before revoking activation"
            )
        }
        model.deactivate(family: family)
        return state
    }
}
