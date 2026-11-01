import Foundation

// MARK: - Identity

/// Process identity of an observation source.
///
/// A PID alone is insufficient: macOS reuses PIDs, and the same numeric PID
/// after a reboot names a different process. The tuple identifies one process
/// lifetime. `instance` names the adapter's logical instance.
struct OwnerIdentity: Codable, Hashable {
    var bootID: String
    var pid: Int32
    var startTimeMicros: UInt64
    var uid: UInt32
    var instance: String
}

/// Identity of one agent session.
///
/// Identical session strings from different families or instances stay
/// separate; they are not merged.
struct SessionIdentity: Codable, Hashable {
    var family: String
    var instance: String
    var session: String
}

/// Identity of one unit of work inside a session.
///
/// `generation` separates an old work item from a newer one that reuses the
/// same name, so a late completion cannot close newer work.
struct WorkIdentity: Codable, Hashable {
    var session: SessionIdentity
    var generation: UInt64
    var work: String
}

// MARK: - Work state

enum WorkState: String, Codable, CaseIterable {
    /// Confirmed unfinished work.
    case working
    /// Progress requires a person. A waiting parent does not cancel a working
    /// child; the child is a separate record.
    case waitingForUser
    /// Previously confirmed unfinished work whose observation was lost.
    case uncertain
    case completed
    case failed
    case cancelled
    /// An authoritative snapshot reported the work as no longer active.
    case ended

    var isActive: Bool {
        switch self {
        case .working, .waitingForUser, .uncertain:
            return true
        case .completed, .failed, .cancelled, .ended:
            return false
        }
    }

    var isTerminal: Bool { !isActive }
}

// MARK: - Events

enum ActivityTransition: String, Codable, CaseIterable {
    case started
    case humanWait
    case resumed
    case completed
    case failed
    case cancelled
    case childStarted
    case childFinished
    case snapshot
    case observationLost
    /// Confirms observer liveness. It never establishes work state.
    case heartbeat
    /// The observed owner terminated. Only that owner's work is retired.
    case ownerTerminated
}

/// Scope covered by an authoritative snapshot or by an observation-loss report.
enum SnapshotScope: String, Codable {
    case session
    case instance
}

struct SnapshotEntry: Codable, Hashable {
    var session: SessionIdentity
    var work: String
    var generation: UInt64
    var parentWork: String?
    /// Snapshots are authoritative, so only `working` and `waitingForUser`
    /// are meaningful here.
    var state: WorkState
}

/// One normalized observation. Adapters translate vendor events into this
/// shape; the shared model never parses vendor payloads.
struct ActivityEvent: Codable, Hashable {
    static let currentSchema = 1

    var schema: Int
    var id: String
    var source: String
    var activationGeneration: UInt64
    var target: String
    var owner: OwnerIdentity
    var session: SessionIdentity
    var transition: ActivityTransition
    var work: String?
    var generation: UInt64?
    var parentWork: String?
    var sequence: UInt64?
    var timestamp: Date
    var scope: SnapshotScope?
    var snapshotEntries: [SnapshotEntry]?
    /// True only when the adapter proved the snapshot listed every active work
    /// item in its scope. Omitted work from an incomplete snapshot is
    /// uncertain, never ended, and its gaps stay open.
    var snapshotComplete: Bool

    init(
        schema: Int = ActivityEvent.currentSchema,
        id: String,
        source: String,
        activationGeneration: UInt64,
        target: String = "",
        owner: OwnerIdentity,
        session: SessionIdentity,
        transition: ActivityTransition,
        work: String? = nil,
        generation: UInt64? = nil,
        parentWork: String? = nil,
        sequence: UInt64? = nil,
        timestamp: Date,
        scope: SnapshotScope? = nil,
        snapshotEntries: [SnapshotEntry]? = nil,
        snapshotComplete: Bool = false
    ) {
        self.schema = schema
        self.id = id
        self.source = source
        self.activationGeneration = activationGeneration
        self.target = target
        self.owner = owner
        self.session = session
        self.transition = transition
        self.work = work
        self.generation = generation
        self.parentWork = parentWork
        self.sequence = sequence
        self.timestamp = timestamp
        self.scope = scope
        self.snapshotEntries = snapshotEntries
        self.snapshotComplete = snapshotComplete
    }

