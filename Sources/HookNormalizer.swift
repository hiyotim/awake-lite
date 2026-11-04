import Foundation

// MARK: - Vocabulary

/// One validated helper invocation: the emission contract minus the payload.
///
/// Argument parsing lives in `HelperRunner`; everything here has already passed
/// the family, target, generation, and event-shape checks.
struct HookInvocation: Equatable {
    var family: String
    var target: String
    var generation: UInt64
    var event: String

    /// Stamps one event with the fields the helper contract fixes: schema 1,
    /// this family, activation generation, and target, the injected owner and
    /// timestamp, and `snapshotComplete == false`.
    ///
    /// The adapter fills in the vendor-derived part. `HookNormalizer` re-stamps
    /// the invariant fields before writing, so an adapter cannot redirect an
    /// event to another family, generation, target, owner, or time.
    func makeEvent(
        owner: OwnerIdentity,
        timestamp: Date,
        session: String,
        transition: ActivityTransition,
        work: String? = nil,
        workGeneration: UInt64? = nil,
        parentWork: String? = nil,
        sequence: UInt64? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            schema: ActivityEvent.currentSchema,
            id: "",
            source: family,
            activationGeneration: generation,
            target: target,
            owner: owner,
            session: SessionIdentity(
                family: family,
                instance: owner.instance,
                session: session
            ),
            transition: transition,
            work: work,
            generation: workGeneration,
            parentWork: parentWork,
            sequence: sequence,
            timestamp: timestamp,
            snapshotComplete: false
        )
    }
}

/// Canonical form for the identifiers an event file name is built from.
///
/// Keeps `[A-Za-z0-9_-]`, replaces anything else with `_`, and caps at 64
/// characters. Adapters canonicalize vendor session, work, and parent-work
/// identifiers with `canonical(_:)`; the normalizer refuses a value that is not
/// already canonical, because two different vendor ids must never silently
/// collapse into one path component or one work record.
enum HookIdentifier {
    /// Longest identifier an event file name or work identity may carry.
    /// `EventFileName.sanitize` truncates at this bound, so a longer vendor id
    /// cannot be stored without losing characters.
    static let maxLength = 64

    static func canonical(_ value: String) -> String {
        EventFileName.sanitize(value)
    }

    static func isCanonical(_ value: String) -> Bool {
        !value.isEmpty && EventFileName.sanitize(value) == value
    }
}

// MARK: - Payload

/// One bounded vendor payload, readable by documented field name only.
///
/// The raw bytes stay inside this type: an adapter asks for the fields its
/// vendor contract documents and nothing else is reachable. Unknown keys are
/// never enumerated, copied, logged, or persisted, so a payload that carries a
/// prompt, a response, tool arguments, or a credential contributes the same
/// bytes to storage as a payload that does not contain them.
struct HookPayload {
    private let root: JSONValue?

    /// An absent payload, for hook events that carry no body.
    static let empty = HookPayload(root: nil)

    private init(root: JSONValue?) {
        self.root = root
    }

    var isEmpty: Bool { root == nil }

    /// Parses the optional stdin body.
    ///
    /// An empty body is `empty`; anything else must be exactly one JSON object.
    /// Oversize bytes are refused before parsing.
    static func parse(_ data: Data, maxBytes: Int) throws -> HookPayload {
        guard data.count <= maxBytes else {
            throw HookIngestError.payloadTooLarge(data.count)
        }
        guard !data.isEmpty else { return .empty }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw HookIngestError.malformedPayload("payload")
        }
        guard value.objectValue != nil else {
            throw HookIngestError.malformedPayload("payload")
        }
        return HookPayload(root: value)
    }

    // MARK: Documented field accessors

    func string(_ field: String) -> String? {
        fieldValue(field)?.stringValue
    }

    func uint64(_ field: String) -> UInt64? {
        guard let value = fieldValue(field),
              case .number(let number, let isInteger) = value,
              isInteger, number >= 0,
              number < 18_446_744_073_709_551_616.0
        else { return nil }
        return UInt64(number)
    }

    func bool(_ field: String) -> Bool? {
        fieldValue(field)?.boolValue
    }

    /// A nested object viewed as its own payload, for documented nested shapes.
    func object(_ field: String) -> HookPayload? {
        guard let value = fieldValue(field), value.objectValue != nil else { return nil }
        return HookPayload(root: value)
    }

    func requiredString(_ field: String) throws -> String {
        guard let value = string(field) else {
            throw HookIngestError.malformedPayload(field)
        }
        return value
    }

    func requiredUInt64(_ field: String) throws -> UInt64 {
        guard let value = uint64(field) else {
            throw HookIngestError.malformedPayload(field)
        }
        return value
    }

    private func fieldValue(_ field: String) -> JSONValue? {
        root?.objectValue?[field]
    }
}

