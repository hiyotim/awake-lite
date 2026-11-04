import Foundation

// MARK: - Documented service surface

/// Paths of the documented OpenCode V2 HTTP surface.
///
/// Source: the OpenCode V2 HTTP API reference (`/v2/openapi.json`,
/// `opencode HttpApi` version 0.0.1). Only these four reads are used:
///
/// | Path | Documented meaning |
/// | --- | --- |
/// | `GET /api/session/active` | `{ "data": { "<ses…>": SessionActive } }`; sessions absent from the result are inactive. |
/// | `GET /api/session/{sessionID}` | `{ "data": Session.Info }`; carries the last execution `outcome` (`succeeded`, `failed`, `interrupted`) when one finished. |
/// | `GET /api/session/{sessionID}/permission` | `{ "data": [Permission.Request] }` pending human approvals. |
/// | `GET /api/session/{sessionID}/form` | `{ "data": [Form.Info] }` pending human forms. |
///
/// `SessionActive` is documented as `{ "type": "running" }`; the only inactive
/// value this connector accepts is `"idle"`. Any other type is a value the
/// published surface does not describe, so it is unreadable rather than
/// optimistically treated as finished. `/api/session/active` has no pagination
/// in the published specification, so one successful listing is the whole
/// page. If a later version pages it, this connector cannot prove coverage and
/// must be revised rather than assumed complete.
enum OpenCodeService {
    static let activeSessionsPath = "/api/session/active"

    static func sessionPath(_ sessionID: String) -> String {
        "/api/session/" + escapedPathComponent(sessionID)
    }

    static func permissionsPath(_ sessionID: String) -> String {
        sessionPath(sessionID) + "/permission"
    }

    static func formsPath(_ sessionID: String) -> String {
        sessionPath(sessionID) + "/form"
    }

    /// Session identifiers documented as `^ses`; the connector additionally
    /// bounds length and character set because the value becomes both a URL
    /// component and a normalized event field. A value that fails this check is
    /// never put in a path or an event; the observation becomes uncertain.
    static func isUsableSessionIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("ses"), !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return (0x30...0x39).contains(code)
                || (0x41...0x5A).contains(code)
                || (0x61...0x7A).contains(code)
                || code == 0x5F || code == 0x2D || code == 0x2E
        }
    }

    /// Percent-encodes every character outside the unreserved set, so a
    /// documented identifier cannot add path segments or a query.
    private static func escapedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Transport

/// Why a transport read produced no HTTP response.
///
/// The cases are fixed tokens on purpose: a `URLSession` error description can
/// repeat request details, so no error text ever crosses this boundary.
enum OpenCodeTransportFailure: String, Equatable, Error {
    case unreachable
    case timedOut
    case cancelled
    case other
}

struct OpenCodeHTTPResponse: Equatable {
    var status: Int
    var body: Data
}

enum OpenCodeTransportResult: Equatable {
    case response(OpenCodeHTTPResponse)
    case failure(OpenCodeTransportFailure)
}

/// One injectable read of the local service.
///
/// The adapter never constructs a transport of its own except through
/// `URLSessionOpenCodeTransport`; tests supply a fixture transport, so no check
/// performs a network request or needs a running service.
protocol OpenCodeTransport {
    func get(_ path: String) async -> OpenCodeTransportResult
}

/// Incremental bound on a response body the production transport is reading.
///
/// The transport reads the body in chunks and stops as soon as the bound is
/// passed, so a service that answers with an unbounded body cannot make the
/// connector allocate it. One byte past the limit is kept so the adapter's own
/// `body.count <= maxResponseBytes` check still refuses the response as
/// malformed instead of decoding a truncated body.
struct OpenCodeBodyBudget {
    /// Bytes read per streaming step before the budget is consulted.
    static let chunkBytes = 16 * 1024

    let limit: Int
    private(set) var data = Data()
    private(set) var exceededLimit = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Keeps at most `limit + 1` bytes. Once more has arrived, nothing further
    /// is stored and `exceededLimit` stays true.
    mutating func append(_ bytes: [UInt8]) {
        guard !exceededLimit else { return }
        let room = limit + 1 - data.count
        guard room > 0 else {
            exceededLimit = true
            return
        }
        if bytes.count > room {
            data.append(contentsOf: bytes.prefix(room))
            exceededLimit = true
        } else {
            data.append(contentsOf: bytes)
            if data.count > limit { exceededLimit = true }
        }
    }
}