    private enum CodingKeys: String, CodingKey {
        case schema, id, source, activationGeneration, target, owner, session
        case transition, work, generation, parentWork, sequence, timestamp
        case scope, snapshotEntries, snapshotComplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schema: try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema,
            id: try container.decode(String.self, forKey: .id),
            source: try container.decode(String.self, forKey: .source),
            activationGeneration: try container.decode(UInt64.self, forKey: .activationGeneration),
            target: try container.decodeIfPresent(String.self, forKey: .target) ?? "",
            owner: try container.decode(OwnerIdentity.self, forKey: .owner),
            session: try container.decode(SessionIdentity.self, forKey: .session),
            transition: try container.decode(ActivityTransition.self, forKey: .transition),
            work: try container.decodeIfPresent(String.self, forKey: .work),
            generation: try container.decodeIfPresent(UInt64.self, forKey: .generation),
            parentWork: try container.decodeIfPresent(String.self, forKey: .parentWork),
            sequence: try container.decodeIfPresent(UInt64.self, forKey: .sequence),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            scope: try container.decodeIfPresent(SnapshotScope.self, forKey: .scope),
            snapshotEntries: try container.decodeIfPresent([SnapshotEntry].self, forKey: .snapshotEntries),
            snapshotComplete: try container.decodeIfPresent(Bool.self, forKey: .snapshotComplete) ?? false
        )
    }
}

// MARK: - Observation gaps

enum GapReason: String, Codable, CaseIterable {
    /// An adapter reported that it stopped observing.
    case observerLost
    /// An event could not be parsed or validated.
    case eventRejected
    /// The inbox exceeded its file bound.
    case storageOverflow
    /// The model reached its work bound and could not record new work.
    case capacityExceeded
}

struct GapKey: Codable, Hashable {
    var family: String
    var instance: String
    /// `nil` means the whole instance is unobserved.
    var session: String?
}

struct ObservationGap: Codable, Hashable {
    var family: String
    var instance: String
    var session: String?
    var reasons: Set<GapReason>
    /// Event time of the first loss this gap records; never a local clock read.
    var detectedAt: Date
}

// MARK: - Model

struct WorkRecord: Codable, Hashable {
    var identity: WorkIdentity
    var parentWork: String?
    var owner: OwnerIdentity
    var state: WorkState
    var lastSequence: UInt64?
    var updatedAt: Date
}

enum ApplyOutcome: Equatable {
    case applied
    case duplicate
    case ignored(IgnoreReason)
}

enum IgnoreReason: String, Equatable {
    case unsupportedSchema
    case invalidEvent
    case inactiveSource
    case staleActivation
    case ownerMismatch
    case unknownWork
    case staleSequence
    case staleTimestamp
    case terminalWork
    case capacityExceeded
    case invalidSnapshot
}

enum AggregateState: String, Codable {
    /// Confirmed unfinished work exists. Hold the sleep assertion.
    case working
    /// Previously confirmed unfinished work lost observation. Hold until
    /// reliable completion, state recovery, or confirmed termination.
    case uncertain
    /// Progress requires a person; no other work is active.
    case waitingForUser
    /// Observation is incomplete but no unfinished work was confirmed.
    /// Allow sleep, and never present this as confirmed idle.
    case unknown
    /// Absence of work was confirmed.
    case idle
}

struct AggregateDecision: Equatable {
    var state: AggregateState
    var holdAssertion: Bool
    var reasons: [String]
}

/// Pure reducer state. It owns work identity, transitions, deduplication,
/// uncertainty, and the aggregate sleep decision. It performs no I/O and
/// never parses vendor payloads.
struct ActivityModel: Codable {
    static let currentSchema = 1

    /// Bounds keep weeks of observation from growing without limit.
    ///
    /// The dedup ring must cover one reconcile pass (512 events) plus the
    /// retained terminal facts (512), so the constant stays at 2048.
    static let maxRecentEventIDs = 2048
    static let maxWorks = 1024
    static let maxTerminalWorks = 512
    static let maxGaps = 1024

