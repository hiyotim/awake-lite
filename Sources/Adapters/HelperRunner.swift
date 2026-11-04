import Foundation

// MARK: - Exit codes

/// Process exit codes fixed by the helper contract that installed templates use.
///
/// 0 = exactly one event file was written. 2 = invalid input, usage, unknown
/// family or event, or a malformed/oversize payload. 3 = the family is inactive
/// or the activation generation is stale. 4 = the storage write failed.
enum HelperExitCode: Int32 {
    case written = 0
    case invalidInput = 2
    case inactiveFamily = 3
    case storageFailure = 4
}

/// Outcome of one emission: the exit code plus the single diagnostic line the
/// binary prints to stderr on failure. It never carries a payload byte.
struct HelperOutcome: Equatable {
    var exitCode: Int32
    var diagnostic: String?
}

// MARK: - Runner

/// One hook emission, driven entirely by injected values.
///
/// The runner reads no process-global state: arguments, stdin bytes, the app
/// support root, the adapter list, the clock, and the owner are parameters, so
/// XCTest can drive the exact production path.
enum HelperRunner {
    /// Accepted stdin body size. A larger body is refused before it is parsed.
    static let maxPayloadBytes = HookNormalizer.maxPayloadBytes

    /// Longest accepted `--event` token; documented vendor event names are short.
    static let maxEventLength = 128

    /// Syntax accepted on the command line, in the order diagnostics report it.
    static let valueFlags = [
        "--family", "--target", "--generation", "--event", "--app-support",
        "--owner-instance", "--owner-pid"
    ]

    /// Longest accepted `--owner-instance` token. The value becomes the
    /// session instance and part of an event file name, so it must be
    /// canonical and no longer than a stored identifier.
    static let maxOwnerInstanceLength = HookIdentifier.maxLength

    static let usage = "usage: AwakeLiteHelper --family <family> --target <target> "
        + "--generation <uint64> --event <vendor-event> [--app-support <dir>] "
        + "[--owner-instance <token> --owner-pid <pid>]"

    struct ParsedArguments {
        var invocation: HookInvocation
        var appSupportRoot: URL?

        /// Owner supplied by the caller when the helper cannot measure one.
        /// `nil` means the caller wants the ancestry probe.
        var owner: OwnerIdentity?
    }

    // MARK: Arguments