/// Production transport for the user's existing local service.
///
/// It performs one bounded GET per call. It starts no timer, thread, retry
/// loop, or background task: scheduling belongs to Stage 5, gated on package
/// activation. Authorization is attached as a header value supplied by the
/// caller and is never stored in an event, an error, or a description.
///
/// The body is streamed rather than buffered whole: bytes are counted as they
/// arrive and reading stops at `OpenCodeAdapter.maxResponseBytes + 1`. Ending
/// iteration releases the byte stream, which cancels the request's transfer,
/// so a large or endless body is never accumulated in memory.
///
/// Not used by any test.
struct URLSessionOpenCodeTransport: OpenCodeTransport {
    static let requestTimeout: TimeInterval = 5

    let baseURL: URL
    let session: URLSession
    private let authorization: @Sendable () -> String?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        authorization: @escaping @Sendable () -> String? = { nil }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authorization = authorization
    }

    func get(_ path: String) async -> OpenCodeTransportResult {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            return .failure(.other)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let header = authorization() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }

        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.other) }
            // A non-success response is classified by status alone; its body is
            // never read, so it cannot carry bytes into memory or an outcome.
            guard http.statusCode == 200 else {
                return .response(OpenCodeHTTPResponse(status: http.statusCode, body: Data()))
            }

            var budget = OpenCodeBodyBudget(limit: OpenCodeAdapter.maxResponseBytes)
            var chunk = [UInt8]()
            chunk.reserveCapacity(OpenCodeBodyBudget.chunkBytes)
            for try await byte in stream {
                chunk.append(byte)
                if chunk.count == OpenCodeBodyBudget.chunkBytes {
                    budget.append(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    if budget.exceededLimit { break }
                }
            }
            if !budget.exceededLimit, !chunk.isEmpty { budget.append(chunk) }
            return .response(OpenCodeHTTPResponse(status: http.statusCode, body: budget.data))
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return .failure(.timedOut)
            case .cancelled: return .failure(.cancelled)
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                return .failure(.unreachable)
            default:
                return .failure(.other)
            }
        } catch {
            return .failure(.other)
        }
    }
}

extension URLSessionOpenCodeTransport: CustomStringConvertible {
    /// Fully redacted: neither the authorization value nor a URL that could
    /// carry request details reaches a log or an error description.
    var description: String {
        "URLSessionOpenCodeTransport(<redacted>)"
    }
}

// MARK: - Endpoint

enum OpenCodeConfigurationError: Error, Equatable {
    case notVerifiedLocalEndpoint
    case invalidInstance
    case ownerInstanceMismatch
    case invalidTarget
    case invalidEntryLimit
    case invalidByteLimit
}

extension OpenCodeConfigurationError: LocalizedError, CustomStringConvertible {
    /// Fixed text. No URL, path, header, or payload value is interpolated.
    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notVerifiedLocalEndpoint:
            return "the OpenCode endpoint is not a verified local endpoint"
        case .invalidInstance:
            return "the OpenCode adapter instance is not a canonical identifier"
        case .ownerInstanceMismatch:
            return "the OpenCode owner instance does not match the adapter instance"
        case .invalidTarget:
            return "the OpenCode target identifier is empty"
        case .invalidEntryLimit:
            return "the OpenCode snapshot entry limit is outside 1...ActivityModel.maxWorks"
        case .invalidByteLimit:
            return "the OpenCode snapshot byte limit is not positive"
        }
    }
}

/// A verified local endpoint for the user's existing OpenCode service.
///
/// Only loopback hosts are accepted, and credentials, query, and fragment are
/// refused, so an authorization secret can never be carried in the URL that
/// this connector builds requests from. The service's port is supplied by the
/// caller; the published V2 specification does not state a default port.
struct OpenCodeEndpoint: Equatable {
    let baseURL: URL

    init(baseURL: URL) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = baseURL.host,
              Self.isLoopback(host),
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/"
        else {
            throw OpenCodeConfigurationError.notVerifiedLocalEndpoint
        }
        self.baseURL = baseURL
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.lowercased() == "localhost"
    }
}