    private(set) var activeGenerations: [String: UInt64]
    private(set) var works: [WorkIdentity: WorkRecord]
    private(set) var gaps: [GapKey: ObservationGap]
    private(set) var recentEventIDs: [String]

    /// Derived from `recentEventIDs`; not persisted separately.
    private var recentIDSet: Set<String>

    init() {
        activeGenerations = [:]
        works = [:]
        gaps = [:]
        recentEventIDs = []
        recentIDSet = []
    }

    // MARK: Activation

    /// A reinstall always receives a new generation, so events from hooks that
    /// were already in flight under the previous installation are rejected.
    mutating func activate(family: String, generation: UInt64) {
        if let current = activeGenerations[family], current != generation {
            deactivate(family: family)
        }
        activeGenerations[family] = generation
    }

    /// Removal excludes the package from the model. A late event from an old
    /// hook cannot restore its contribution, even after a later reinstall.
    mutating func deactivate(family: String) {
        activeGenerations.removeValue(forKey: family)
        let workKeys = works.keys.filter { $0.session.family == family }
        for key in workKeys { works.removeValue(forKey: key) }
        let gapKeys = gaps.keys.filter { $0.family == family }
        for key in gapKeys { gaps.removeValue(forKey: key) }
    }

    // MARK: Apply

    mutating func apply(_ event: ActivityEvent) -> ApplyOutcome {
        let key = Self.dedupKey(for: event)

        guard event.schema == Self.currentSchema else {
            return .ignored(.unsupportedSchema)
        }
        guard !recentIDSet.contains(key) else {
            return .duplicate
        }
        // Owner identity names the observed instance. Mismatching instances
        // cannot be reconciled into one session.
        guard event.session.family == event.source,
              event.owner.instance == event.session.instance else {
            return .ignored(.invalidEvent)
        }
        guard let active = activeGenerations[event.source] else {
            return .ignored(.inactiveSource)
        }
        guard active == event.activationGeneration else {
            return .ignored(.staleActivation)
        }

        let outcome: ApplyOutcome
        switch event.transition {
        case .snapshot:
            outcome = applySnapshot(event)
        case .observationLost:
            let session = event.scope == .instance ? nil : event.session.session
            recordGap(
                family: event.source,
                instance: event.session.instance,
                session: session,
                reason: .observerLost,
                at: event.timestamp
            )
            outcome = .applied
        case .heartbeat:
            outcome = applyHeartbeat(event)
        case .ownerTerminated:
            outcome = applyOwnerTerminated(event)
        case .started, .childStarted:
            outcome = applyStart(event)
        case .humanWait, .resumed, .completed, .failed, .cancelled, .childFinished:
            outcome = applyUpdate(event)
        }

        // Only an event that changed state is remembered. Rejections must stay
        // replayable when a later gate (activation, snapshot) changes.
        if outcome == .applied {
            remember(key)
        }
        return outcome
    }

    /// Records an observation gap and turns affected active work uncertain.
    /// An unrelated new task cannot clear the gap; only an authoritative
    /// snapshot covering the same scope, or package removal, does.
    mutating func recordGap(
        family: String,
        instance: String,
        session: String?,
        reason: GapReason,
        at date: Date
    ) {
        // Bound the gap table before inserting: collapse the scopes that free
        // the most entries, so one noisy adapter cannot evict every other
        // instance's losses. When every scope holds a single gap there is
        // nothing to collapse, so the two oldest losses pair up instead and
        // the bound still holds.
        while gaps.count >= Self.maxGaps {
            if let scope = densestGapScope(), scope.count > 1 {
                mergeGaps(family: scope.family, instance: scope.instance)
                continue
            }
            guard mergeTwoOldestGaps() else { break }
        }

        let key = GapKey(family: family, instance: instance, session: session)
        var gap = gaps[key] ?? ObservationGap(
            family: family,
            instance: instance,
            session: session,
            reasons: [],
            detectedAt: date
        )
        gap.reasons.insert(reason)
        gap.detectedAt = min(gap.detectedAt, date)
        gaps[key] = gap

        let affected = works.keys.filter { identity in
            guard identity.session.family == family, identity.session.instance == instance else { return false }
            if let session, identity.session.session != session { return false }
            return works[identity]?.state.isActive == true
        }
        for identity in affected {
            works[identity]?.state = .uncertain
            works[identity]?.updatedAt = date
        }
    }