// MARK: - Adapter protocol

/// One family's documented hook vocabulary.
///
/// An adapter lives in its own file under `Sources/Adapters/`, declares the
/// vendor event names it understands, and maps one documented payload shape to
/// one `ActivityEvent`. It never touches files, clocks, processes, networks, or
/// power: the normalizer supplies the owner, the time, and the store.
protocol HookAdapter {
    /// Install family this adapter serves, exactly as in the manifest and in
    /// the receipt file name.
    var family: String { get }

    /// Documented vendor event names. An `--event` outside this set is refused
    /// before the payload is read.
    var eventNames: Set<String> { get }

    /// Maps one documented payload shape to one event.
    ///
    /// Build the result with `HookInvocation.makeEvent(...)`. Throw
    /// `HookIngestError.malformedPayload(field)` when a documented field is
    /// missing or has the wrong type, naming the field only.
    func event(
        for invocation: HookInvocation,
        payload: HookPayload,
        owner: OwnerIdentity,
        now: Date
    ) throws -> ActivityEvent
}

// MARK: - Errors

/// Why an emission produced no event file.
///
/// Messages carry field names, flag names, and paths only. No payload byte ever
/// reaches an error, a diagnostic line, or a persisted file.
enum HookIngestError: Error, Equatable {
    /// Exit 2: the invocation does not match the helper contract.
    case invalidUsage(String)
    case unknownFamily(String)
    case unknownEvent(String)
    case malformedPayload(String)
    case payloadTooLarge(Int)
    /// Exit 3: nothing was written and no directory was created.
    case inactiveFamily(family: String, receiptPath: String)
    /// Exit 3: the receipts or journals could not be read, so activation
    /// cannot be decided. Distinct from a missing receipt: the install state
    /// itself is unavailable, and the path names that state rather than a
    /// receipt the family does not own.
    case activationUnavailable(path: String)
    case staleGeneration(requested: UInt64, installed: UInt64)
    /// Exit 4: the event store refused the write.
    case storage(String)
}

// MARK: - Normalizer

/// Turns one documented hook emission into exactly one immutable event file.
///
/// Order is part of the contract:
///
/// 1. the family has a registered adapter and the vendor event name is in its
///    allowlist (exit 2 otherwise),
/// 2. the family is active at the requested activation generation, decided from
///    committed receipts and unresolved journals only (exit 3 otherwise),
/// 3. the stdin body is bounded and must be one JSON object (exit 2),
/// 4. the adapter reads its documented fields and returns one event (exit 2),
/// 5. the event is re-stamped, validated, and written through
///    `LocalEventStore.enqueue` (exit 4 on a storage failure).
///
/// Activation is decided before a payload byte is parsed and before storage is
/// touched, so an inactive family cannot create a directory, a lock, or a file.
struct HookNormalizer {
    /// Accepted stdin body size for one emission. The helper's stdin reader and
    /// this normalizer share the same bound, so a body that reaches the adapter
    /// is always within it.
    static let maxPayloadBytes = 64 * 1024

    struct Limits: Equatable {
        var maxPayloadBytes = HookNormalizer.maxPayloadBytes
        var storeLimits = LocalEventStore.Limits()
    }

    let appSupportRoot: URL
    var adapters: [HookAdapter]
    var limits: Limits

    init(
        appSupportRoot: URL,
        adapters: [HookAdapter] = HookAdapterRegistry.all,
        limits: Limits = Limits()
    ) {
        self.appSupportRoot = appSupportRoot
        self.adapters = adapters
        self.limits = limits
    }

    func adapter(for family: String) -> HookAdapter? {
        HookAdapterRegistry.adapter(for: family, in: adapters)
    }

    func receiptPath(for family: String) -> String {
        appSupportRoot
            .appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent("\(family).json")
            .path
    }