extension OpenCodeEndpoint: CustomStringConvertible {
    /// Scheme, host, and port only. Paths, user info, query, and fragment are
    /// never printed.
    var description: String {
        let host = baseURL.host ?? ""
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return "OpenCodeEndpoint(\(baseURL.scheme ?? "")://\(host)\(port))"
    }
}

// MARK: - Configuration

/// Everything the adapter needs from its owner, supplied by the app.
///
/// The connector never scans processes, reads a clock, or allocates a timer:
/// the owner identity, activation generation, and observation time all come
/// from the caller. Stage 5 owns scheduling and passes the current activation
/// generation from `ActivationHandoff`.
struct OpenCodeConfiguration: Equatable {
    /// Canonical family identifier; events only come from this source.
    static let family = "opencode"

    /// The connector's logical instance. Also used as the owner instance.
    var instance: String
    var activationGeneration: UInt64
    var owner: OwnerIdentity
    var target: String

    /// Snapshot entry bound. Never larger than the model's own work bound.
    var entryLimit: Int

    /// Snapshot byte bound, matching the store's per-event limit by default.
    var maxEventBytes: Int

    init(
        instance: String,
        activationGeneration: UInt64,
        owner: OwnerIdentity,
        target: String = "opencode.tui",
        entryLimit: Int = ActivityModel.maxWorks,
        maxEventBytes: Int = LocalEventStore.Limits().maxEventBytes
    ) throws {
        guard EventFileName.sanitize(instance) == instance,
              !instance.isEmpty,
              instance.count <= 64
        else {
            throw OpenCodeConfigurationError.invalidInstance
        }
        guard owner.instance == instance else {
            throw OpenCodeConfigurationError.ownerInstanceMismatch
        }
        guard !target.isEmpty else {
            throw OpenCodeConfigurationError.invalidTarget
        }
        guard entryLimit > 0, entryLimit <= ActivityModel.maxWorks else {
            throw OpenCodeConfigurationError.invalidEntryLimit
        }
        guard maxEventBytes > 0 else {
            throw OpenCodeConfigurationError.invalidByteLimit
        }
        self.instance = instance
        self.activationGeneration = activationGeneration
        self.owner = owner
        self.target = target
        self.entryLimit = entryLimit
        self.maxEventBytes = maxEventBytes
    }
}

// MARK: - Problems, oversize, observation

/// Why an observation could not prove complete coverage.
///
/// Fixed tokens only. Permission text, form text, resource lists, metadata,
/// session titles, response bodies, and authorization values are never copied
/// into a problem, an event, or an error description.
enum OpenCodeProblem: String, Equatable, CaseIterable {
    /// The active-session listing could not be read.
    case activeListingUnavailable
    case activeListingUnauthorized
    case activeListingMalformed
    /// A running row's per-session execution detail could not be read.
    case sessionDetailUnavailable
    case sessionDetailMalformed
    case permissionListUnavailable
    case permissionListMalformed
    case formListUnavailable
    case formListMalformed
    case unreadableActiveRow
    /// A row claims `running` while its execution detail reports a terminal
    /// `outcome`. The detail may describe an older execution, so completion is
    /// not proven.
    case runningRowWithFinishedOutcome
    case invalidSessionIdentifier
}

/// A snapshot that cannot be represented within the model's bounds.
///
/// An oversize snapshot is never truncated and never presented as complete.
/// The caller maps it to the model's capacity-gap path with
/// `OpenCodeAdapter.recordCapacityGap(for:in:)`, which marks affected work
/// uncertain.
struct OpenCodeOversize: Equatable {
    var family: String
    var instance: String
    var observedAt: Date
    /// Entries proven when the check fired: the listing's row count when the
    /// per-pass row bound stopped the pass before any session read, one past
    /// `entryLimit` when the configured entry bound stopped the scan, or the
    /// proved total for the byte bound.
    var entryCount: Int
    var entryLimit: Int
    /// Encoded snapshot size; 0 when the entry bound was hit first.
    var encodedBytes: Int
    var byteLimit: Int
    var problems: [OpenCodeProblem]

    var exceededEntryLimit: Bool { entryCount > entryLimit }
    var exceededByteLimit: Bool { encodedBytes > byteLimit }
}