    /// Holds work observed under a previous boot as uncertain until its
    /// termination is verified. Owner and freshness stay untouched.
    mutating func retireForeignBoots(currentBootID: String) {
        let affected = works
            .filter { $0.value.state.isActive && $0.value.owner.bootID != currentBootID }
            .map(\.key)
        for identity in affected {
            works[identity]?.state = .uncertain
        }
    }

    // MARK: Decision

    var decision: AggregateDecision {
        let active = works.values.filter { $0.state.isActive }

        let working = active.filter { $0.state == .working }
        if !working.isEmpty {
            return AggregateDecision(
                state: .working,
                holdAssertion: true,
                reasons: sortedReasons(reasonEntries(for: working))
            )
        }

        let uncertain = active.filter { $0.state == .uncertain }
        if !uncertain.isEmpty {
            return AggregateDecision(
                state: .uncertain,
                holdAssertion: true,
                reasons: sortedReasons(reasonEntries(for: uncertain))
            )
        }

        let waiting = active.filter { $0.state == .waitingForUser }

        // A gap outranks a wait: incomplete observation is never confirmed
        // idle, and the reasons still name the waiting work.
        if !gaps.isEmpty {
            let entries = gapReasons() + reasonEntries(for: waiting)
            return AggregateDecision(
                state: .unknown,
                holdAssertion: false,
                reasons: sortedReasons(entries)
            )
        }

        if !waiting.isEmpty {
            return AggregateDecision(
                state: .waitingForUser,
                holdAssertion: false,
                reasons: sortedReasons(reasonEntries(for: waiting))
            )
        }

        return AggregateDecision(state: .idle, holdAssertion: false, reasons: [])
    }

    // MARK: Snapshot

    private mutating func applySnapshot(_ event: ActivityEvent) -> ApplyOutcome {
        guard let scope = event.scope, let entries = event.snapshotEntries else {
            return .ignored(.invalidSnapshot)
        }
        guard entries.count <= Self.maxWorks else {
            recordGap(
                family: event.source,
                instance: event.session.instance,
                session: nil,
                reason: .capacityExceeded,
                at: event.timestamp
            )
            return .ignored(.invalidSnapshot)
        }
        guard entries.allSatisfy({ entry in
            entry.session.family == event.source
                && (entry.state == .working || entry.state == .waitingForUser)
        }) else {
            return .ignored(.invalidSnapshot)
        }

        // `covered` names the sessions in which omitted work is reconciled.
        // `cleared` names the gaps the snapshot proves are gone; `nil` clears
        // every gap of the instance, an empty set clears none.
        let covered: Set<String>
        let cleared: Set<String>?
        switch scope {
        case .session:
            guard entries.allSatisfy({
                $0.session.instance == event.session.instance && $0.session.session == event.session.session
            }) else { return .ignored(.invalidSnapshot) }
            covered = [event.session.session]
            cleared = event.snapshotComplete ? [event.session.session] : []
        case .instance:
            guard entries.allSatisfy({ $0.session.instance == event.session.instance }) else {
                return .ignored(.invalidSnapshot)
            }
            if event.snapshotComplete {
                covered = Set(
                    works.keys
                        .filter { $0.session.family == event.source && $0.session.instance == event.session.instance }
                        .map { $0.session.session }
                )
                cleared = nil
            } else {
                // Only the sessions this snapshot actually listed are
                // reconciled; other sessions and the instance gap stay open.
                covered = Set(entries.map { $0.session.session })
                cleared = covered
            }
        }

        let entryKeys = Set(entries.map {
            WorkIdentity(session: $0.session, generation: $0.generation, work: $0.work)
        })

        // Works the snapshot omits are no longer active, but only when the
        // snapshot is complete: otherwise they become uncertain. A record
        // newer than the snapshot is never ended by it.
        let omittedState: WorkState = event.snapshotComplete ? .ended : .uncertain
        let omitted = works.keys.filter { identity in
            guard identity.session.family == event.source,
                  identity.session.instance == event.session.instance,
                  covered.contains(identity.session.session) else { return false }
            guard let record = works[identity], record.state.isActive else { return false }
            guard !entryKeys.contains(identity) else { return false }
            return record.updatedAt <= event.timestamp
        }
        for identity in omitted {
            works[identity]?.state = omittedState
            works[identity]?.updatedAt = event.timestamp
        }

        for entry in entries {
            let identity = WorkIdentity(session: entry.session, generation: entry.generation, work: entry.work)
            if let existing = works[identity] {
                // A snapshot older than the fact it describes proves nothing.
                guard existing.updatedAt <= event.timestamp else { continue }
                // A live record owned by another process cannot be overwritten
                // by this snapshot; the conflict is a loss of observation.
                if existing.state.isActive, existing.owner != event.owner {
                    works[identity]?.state = .uncertain
                    continue
                }
            }
            works[identity] = WorkRecord(
                identity: identity,
                parentWork: entry.parentWork,
                owner: event.owner,
                state: entry.state,
                lastSequence: event.sequence,
                updatedAt: event.timestamp
            )
        }

        clearGaps(
            family: event.source,
            instance: event.session.instance,
            sessions: cleared,
            notAfter: event.timestamp
        )
        pruneTerminal()
        if works.count > Self.maxWorks {
            recordGap(
                family: event.source,
                instance: event.session.instance,
                session: nil,
                reason: .capacityExceeded,
                at: event.timestamp
            )
        }
        return .applied
    }