    /// Full ingress for one emission.
    @discardableResult
    func ingest(
        invocation: HookInvocation,
        payload: Data,
        owner: OwnerIdentity,
        now: Date
    ) throws -> ActivityEvent {
        guard let adapter = adapter(for: invocation.family) else {
            throw HookIngestError.unknownFamily(invocation.family)
        }
        guard adapter.eventNames.contains(invocation.event) else {
            throw HookIngestError.unknownEvent(invocation.event)
        }

        try verifyActive(family: invocation.family, generation: invocation.generation)

        let parsed = try HookPayload.parse(payload, maxBytes: limits.maxPayloadBytes)
        var event: ActivityEvent
        do {
            event = try adapter.event(
                for: invocation,
                payload: parsed,
                owner: owner,
                now: now
            )
        } catch let error as HookIngestError {
            throw error
        } catch {
            // A vendor parser's error text is never repeated: it could quote the
            // payload. Only the field name survives.
            throw HookIngestError.malformedPayload("payload")
        }

        Self.stamp(&event, invocation: invocation, owner: owner, now: now)
        try Self.validate(event)
        try write(event)
        return event
    }

    // MARK: Activation

    private func verifyActive(family: String, generation: UInt64) throws {
        let state: ActivationState
        do {
            state = try ActivationHandoff(appSupportRoot: appSupportRoot).readState()
        } catch {
            // Unreadable install state cannot prove activation. Fail closed,
            // but report the state path rather than a receipt path: the family
            // may own a perfectly healthy receipt while another file in the
            // same tree is corrupt, and a missing receipt is a different fact.
            throw HookIngestError.activationUnavailable(path: appSupportRoot.path)
        }
        guard let installed = state.generation(for: family) else {
            throw HookIngestError.inactiveFamily(
                family: family,
                receiptPath: receiptPath(for: family)
            )
        }
        guard installed == generation else {
            throw HookIngestError.staleGeneration(
                requested: generation,
                installed: installed
            )
        }
    }

    // MARK: Stamping and validation

    /// Re-stamps every field the helper contract fixes, whatever the adapter
    /// returned, and assigns the per-emission event id.
    private static func stamp(
        _ event: inout ActivityEvent,
        invocation: HookInvocation,
        owner: OwnerIdentity,
        now: Date
    ) {
        event.schema = ActivityEvent.currentSchema
        event.id = makeEventID(now: now)
        event.source = invocation.family
        event.activationGeneration = invocation.generation
        event.target = invocation.target
        event.owner = owner
        event.session.family = invocation.family
        event.session.instance = owner.instance
        event.timestamp = now
        event.snapshotComplete = false
    }

    /// Unique per emission and canonical, so `LocalEventStore.enqueue` accepts
    /// it unaliased.
    static func makeEventID(now: Date, nonce: UUID = UUID()) -> String {
        let micros = UInt64(max(0, (now.timeIntervalSince1970 * 1_000_000).rounded(.down)))
        let tail = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "h\(String(micros, radix: 16))-\(tail)"
    }

    private static func validate(_ event: ActivityEvent) throws {
        guard HookIdentifier.isCanonical(event.session.session) else {
            throw HookIngestError.malformedPayload("session")
        }
        if let work = event.work, !HookIdentifier.isCanonical(work) {
            throw HookIngestError.malformedPayload("work")
        }
        if let parent = event.parentWork, !HookIdentifier.isCanonical(parent) {
            throw HookIngestError.malformedPayload("parentWork")
        }
    }

    // MARK: Write

    private func write(_ event: ActivityEvent) throws {
        let store = LocalEventStore(root: appSupportRoot, limits: limits.storeLimits)
        do {
            try store.enqueue(event)
        } catch let error as StoreError {
            throw HookIngestError.storage(Self.describe(error))
        } catch {
            throw HookIngestError.storage("the event store refused the write")
        }
    }

    private static func describe(_ error: StoreError) -> String {
        switch error {
        case .writeFailed(let detail):
            return detail
        case .posix(let code):
            return String(cString: strerror(code))
        case .invalidIdentifier:
            return "the event carries a non-canonical identifier"
        case .eventTooLarge:
            return "the event exceeds the stored event size bound"
        case .locked:
            return "the event store is locked by another process"
        case .invalidCheckpoint(let path):
            return "unreadable checkpoint at \(path)"
        case .unsupportedCheckpoint(let path, _):
            return "unsupported checkpoint at \(path)"
        }
    }
}

// MARK: - Registry

/// The single place that maps a family to its adapter.
///
/// Vendor event names and payload shapes stay in the adapter files; nothing in
/// the shared core knows them. One entry per install family: Codex serves both
/// `codex.cli` and `codex.desktop` from one adapter (it reads the target from
/// the invocation), so it must not appear twice. Add a new family only here.
enum HookAdapterRegistry {
    static let all: [HookAdapter] = [
        PiAdapter(),
        OMPAdapter(),
        CodexAdapter()
    ]

    static func adapter(for family: String, in adapters: [HookAdapter] = all) -> HookAdapter? {
        adapters.first { $0.family == family }
    }
}