/// The result of one read-only observation.
///
/// Only `.complete` claims that the listing covered every active work item in
/// its scope. Every other case makes the caller's model uncertain; none can be
/// recorded as idle.
enum OpenCodeObservation: Equatable {
    /// A complete instance-scoped snapshot. Applying it is authoritative for
    /// every session of this instance.
    ///
    /// `confirmedInactive` carries, for every session this pass proved inactive
    /// from its row type, a session-scoped complete snapshot with no entries.
    /// The instance snapshot cannot reconcile a session it omits once any other
    /// read in the pass failed, so these explicit statements are what end a
    /// finished session's record in an incomplete pass. They are ordered after
    /// the instance snapshot.
    case complete(ActivityEvent, confirmedInactive: [ActivityEvent])

    /// The listing succeeded but coverage was not proven. `snapshot` carries
    /// the work items that were proven and has `snapshotComplete == false`, so
    /// the model marks omitted work uncertain instead of ended.
    /// `confirmedInactive` holds the session-scoped complete snapshots for
    /// sessions the pass proved inactive, so a finished session still ends even
    /// though another session's read failed. `losses` are observation-loss
    /// events for the sessions that could not be read (session scoped where the
    /// identifier is usable, instance scoped otherwise). Ordering is always:
    /// instance snapshot, per-session complete snapshots, losses.
    case incomplete(
        snapshot: ActivityEvent,
        confirmedInactive: [ActivityEvent],
        losses: [ActivityEvent],
        problems: [OpenCodeProblem]
    )

    /// The active listing itself was unreadable. One instance-scoped
    /// observation-loss event replaces any snapshot.
    case unavailable(loss: ActivityEvent, problem: OpenCodeProblem)

    /// The payload proved more work than the model or the inbox can hold. No
    /// event is produced; the caller records a capacity gap.
    case oversize(OpenCodeOversize)

    /// Normalized events in the order the store must apply them.
    var events: [ActivityEvent] {
        switch self {
        case .complete(let snapshot, let confirmedInactive):
            return [snapshot] + confirmedInactive
        case .incomplete(let snapshot, let confirmedInactive, let losses, _):
            return [snapshot] + confirmedInactive + losses
        case .unavailable(let loss, _):
            return [loss]
        case .oversize:
            return []
        }
    }

    var snapshotEvent: ActivityEvent? {
        switch self {
        case .complete(let snapshot, _):
            return snapshot
        case .incomplete(let snapshot, _, _, _):
            return snapshot
        case .unavailable, .oversize:
            return nil
        }
    }

    var problems: [OpenCodeProblem] {
        switch self {
        case .complete:
            return []
        case .incomplete(_, _, _, let problems):
            return problems
        case .unavailable(_, let problem):
            return [problem]
        case .oversize(let oversize):
            return oversize.problems
        }
    }
}

// MARK: - Adapter

/// Read-only client of the user's existing local OpenCode service.
///
/// Boundaries:
///
/// - No timer, thread, background queue, retry loop, or polling loop. One
///   `observe` call performs a fixed fan-out of reads and returns; Stage 5
///   decides when to call it. An inactive package therefore starts nothing.
/// - The service is only read. The adapter never restarts, stops, reconfigures,
///   prompts, interrupts, or otherwise mutates it.
/// - No process scanning and no payload persistence. Only normalized
///   `ActivityEvent` values are handed back, and only the same immutable inbox
///   path the helper uses can store them.
///
/// Interpretation rules, all conservative:
///
/// - Membership in `/api/session/active` is not work. A row is only a candidate;
///   its documented `SessionActive` type must be `"running"` *and* its
///   per-session `Session.Info` must record no finished `outcome`.
/// - The documented inactive type `"idle"` proves the session has no running
///   execution. That proof is stated as a session-scoped complete snapshot with
///   no entries, so a finished record ends even when another session's read
///   fails in the same pass. A row type this connector does not document is
///   unreadable: it produces a problem, never work and never a completion.
/// - `outcome` is never used to end work a row still calls `running`: a running
///   row that also carries a terminal `outcome` is contradictory (the detail can
///   describe an older execution), so it is a problem and the work is not
///   ended. Inactivity is proved by the row's own documented inactive type;
///   no execution detail is read for a row that does not claim to be running.
/// - A pending permission (`Permission.Request`) or form (`Form.Info`) is human
///   wait: it allows sleep when no other work is active, and it outranks a
///   running execution in that session.
/// - Any unreadable page, row, detail, permission list, or form list makes the
///   observation incomplete and produces observation-loss uncertainty. Work
///   that could not be re-read is never reported as ended or idle.
/// - Over the HTTP surface there is no documented execution identifier, so each
///   session has exactly one normalized work item (`"execution"`, generation 0).
///   Snapshots are the only transition this adapter emits; state changes are
///   authoritative snapshot statements, not reconstructed completions.
struct OpenCodeAdapter {
    /// Response body bound; larger bodies are refused as malformed rather than
    /// decoded into unbounded memory. The production transport enforces the
    /// same bound while streaming, so the whole body is never buffered.
    static let maxResponseBytes = 4 * 1024 * 1024