    /// Clears gaps the snapshot proves are gone. A snapshot can only speak for
    /// losses it observed: a gap detected after the snapshot's own timestamp
    /// stays open.
    private mutating func clearGaps(
        family: String,
        instance: String,
        sessions: Set<String>?,
        notAfter: Date
    ) {
        let keys = gaps.keys.filter { key in
            guard key.family == family, key.instance == instance else { return false }
            guard let gap = gaps[key], gap.detectedAt <= notAfter else { return false }
            guard let sessions else { return true }
            guard let gapSession = key.session else { return false }
            return sessions.contains(gapSession)
        }
        for key in keys { gaps.removeValue(forKey: key) }
    }

    // MARK: Transitions

    private mutating func applyStart(_ event: ActivityEvent) -> ApplyOutcome {
        guard let identity = workIdentity(event) else { return .ignored(.invalidEvent) }

        if var record = works[identity] {
            // `ended` is a snapshot statement, not a completion fact: a later
            // start of the same work revives it. Every other terminal state
            // stays closed.
            let revivable = record.state == .ended
            guard !record.state.isTerminal || revivable else { return .ignored(.terminalWork) }
            guard record.owner == event.owner else { return .ignored(.ownerMismatch) }
            guard event.timestamp >= record.updatedAt else { return .ignored(.staleTimestamp) }
            if isStale(event.sequence, than: record.lastSequence) {
                return .ignored(.staleSequence)
            }
            record.state = .working
            record.lastSequence = event.sequence ?? record.lastSequence
            record.updatedAt = event.timestamp
            works[identity] = record
            return .applied
        }

        guard makeRoom(for: event) else { return .ignored(.capacityExceeded) }
        works[identity] = WorkRecord(
            identity: identity,
            parentWork: event.parentWork,
            owner: event.owner,
            state: .working,
            lastSequence: event.sequence,
            updatedAt: event.timestamp
        )
        return .applied
    }

    private mutating func applyUpdate(_ event: ActivityEvent) -> ApplyOutcome {
        guard let identity = workIdentity(event) else { return .ignored(.invalidEvent) }
        guard var record = works[identity] else { return .ignored(.unknownWork) }
        let revivable = record.state == .ended && event.transition == .resumed
        guard !record.state.isTerminal || revivable else { return .ignored(.terminalWork) }
        guard record.owner == event.owner else { return .ignored(.ownerMismatch) }
        guard event.timestamp >= record.updatedAt else { return .ignored(.staleTimestamp) }
        if isStale(event.sequence, than: record.lastSequence) {
            return .ignored(.staleSequence)
        }

        switch event.transition {
        case .humanWait:
            record.state = .waitingForUser
        case .resumed:
            record.state = .working
        case .completed, .childFinished:
            record.state = .completed
        case .failed:
            record.state = .failed
        case .cancelled:
            record.state = .cancelled
        default:
            return .ignored(.invalidEvent)
        }

        record.lastSequence = event.sequence ?? record.lastSequence
        record.updatedAt = event.timestamp
        works[identity] = record
        pruneTerminal()
        return .applied
    }