    /// Parses the documented command line.
    ///
    /// Every rejection is `invalidUsage` (exit 2): an unrecognized flag, a
    /// duplicate or missing flag, a missing or empty value, a non-canonical
    /// family, a `--target` that does not start with `<family>.`, a
    /// `--generation` that is not a positive uint64, an event token that is not
    /// a documented-shaped name, a relative `--app-support` path, or one
    /// owner flag without the other, a non-canonical or oversize
    /// `--owner-instance`, or a `--owner-pid` that is not an integer above 1.
    static func parse(arguments: [String]) throws -> ParsedArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard valueFlags.contains(flag) else {
                throw HookIngestError.invalidUsage("unrecognized argument")
            }
            guard values[flag] == nil else {
                throw HookIngestError.invalidUsage("duplicate \(flag)")
            }
            guard index + 1 < arguments.count else {
                throw HookIngestError.invalidUsage("missing value for \(flag)")
            }
            let value = arguments[index + 1]
            guard !value.isEmpty else {
                throw HookIngestError.invalidUsage("empty value for \(flag)")
            }
            values[flag] = value
            index += 2
        }

        for flag in ["--family", "--target", "--generation", "--event"] where values[flag] == nil {
            throw HookIngestError.invalidUsage("missing \(flag)")
        }

        let family = values["--family"]!
        guard PathRules.isCanonicalComponent(family) else {
            throw HookIngestError.invalidUsage("--family is not a canonical family identifier")
        }

        let target = values["--target"]!
        guard PathRules.isCanonicalComponent(target),
              target.hasPrefix(family + "."),
              target.count > family.count + 1
        else {
            throw HookIngestError.invalidUsage("--target must start with \"<family>.\"")
        }

        guard let generation = UInt64(values["--generation"]!), generation > 0 else {
            throw HookIngestError.invalidUsage("--generation must be a positive uint64")
        }

        let event = values["--event"]!
        guard PathRules.isCanonicalComponent(event), event.count <= maxEventLength else {
            throw HookIngestError.invalidUsage("--event is not a documented event name")
        }

        var root: URL?
        if let path = values["--app-support"] {
            guard path.hasPrefix("/") else {
                throw HookIngestError.invalidUsage("--app-support must be an absolute path")
            }
            root = URL(fileURLWithPath: path, isDirectory: true)
        }

        return ParsedArguments(
            invocation: HookInvocation(
                family: family,
                target: target,
                generation: generation,
                event: event
            ),
            appSupportRoot: root,
            owner: try suppliedOwner(values)
        )
    }

    /// The owner the caller measured before spawning this helper.
    ///
    /// Both flags must appear together or not at all. An instance token is
    /// accepted only when it is already canonical and within the stored
    /// identifier bound; a supplied pid must be a positive process id above
    /// PID 1. Everything but those two values comes from the helper: the boot
    /// token and uid are its own, and `startTimeMicros` is 0 because the caller
    /// supplies no measurement of the owner's start time.
    ///
    /// This exists because a detached helper can be orphaned before it probes
    /// `getppid()`: the measured owner would then be launchd or a dead wrapper,
    /// so every emission of one harness process would disagree on the owner and
    /// teardown could never match. A supplied instance is identical across all
    /// emissions of that process and survives its exit.
    private static func suppliedOwner(_ values: [String: String]) throws -> OwnerIdentity? {
        let instance = values["--owner-instance"]
        let pidText = values["--owner-pid"]

        switch (instance, pidText) {
        case (nil, nil):
            return nil
        case (let instance?, let pidText?):
            guard HookIdentifier.isCanonical(instance),
                  instance.unicodeScalars.count <= maxOwnerInstanceLength
            else {
                throw HookIngestError.invalidUsage(
                    "--owner-instance must be a canonical token of at most "
                        + "\(maxOwnerInstanceLength) characters"
                )
            }
            guard let pid = Int32(pidText), pid > 1, String(pid) == pidText else {
                throw HookIngestError.invalidUsage(
                    "--owner-pid must be an integer process id greater than 1"
                )
            }
            return OwnerIdentityProbe.supplied(instance: instance, pid: pid)
        case (nil, _?):
            throw HookIngestError.invalidUsage("--owner-pid requires --owner-instance")
        case (_?, nil):
            throw HookIngestError.invalidUsage("--owner-instance requires --owner-pid")
        }
    }

    /// Production default: `~/Library/Application Support/AwakeLite`.
    static func defaultAppSupportRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/AwakeLite", isDirectory: true)
    }

    // MARK: Emission

    /// Runs one emission and returns its report. Writes nothing to a stream.
    ///
    /// `appSupportRoot` overrides `--app-support`, which overrides the
    /// production default. `owner` overrides the command-line owner (the test
    /// seam); otherwise `--owner-instance`/`--owner-pid` supply the owner, and
    /// only an invocation with neither takes the parent-process probe.
    static func execute(
        arguments: [String],
        stdin: Data,
        appSupportRoot: URL? = nil,
        adapters: [HookAdapter] = HookAdapterRegistry.all,
        now: Date = Date(),
        owner: OwnerIdentity? = nil
    ) -> HelperOutcome {
        do {
            let parsed = try parse(arguments: arguments)
            let root = appSupportRoot ?? parsed.appSupportRoot ?? defaultAppSupportRoot()
            let normalizer = HookNormalizer(appSupportRoot: root, adapters: adapters)
            try normalizer.ingest(
                invocation: parsed.invocation,
                payload: stdin,
                owner: owner ?? parsed.owner ?? OwnerIdentityProbe.parentIdentity(),
                now: now
            )
            return HelperOutcome(exitCode: HelperExitCode.written.rawValue, diagnostic: nil)
        } catch let error as HookIngestError {
            return outcome(for: error)
        } catch {
            // Unexpected failure. The text is dropped because a vendor parser
            // could have put payload content in it.
            return outcome(for: .invalidUsage("the emission could not be normalized"))
        }
    }

    /// Contract-shaped wrapper: returns the exit code and writes the one
    /// diagnostic line, if any, through `write`.
    @discardableResult
    static func run(
        arguments: [String],
        stdin: Data,
        appSupportRoot: URL? = nil,
        adapters: [HookAdapter] = HookAdapterRegistry.all,
        now: Date = Date(),
        owner: OwnerIdentity? = nil,
        write: (String) -> Void = HelperRunner.writeToStandardError
    ) -> Int32 {
        let outcome = execute(
            arguments: arguments,
            stdin: stdin,
            appSupportRoot: appSupportRoot,
            adapters: adapters,
            now: now,
            owner: owner
        )
        if let diagnostic = outcome.diagnostic {
            write(diagnostic)
        }
        return outcome.exitCode
    }

    static func writeToStandardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: Diagnostics

    /// Maps one failure to its exit code and single-line diagnostic.
    static func outcome(for error: HookIngestError) -> HelperOutcome {
        switch error {
        case .invalidUsage(let detail):
            return HelperOutcome(
                exitCode: HelperExitCode.invalidInput.rawValue,
                diagnostic: line("\(detail); \(usage)")
            )
        case .unknownFamily(let family):
            return HelperOutcome(
                exitCode: HelperExitCode.invalidInput.rawValue,
                diagnostic: line("no adapter is registered for family \"\(family)\"")
            )
        case .unknownEvent(let event):
            return HelperOutcome(
                exitCode: HelperExitCode.invalidInput.rawValue,
                diagnostic: line("event \"\(event)\" is not documented for this family")
            )
        case .malformedPayload(let field):
            return HelperOutcome(
                exitCode: HelperExitCode.invalidInput.rawValue,
                diagnostic: line("payload does not match the documented shape at field \"\(field)\"")
            )
        case .payloadTooLarge(let bytes):
            return HelperOutcome(
                exitCode: HelperExitCode.invalidInput.rawValue,
                diagnostic: line("payload of \(bytes) bytes exceeds \(maxPayloadBytes)")
            )
        case .inactiveFamily(let family, let receiptPath):
            return HelperOutcome(
                exitCode: HelperExitCode.inactiveFamily.rawValue,
                diagnostic: line("family \"\(family)\" is not active; no committed receipt at \(receiptPath)")
            )
        case .activationUnavailable(let path):
            return HelperOutcome(
                exitCode: HelperExitCode.inactiveFamily.rawValue,
                diagnostic: line("install state is unreadable at \(path)")
            )
        case .staleGeneration(let requested, let installed):
            return HelperOutcome(
                exitCode: HelperExitCode.inactiveFamily.rawValue,
                diagnostic: line(
                    "activation generation \(requested) is stale; installed generation is \(installed)"
                )
            )
        case .storage(let detail):
            return HelperOutcome(
                exitCode: HelperExitCode.storageFailure.rawValue,
                diagnostic: line("cannot write the event: \(detail)")
            )
        }
    }

    /// One short line, prefixed with the binary name. Newlines inside a system
    /// message are folded so stderr stays one line.
    static func line(_ text: String) -> String {
        let folded = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "AwakeLiteHelper: \(folded)"
    }
}

// MARK: - Process shell

/// The only helper code that reads global process state.
///
/// The binary is a thin shell over this entry point: it reads stdin with a bound
/// and exits with the returned code. XCTest drives `HelperRunner` directly
/// instead, so no test depends on the real stdin, stderr, parent, or home.
public enum HelperEntryPoint {
    @discardableResult
    public static func main(
        arguments: [String],
        standardInput: FileHandle = .standardInput,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        guard let payload = readBounded(standardInput) else {
            standardError.write(
                Data("AwakeLiteHelper: the hook payload could not be read\n".utf8)
            )
            return HelperExitCode.invalidInput.rawValue
        }
        return HelperRunner.run(arguments: arguments, stdin: payload) { line in
            standardError.write(Data((line + "\n").utf8))
        }
    }

    /// Reads at most one byte past the payload bound, which is enough to tell
    /// "at the bound" from "over the bound"; `nil` means the read failed.
    static func readBounded(_ handle: FileHandle) -> Data? {
        var data = Data()
        do {
            while data.count <= HelperRunner.maxPayloadBytes {
                let chunk = try handle.read(upToCount: HelperRunner.maxPayloadBytes - data.count + 1)
                guard let chunk, !chunk.isEmpty else { return data }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data
    }
}