    /// Bound on listed rows per observation.
    ///
    /// Each usable row costs up to three per-session reads (execution detail,
    /// permission list, form list), so an unbounded listing would turn one
    /// observation into an unbounded number of requests. A listing with more
    /// rows than this is refused as oversize *before* any per-session request;
    /// the caller records the model's `capacityExceeded` gap and no snapshot is
    /// presented as complete. 128 rows is four times the documented parallel
    /// session scale of one local TUI and keeps one pass at most 385 reads.
    static let maxSessionsPerObservation = 128

    /// Pseudo session carried by instance-scoped events. Instance-scoped
    /// snapshots and losses ignore it for coverage; it exists because an
    /// `ActivityEvent` always names a session.
    static let instanceSession = "opencode-service"

    /// The single normalized work name for a session's execution. Generation 0
    /// stays stable, so a session that runs again revives the same record from
    /// the next authoritative snapshot instead of accumulating stale ones.
    static let executionWork = "execution"

    let endpoint: OpenCodeEndpoint
    let configuration: OpenCodeConfiguration
    let transport: OpenCodeTransport

    init(
        endpoint: OpenCodeEndpoint,
        configuration: OpenCodeConfiguration,
        transport: OpenCodeTransport
    ) {
        self.endpoint = endpoint
        self.configuration = configuration
        self.transport = transport
    }

    /// Production initializer: the default URLSession transport. It is used by
    /// the app only, never by tests.
    init(
        endpoint: OpenCodeEndpoint,
        configuration: OpenCodeConfiguration,
        authorization: @escaping @Sendable () -> String? = { nil },
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.configuration = configuration
        self.transport = URLSessionOpenCodeTransport(
            baseURL: endpoint.baseURL,
            session: session,
            authorization: authorization
        )
    }

    // MARK: Observation

    /// Reads the service once at the caller's observation time.
    ///
    /// `at` is required so the adapter never reads a clock and fixtures stay
    /// deterministic. It orders events; it is not their identity — each
    /// emission carries its own nonce, so two observations in the same
    /// microsecond stay distinct.
    func observe(at date: Date) async -> OpenCodeObservation {
        switch await readActiveSessions() {
        case .unavailable(let problem):
            return .unavailable(loss: lossEvent(at: date, session: nil), problem: problem)
        case .listing(let rows):
            return await observe(rows: rows, at: date)
        }
    }

    /// Writes the observation's normalized events through the same immutable
    /// inbox the helper uses. Oversize carries no event, so nothing is written
    /// and the caller records the capacity gap instead.
    @discardableResult
    func enqueue(_ observation: OpenCodeObservation, into store: LocalEventStore) throws -> Int {
        var written = 0
        for event in observation.events {
            try store.enqueue(event)
            written += 1
        }
        return written
    }

    /// Maps an oversize snapshot to the model's capacity-gap path.
    ///
    /// The model records `capacityExceeded` for the instance and conservatively
    /// marks affected active work uncertain; it never sees a truncated snapshot.
    static func recordCapacityGap(for oversize: OpenCodeOversize, in model: inout ActivityModel) {
        model.recordGap(
            family: oversize.family,
            instance: oversize.instance,
            session: nil,
            reason: .capacityExceeded,
            at: oversize.observedAt
        )
    }

    // MARK: Listing

    private enum ActiveListing {
        case listing(rows: [String: Any])
        case unavailable(OpenCodeProblem)
    }