    /// Confirms observer liveness only. It never changes work state.
    private mutating func applyHeartbeat(_ event: ActivityEvent) -> ApplyOutcome {
        guard let identity = workIdentity(event) else { return .ignored(.invalidEvent) }
        guard var record = works[identity] else { return .ignored(.unknownWork) }
        guard !record.state.isTerminal else { return .ignored(.terminalWork) }
        guard record.owner == event.owner else { return .ignored(.ownerMismatch) }
        // Freshness never moves backwards on a late heartbeat.
        if event.timestamp > record.updatedAt {
            record.updatedAt = event.timestamp
            works[identity] = record
        }
        return .applied
    }

    /// Verified owner termination retires exactly that owner's work. Work
    /// owned by any other process stays accounted for.
    private mutating func applyOwnerTerminated(_ event: ActivityEvent) -> ApplyOutcome {
        let affected = works
            .filter { $0.value.state.isActive && $0.value.owner == event.owner }
            .map(\.key)
        for identity in affected {
            works[identity]?.state = .ended
            works[identity]?.updatedAt = event.timestamp
        }
        pruneTerminal()
        return .applied
    }

    // MARK: Bounds and helpers

    private mutating func makeRoom(for event: ActivityEvent) -> Bool {
        pruneTerminal()
        guard works.count >= Self.maxWorks else { return true }
        recordGap(
            family: event.source,
            instance: event.session.instance,
            session: nil,
            reason: .capacityExceeded,
            at: event.timestamp
        )
        return false
    }

    private mutating func pruneTerminal() {
        let terminal = works.filter { $0.value.state.isTerminal }
        guard terminal.count > Self.maxTerminalWorks else { return }
        let overflow = terminal
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(terminal.count - Self.maxTerminalWorks)
        for entry in overflow { works.removeValue(forKey: entry.key) }
    }

    /// Collapses every gap of one family and instance into a single
    /// instance-wide gap. Reasons are unioned and the earliest detection time
    /// is kept, so narrowing to the instance loses no fact.
    private mutating func mergeGaps(family: String, instance: String) {
        let matching = gaps.filter { $0.key.family == family && $0.key.instance == instance }
        guard let earliest = matching.values.map(\.detectedAt).min() else { return }
        var merged = ObservationGap(
            family: family,
            instance: instance,
            session: nil,
            reasons: [],
            detectedAt: earliest
        )
        for gap in matching.values {
            merged.reasons.formUnion(gap.reasons)
            merged.detectedAt = min(merged.detectedAt, gap.detectedAt)
        }
        for key in matching.keys { gaps.removeValue(forKey: key) }
        gaps[GapKey(family: family, instance: instance, session: nil)] = merged
    }

    /// Pairs the two oldest losses into the older one's instance-wide gap.
    /// Used when no scope holds more than one gap, so the bound still holds
    /// without dropping any reason. Returns false when there is nothing left
    /// to merge.
    private mutating func mergeTwoOldestGaps() -> Bool {
        let ordered = gaps.sorted { lhs, rhs in
            (lhs.value.detectedAt, lhs.key.family, lhs.key.instance, lhs.key.session ?? "")
                < (rhs.value.detectedAt, rhs.key.family, rhs.key.instance, rhs.key.session ?? "")
        }
        guard ordered.count >= 2 else { return false }

        let older = ordered[0]
        let newer = ordered[1]
        gaps.removeValue(forKey: older.key)
        gaps.removeValue(forKey: newer.key)

        let destination = GapKey(family: older.key.family, instance: older.key.instance, session: nil)
        var merged = gaps[destination] ?? ObservationGap(
            family: older.key.family,
            instance: older.key.instance,
            session: nil,
            reasons: [],
            detectedAt: older.value.detectedAt
        )
        merged.reasons.formUnion(older.value.reasons)
        merged.reasons.formUnion(newer.value.reasons)
        merged.detectedAt = min(merged.detectedAt, older.value.detectedAt, newer.value.detectedAt)
        gaps[destination] = merged
        return true
    }