    private func readActiveSessions() async -> ActiveListing {
        switch await transport.get(OpenCodeService.activeSessionsPath) {
        case .failure:
            return .unavailable(.activeListingUnavailable)
        case .response(let response):
            guard response.status == 200 else {
                return .unavailable(response.status == 401 ? .activeListingUnauthorized : .activeListingUnavailable)
            }
            guard response.body.count <= Self.maxResponseBytes,
                  let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let rows = root["data"] as? [String: Any]
            else {
                return .unavailable(.activeListingMalformed)
            }
            return .listing(rows: rows)
        }
    }

    // MARK: Snapshot

    private func observe(rows: [String: Any], at date: Date) async -> OpenCodeObservation {
        // Bound the fan-out before any per-session request. A listing past the
        // row bound proves the snapshot cannot be represented, so the pass
        // returns without reading a single session.
        guard rows.count <= Self.maxSessionsPerObservation else {
            return .oversize(OpenCodeOversize(
                family: OpenCodeConfiguration.family,
                instance: configuration.instance,
                observedAt: date,
                entryCount: rows.count,
                entryLimit: configuration.entryLimit,
                encodedBytes: 0,
                byteLimit: configuration.maxEventBytes,
                problems: []
            ))
        }

        var entries: [SnapshotEntry] = []
        var problems: [OpenCodeProblem] = []
        var failedSessions: Set<String> = []
        /// Sessions this pass proved have no running execution. Each one is
        /// stated as a session-scoped complete snapshot with no entries, so the
        /// model ends its record even when another read in the pass fails and
        /// the instance-scoped snapshot is therefore incomplete.
        var inactiveSessions: Set<String> = []
        var instanceLost = false

        for sessionID in rows.keys.sorted() {
            guard OpenCodeService.isUsableSessionIdentifier(sessionID) else {
                // The identifier is neither safe in a path nor usable in an
                // event, so the loss can only be stated for the instance.
                problems.append(.invalidSessionIdentifier)
                instanceLost = true
                continue
            }

            switch rowState(rows[sessionID]) {
            case .unreadable:
                problems.append(.unreadableActiveRow)
                failedSessions.insert(sessionID)

            case .inactive:
                // The row type itself proves no execution is running. Pending
                // human waits are still read, because a wait is a state the
                // model must show even though it allows sleep.
                let wait = await readPendingWait(sessionID: sessionID)
                problems.append(contentsOf: wait.problems)
                if !wait.problems.isEmpty {
                    failedSessions.insert(sessionID)
                    inactiveSessions.insert(sessionID)
                } else if wait.hasWait {
                    // The wait entry replaces the session's execution record,
                    // so no separate inactivity statement is emitted for it.
                    entries.append(entry(sessionID, state: .waitingForUser))
                } else {
                    inactiveSessions.insert(sessionID)
                }

            case .running:
                switch await readExecutionDetail(sessionID: sessionID) {
                case .unavailable:
                    problems.append(.sessionDetailUnavailable)
                    failedSessions.insert(sessionID)
                case .malformed:
                    problems.append(.sessionDetailMalformed)
                    failedSessions.insert(sessionID)
                case .finished:
                    // The row still claims `running` while the detail reports a
                    // finished outcome. The detail can describe an earlier
                    // execution, so this is not proof of completion: the
                    // contradiction leaves the session unreadable.
                    problems.append(.runningRowWithFinishedOutcome)
                    failedSessions.insert(sessionID)
                case .running:
                    let wait = await readPendingWait(sessionID: sessionID)
                    problems.append(contentsOf: wait.problems)
                    if !wait.problems.isEmpty {
                        failedSessions.insert(sessionID)
                    } else if wait.hasWait {
                        entries.append(entry(sessionID, state: .waitingForUser))
                    } else {
                        entries.append(entry(sessionID, state: .working))
                    }
                }
            }

            // A configured entry bound smaller than the row bound still stops
            // the pass one entry past the model's work bound.
            if entries.count > configuration.entryLimit {
                return .oversize(OpenCodeOversize(
                    family: OpenCodeConfiguration.family,
                    instance: configuration.instance,
                    observedAt: date,
                    entryCount: entries.count,
                    entryLimit: configuration.entryLimit,
                    encodedBytes: 0,
                    byteLimit: configuration.maxEventBytes,
                    problems: problems
                ))
            }
        }

        let snapshot = snapshotEvent(entries: entries, complete: problems.isEmpty, at: date)
        let encodedBytes = (try? Self.encoder.encode(snapshot))?.count ?? 0
        if encodedBytes > configuration.maxEventBytes {
            return .oversize(OpenCodeOversize(
                family: OpenCodeConfiguration.family,
                instance: configuration.instance,
                observedAt: date,
                entryCount: entries.count,
                entryLimit: configuration.entryLimit,
                encodedBytes: encodedBytes,
                byteLimit: configuration.maxEventBytes,
                problems: problems
            ))
        }

        // Per-session complete snapshots follow the instance snapshot in sorted
        // session order, so applying them in file order is deterministic.
        let confirmedInactive = inactiveSessions.sorted().map {
            inactivitySnapshotEvent(session: $0, at: date)
        }

        guard !problems.isEmpty else {
            return .complete(snapshot, confirmedInactive: confirmedInactive)
        }

        // Losses come last: snapshot ids (`snap…`, `snapsession…`) sort before
        // loss ids (`uncertain…`) at the same observation time, so the
        // session-scoped gaps survive the snapshots' gap clearing.
        var losses: [ActivityEvent] = []
        for sessionID in failedSessions.sorted() {
            losses.append(lossEvent(at: date, session: sessionID))
        }
        if instanceLost {
            losses.append(lossEvent(at: date, session: nil))
        }
        return .incomplete(
            snapshot: snapshot,
            confirmedInactive: confirmedInactive,
            losses: losses,
            problems: problems
        )
    }

    private enum RowState: Equatable {
        case running
        /// The documented inactive type, which proves no execution is running.
        case inactive
        case unreadable
    }

    /// Row interpretation. Only the documented `running` and `idle` types are
    /// understood; every other value, a non-object, or a missing type is
    /// unreadable rather than optimistically finished.
    private func rowState(_ value: Any?) -> RowState {
        guard let object = value as? [String: Any],
              let type = object["type"] as? String
        else {
            return .unreadable
        }
        switch type {
        case "running": return .running
        case "idle": return .inactive
        default: return .unreadable
        }
    }

    // MARK: Per-session detail

    private enum ExecutionDetail: Equatable {
        case running
        case finished
        case unavailable
        case malformed
    }

    /// `GET /api/session/{id}` → `{ "data": Session.Info }`.
    ///
    /// Only identity and the documented `outcome` are read. `outcome` is
    /// `succeeded`, `failed`, or `interrupted` for a finished execution; absent
    /// (or JSON null) means no finished outcome is recorded. An unknown outcome
    /// value is treated as malformed rather than guessed.
    private func readExecutionDetail(sessionID: String) async -> ExecutionDetail {
        switch await transport.get(OpenCodeService.sessionPath(sessionID)) {
        case .failure:
            return .unavailable
        case .response(let response):
            guard response.status == 200 else { return .unavailable }
            guard response.body.count <= Self.maxResponseBytes,
                  let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let data = root["data"] as? [String: Any],
                  let identifier = data["id"] as? String,
                  identifier == sessionID
            else {
                return .malformed
            }
            guard let outcome = data["outcome"], !(outcome is NSNull) else {
                return .running
            }
            guard let value = outcome as? String,
                  value == "succeeded" || value == "failed" || value == "interrupted"
            else {
                return .malformed
            }
            return .finished
        }
    }

    // MARK: Pending human waits

    private struct PendingWait {
        var hasWait: Bool
        var problems: [OpenCodeProblem]
    }

    private func readPendingWait(sessionID: String) async -> PendingWait {
        var problems: [OpenCodeProblem] = []
        var hasWait = false

        switch await readPendingList(
            path: OpenCodeService.permissionsPath(sessionID),
            sessionID: sessionID
        ) {
        case .present(let empty):
            hasWait = hasWait || !empty
        case .unavailable:
            problems.append(.permissionListUnavailable)
        case .malformed:
            problems.append(.permissionListMalformed)
        }

        switch await readPendingList(
            path: OpenCodeService.formsPath(sessionID),
            sessionID: sessionID
        ) {
        case .present(let empty):
            hasWait = hasWait || !empty
        case .unavailable:
            problems.append(.formListUnavailable)
        case .malformed:
            problems.append(.formListMalformed)
        }

        return PendingWait(hasWait: hasWait, problems: problems)
    }

    private enum PendingList: Equatable {
        case present(empty: Bool)
        case unavailable
        case malformed
    }