    /// The family and instance holding the most gaps, so collapsing it frees
    /// the most room. Ties go to the oldest loss, then to the identifiers, so
    /// the choice never depends on dictionary order.
    private func densestGapScope() -> (family: String, instance: String, count: Int)? {
        var grouping: [GapKey: (count: Int, earliest: Date)] = [:]
        for (key, gap) in gaps {
            let scope = GapKey(family: key.family, instance: key.instance, session: nil)
            if var entry = grouping[scope] {
                entry.count += 1
                entry.earliest = min(entry.earliest, gap.detectedAt)
                grouping[scope] = entry
            } else {
                grouping[scope] = (1, gap.detectedAt)
            }
        }
        let best = grouping.min { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            if lhs.value.earliest != rhs.value.earliest { return lhs.value.earliest < rhs.value.earliest }
            return (lhs.key.family, lhs.key.instance) < (rhs.key.family, rhs.key.instance)
        }
        guard let best else { return nil }
        return (best.key.family, best.key.instance, best.value.count)
    }

    private mutating func remember(_ id: String) {
        recentEventIDs.append(id)
        recentIDSet.insert(id)
        if recentEventIDs.count > Self.maxRecentEventIDs {
            let overflow = recentEventIDs.count - Self.maxRecentEventIDs
            for removed in recentEventIDs.prefix(overflow) {
                recentIDSet.remove(removed)
            }
            recentEventIDs.removeFirst(overflow)
        }
    }

    /// Event identity is scoped to its source and instance: the same opaque ID
    /// from two families names two different facts.
    private static func dedupKey(for event: ActivityEvent) -> String {
        "\(event.source)|\(event.session.instance)|\(event.id)"
    }

    private func workIdentity(_ event: ActivityEvent) -> WorkIdentity? {
        guard let work = event.work, let generation = event.generation else { return nil }
        return WorkIdentity(session: event.session, generation: generation, work: work)
    }

    private func isStale(_ sequence: UInt64?, than last: UInt64?) -> Bool {
        guard let sequence, let last else { return false }
        return sequence <= last
    }

    /// The text names every part of the work identity so two records can
    /// never produce the same reason string.
    private func describe(_ record: WorkRecord) -> String {
        let identity = record.identity
        return "\(identity.session.family)/\(identity.session.instance)/\(identity.session.session)"
            + "/\(identity.generation)/\(identity.work) is \(record.state.rawValue)"
    }

    // MARK: Reason ordering

    /// One decision reason with its deterministic sort key.
    private struct ReasonEntry {
        var family: String
        var instance: String
        var session: String
        var text: String
    }

    private func reasonEntries(for records: [WorkRecord]) -> [ReasonEntry] {
        records.map {
            ReasonEntry(
                family: $0.identity.session.family,
                instance: $0.identity.session.instance,
                session: $0.identity.session.session,
                text: describe($0)
            )
        }
    }

    private func gapReasons() -> [ReasonEntry] {
        gaps.values.map {
            ReasonEntry(
                family: $0.family,
                instance: $0.instance,
                session: $0.session ?? "",
                text: "no observation for \($0.family)/\($0.instance)/\($0.session ?? "*")"
            )
        }
    }

    /// Sorted order never depends on dictionary iteration, so a checkpoint
    /// round trip yields identical reasons.
    private func sortedReasons(_ entries: [ReasonEntry]) -> [String] {
        entries
            .sorted { ($0.family, $0.instance, $0.session, $0.text) < ($1.family, $1.instance, $1.session, $1.text) }
            .map(\.text)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case activeGenerations, works, gaps, recentEventIDs
    }

    /// Every key is required. A truncated checkpoint must fail to load instead
    /// of decoding as an empty, idle model.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeGenerations = try container.decode([String: UInt64].self, forKey: .activeGenerations)
        works = try container.decode([WorkIdentity: WorkRecord].self, forKey: .works)
        gaps = try container.decode([GapKey: ObservationGap].self, forKey: .gaps)
        recentEventIDs = try container.decode([String].self, forKey: .recentEventIDs)
        recentIDSet = Set(recentEventIDs)
    }
}