    /// Reads one documented pending list (`{ "data": [ … ] }`). Only emptiness
    /// and each item's owning session are read; every other field is ignored
    /// and never persisted.
    private func readPendingList(path: String, sessionID: String) async -> PendingList {
        switch await transport.get(path) {
        case .failure:
            return .unavailable
        case .response(let response):
            guard response.status == 200 else { return .unavailable }
            guard response.body.count <= Self.maxResponseBytes,
                  let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let items = root["data"] as? [Any]
            else {
                return .malformed
            }
            for item in items {
                guard let object = item as? [String: Any],
                      let owner = object["sessionID"] as? String,
                      owner == sessionID
                else {
                    return .malformed
                }
            }
            return .present(empty: items.isEmpty)
        }
    }

    // MARK: Event construction

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func entry(_ sessionID: String, state: WorkState) -> SnapshotEntry {
        SnapshotEntry(
            session: SessionIdentity(
                family: OpenCodeConfiguration.family,
                instance: configuration.instance,
                session: sessionID
            ),
            work: Self.executionWork,
            generation: 0,
            parentWork: nil,
            state: state
        )
    }

    /// Instance-scoped authoritative snapshot. `snapshotComplete` is true only
    /// when every documented read for every listed session succeeded.
    private func snapshotEvent(entries: [SnapshotEntry], complete: Bool, at date: Date) -> ActivityEvent {
        ActivityEvent(
            id: eventID(prefix: "snap", at: date),
            source: OpenCodeConfiguration.family,
            activationGeneration: configuration.activationGeneration,
            target: configuration.target,
            owner: configuration.owner,
            session: SessionIdentity(
                family: OpenCodeConfiguration.family,
                instance: configuration.instance,
                session: Self.instanceSession
            ),
            transition: .snapshot,
            timestamp: date,
            scope: .instance,
            snapshotEntries: entries,
            snapshotComplete: complete
        )
    }

    /// Session-scoped authoritative statement that a proved-inactive session
    /// holds no work. It carries no entries: an omitted record is ended, and
    /// the session's own gaps are cleared, exactly as the model's complete
    /// snapshot rules require.
    private func inactivitySnapshotEvent(session sessionID: String, at date: Date) -> ActivityEvent {
        ActivityEvent(
            id: eventID(prefix: "snapsession", at: date),
            source: OpenCodeConfiguration.family,
            activationGeneration: configuration.activationGeneration,
            target: configuration.target,
            owner: configuration.owner,
            session: SessionIdentity(
                family: OpenCodeConfiguration.family,
                instance: configuration.instance,
                session: sessionID
            ),
            transition: .snapshot,
            timestamp: date,
            scope: .session,
            snapshotEntries: [],
            snapshotComplete: true
        )
    }

    /// Observation loss. A named session produces a session-scoped gap; `nil`
    /// produces an instance-scoped gap, which only a later complete snapshot or
    /// package removal clears.
    private func lossEvent(at date: Date, session: String?) -> ActivityEvent {
        ActivityEvent(
            id: eventID(prefix: "uncertain", at: date),
            source: OpenCodeConfiguration.family,
            activationGeneration: configuration.activationGeneration,
            target: configuration.target,
            owner: configuration.owner,
            session: SessionIdentity(
                family: OpenCodeConfiguration.family,
                instance: configuration.instance,
                session: session ?? Self.instanceSession
            ),
            transition: .observationLost,
            timestamp: date,
            scope: session == nil ? .instance : .session,
            snapshotComplete: false
        )
    }

    /// File-name-safe, bounded, unique event identity.
    ///
    /// The timestamp alone is not an identity: two observations in the same
    /// microsecond would collide, and a proven snapshot would then be dropped
    /// as a duplicate. A per-emission nonce, as the helper uses, keeps every
    /// event distinct. The prefixes keep ordering when the observation time is
    /// equal: `snap-…` (instance snapshot) sorts first, then `snapsession-…`
    /// (per-session complete snapshots), then `uncertain-…` (losses).
    private func eventID(prefix: String, at date: Date, nonce: UUID = UUID()) -> String {
        let micros = UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded(.down)))
        let tail = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)-\(micros)-\(tail)"
    }
}

// `.incomplete` carries an instance snapshot, per-session complete snapshots
// for proved-inactive sessions, and per-session losses; all are plain
// normalized events, and the equality is structural.
