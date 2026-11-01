import XCTest
@testable import AwakeLiteCore

/// Unit 2.4 privacy fixtures (A15): persisted bytes and error text carry
/// lifecycle metadata, paths, and markers only.
final class PrivacyTests: XCTestCase {
    private struct SimulatedCrash: Error {}

    private var sandbox: URL!
    private var home: URL!
    private var support: URL!
    private var applications: URL!
    private var catalog: Catalog!
    private var installer: Installer!

    /// Obvious conversation and credential markers that must never be
    /// persisted by the installer.
    private let secrets = [
        "PROMPT-MARKER-ALPHA",
        "RESPONSE-MARKER-BETA",
        "TOOL-ARGS-MARKER-GAMMA",
        "sk-live-marker-delta-42"
    ]

    /// Documented schema keys. Anything else in a receipt or journal is a leak
    /// of implementation detail or content.
    private static let receiptKeys: Set<String> = [
        "schema", "family", "packageVersion", "activationGeneration", "installedAt",
        "stage", "entries", "previousGeneration", "createdDirectories"
    ]
    private static let receiptRequired: Set<String> = [
        "schema", "family", "packageVersion", "activationGeneration", "installedAt",
        "stage", "entries", "createdDirectories"
    ]
    private static let entryKeys: Set<String> = [
        "target", "path", "format", "marker", "expectedHash", "kind", "keyPath", "createdFile"
    ]
    private static let entryRequired: Set<String> = [
        "target", "path", "format", "marker", "expectedHash", "kind", "createdFile"
    ]
    private static let journalKeys: Set<String> = [
        "schema", "operationId", "family", "action", "stage", "startedAt", "steps",
        "createdPaths", "expectedMutations", "receipt"
    ]
    private static let journalRequired: Set<String> = [
        "schema", "operationId", "family", "action", "stage", "startedAt", "steps",
        "createdPaths", "expectedMutations"
    ]
    private static let stepKeys: Set<String> = [
        "operation", "target", "path", "beforeHash", "afterHash", "backupPath",
        "applied", "created", "undo"
    ]
    private static let stepRequired: Set<String> = ["operation", "target", "path", "applied", "created"]
    private static let undoKeys: Set<String> = ["kind", "keyPath", "prefix", "markers", "texts"]
    private static let undoKinds: Set<String> = [
        "removeJSONEntries", "restoreJSONEntries", "removeBlocks", "restoreBlocks",
        "deleteFile", "restoreFile"
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try IntegrationFixtures.makeSandbox()
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        support = sandbox.appendingPathComponent("support", isDirectory: true)
        applications = sandbox.appendingPathComponent("applications", isDirectory: true)
        for directory in [home, applications] {
            try FileManager.default.createDirectory(
                at: directory!,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        catalog = try IntegrationFixtures.bundledCatalog()
        installer = Installer(catalog: catalog)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        home = nil
        support = nil
        applications = nil
        catalog = nil
        installer = nil
        try super.tearDownWithError()
    }

    // MARK: - Byte scan across the lifecycle

    func testPersistedFilesNeverContainSeededConversationContent() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try seedFile(
            at: settings,
            text: """
            {
              "prompt": "\(secrets[0])",
              "conversation": {"assistant": "\(secrets[1])"},
              "toolArguments": "\(secrets[2])",
              "credentials": {"apiKey": "\(secrets[3])"}
            }
            """
        )
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try seedFile(
            at: codexConfig,
            text: """
            model = "gpt-5"
            # last prompt: \(secrets[0])
            api_key = "\(secrets[3])"
            """
        )

        _ = try install("claude-code")
        try assertNoSecretsUnderSupport()

        _ = try install("codex")
        try assertNoSecretsUnderSupport()

        _ = try install("claude-code")
        try assertNoSecretsUnderSupport()

        _ = try installer.remove(family: "codex", appSupportRoot: support)
        try assertNoSecretsUnderSupport()

        // A recovery-required conflict: interrupted reinstall plus a user edit.
        let crashed = Installer(catalog: catalog, faults: { point in
            if point == .beforeStep(1) { throw SimulatedCrash() }
        })
        let preview = try installer.preview(
            family: "claude-code",
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertThrowsError(try crashed.apply(preview))
        var object = try IntegrationFixtures.jsonObject(settings)
        object["userEdit"] = "edited after the interruption with \(secrets[1])"
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: settings)

        let reports = try installer.recoverPending(appSupportRoot: support)
        XCTAssertEqual(reports.first?.outcome, .recoveryRequired)
        XCTAssertFalse(journalFiles().isEmpty, "the scan must cover a live journal")
        try assertNoSecretsUnderSupport()
    }

    // MARK: - Schema key allowlists

    func testReceiptAndJournalJSONUseOnlyDocumentedKeys() throws {
        _ = try install("claude-code")
        let receiptURL = support.appendingPathComponent("receipts/claude-code.json")
        let receipt = try IntegrationFixtures.jsonObject(receiptURL)

        XCTAssertTrue(Set(receipt.keys).isSubset(of: Self.receiptKeys), "unexpected receipt key")
        XCTAssertTrue(Self.receiptRequired.isSubset(of: Set(receipt.keys)), "missing receipt key")
        let entries = try XCTUnwrap(receipt["entries"] as? [[String: Any]])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            XCTAssertTrue(Set(entry.keys).isSubset(of: Self.entryKeys), "unexpected entry key")
            XCTAssertTrue(Self.entryRequired.isSubset(of: Set(entry.keys)), "missing entry key")
            XCTAssertEqual(Set(entry.keys).subtracting(Self.entryKeys), [])
        }
        XCTAssertEqual(receipt["stage"] as? String, "committed")

        // An in-flight journal, captured by interrupting after the first step.
        let crashed = Installer(catalog: catalog, faults: { point in
            if point == .afterStep(0) { throw SimulatedCrash() }
        })
        XCTAssertThrowsError(
            try crashed.apply(
                try installer.preview(
                    family: "claude-code",
                    configRoot: home,
                    appSupportRoot: support,
                    discovery: discovery()
                )
            )
        )
        let journalURL = try XCTUnwrap(journalFiles().first)
        let journal = try IntegrationFixtures.jsonObject(journalURL)

        XCTAssertTrue(Set(journal.keys).isSubset(of: Self.journalKeys), "unexpected journal key")
        XCTAssertTrue(Self.journalRequired.isSubset(of: Set(journal.keys)), "missing journal key")
        let steps = try XCTUnwrap(journal["steps"] as? [[String: Any]])
        XCTAssertFalse(steps.isEmpty)
        for step in steps {
            XCTAssertTrue(Set(step.keys).isSubset(of: Self.stepKeys), "unexpected step key")
            XCTAssertTrue(Self.stepRequired.isSubset(of: Set(step.keys)), "missing step key")
            if let undo = step["undo"] as? [String: Any] {
                XCTAssertTrue(Set(undo.keys).isSubset(of: Self.undoKeys), "unexpected undo key")
                let kind = try XCTUnwrap(undo["kind"] as? String)
                XCTAssertTrue(Self.undoKinds.contains(kind), "unexpected undo kind \(kind)")
            }
        }
        if let pending = journal["receipt"] as? [String: Any] {
            XCTAssertTrue(Set(pending.keys).isSubset(of: Self.receiptKeys))
            XCTAssertTrue(Self.receiptRequired.isSubset(of: Set(pending.keys)))
        }
    }

    // MARK: - Error and report text

    func testErrorTextCarriesPathsAndMarkersOnly() throws {
        let secret = secrets[0]
        let settings = home.appendingPathComponent(".claude/settings.json")

        // Malformed JSON is reported by path; the parser message never echoes
        // the file's content.
        try seedFile(at: settings, text: "{\"prompt\": \"\(secret)\", oops")
        let malformed = try installer.preview(
            family: "claude-code",
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertFalse(malformed.conflicts.isEmpty)
        for text in malformed.conflicts {
            XCTAssertTrue(text.contains(settings.path), "conflict must name the path: \(text)")
            XCTAssertFalse(text.contains(secret), "conflict leaked content: \(text)")
        }
        XCTAssertThrowsError(try installer.apply(malformed)) { error in
            assertNoSecret(in: error, secret)
        }

        // A foreign value at a marker is named by path and marker.
        try seedFile(
            at: settings,
            text: "{\"awakeLite\": {\"awake-lite/claude-code.cli/hooks\": \"\(secret)\"}}"
        )
        let foreign = try installer.preview(
            family: "claude-code",
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertFalse(foreign.conflicts.isEmpty)
        XCTAssertTrue(foreign.conflicts.joined().contains("awake-lite/claude-code.cli/hooks"))
        for text in foreign.conflicts {
            XCTAssertFalse(text.contains(secret))
        }

        // Unknown family and missing receipt name the family only.
        XCTAssertThrowsError(
            try installer.preview(
                family: "no-such-family",
                configRoot: home,
                appSupportRoot: support,
                discovery: discovery()
            )
        ) { error in
            assertNoSecret(in: error, secret)
            XCTAssertTrue(String(describing: error).contains("no-such-family"))
        }
        XCTAssertThrowsError(try installer.remove(family: "pi", appSupportRoot: support)) { error in
            assertNoSecret(in: error, secret)
            XCTAssertTrue(String(describing: error).contains("pi"))
        }

        // A symlinked configuration path names the path.
        let linkedTarget = sandbox.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex"),
            withDestinationURL: linkedTarget
        )
        XCTAssertThrowsError(
            try installer.preview(
                family: "codex",
                configRoot: home,
                appSupportRoot: support,
                discovery: discovery()
            )
        ) { error in
            assertNoSecret(in: error, secret)
            XCTAssertTrue(String(describing: error).contains(".codex"))
        }
    }

    func testRecoveryReportCarriesPathsAndMarkersOnly() throws {
        let secret = secrets[2]
        _ = try install("claude-code")
        let settings = home.appendingPathComponent(".claude/settings.json")

        let crashed = Installer(catalog: catalog, faults: { point in
            if point == .beforeStep(1) { throw SimulatedCrash() }
        })
        let preview = try installer.preview(
            family: "claude-code",
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertThrowsError(try crashed.apply(preview))

        var object = try IntegrationFixtures.jsonObject(settings)
        object["userEdit"] = "edited with \(secret)"
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: settings)

        let journalURL = try XCTUnwrap(journalFiles().first)
        let operationId = journalURL.deletingPathExtension().lastPathComponent

        let reports = try installer.recoverPending(appSupportRoot: support)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.outcome, .recoveryRequired)
        XCTAssertEqual(report.family, "claude-code")
        XCTAssertEqual(report.action, .install)
        XCTAssertEqual(report.operationId, operationId)
        XCTAssertFalse(report.conflicts.isEmpty)
        for conflict in report.conflicts {
            XCTAssertTrue(conflict.contains(settings.path), "conflict must name the path: \(conflict)")
            XCTAssertFalse(conflict.contains(secret), "conflict leaked content: \(conflict)")
            XCTAssertFalse(conflict.contains("userEdit"), "conflict leaked a foreign key")
        }
        XCTAssertFalse(String(describing: report).contains(secret))
        XCTAssertFalse(String(describing: report).contains(secrets[0]))

        // A blocked new operation names the operation id, not file content.
        let blocked = try installer.preview(
            family: "claude-code",
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertThrowsError(try installer.apply(blocked)) { error in
            assertNoSecret(in: error, secret)
            XCTAssertTrue(String(describing: error).contains(operationId))
        }
    }

    // MARK: - Helpers

    private func discovery() -> ProductDiscovery {
        ProductDiscovery(homeRoot: home, applicationRoots: [applications])
    }

    @discardableResult
    private func install(_ family: String) throws -> InstallReceipt {
        let preview = try installer.preview(
            family: family,
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertTrue(preview.conflicts.isEmpty, "\(family): \(preview.conflicts)")
        return try installer.apply(preview)
    }

    private func seedFile(at url: URL, text: String) throws {
        try IntegrationFixtures.write(text, to: url)
    }

    private func journalFiles() -> [URL] {
        let directory = support.appendingPathComponent("journal", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().map {
            directory.appendingPathComponent($0)
        }
    }

    private func assertNoSecretsUnderSupport(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: support.path),
            "the app-support root must exist for the scan",
            file: file,
            line: line
        )
        for path in IntegrationFixtures.files(under: support) {
            let text = String(decoding: try Data(contentsOf: path), as: UTF8.self)
            for secret in secrets {
                XCTAssertFalse(
                    text.contains(secret),
                    "\(path.path) contains seeded content \"\(secret)\"",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertNoSecret(
        in error: Error,
        _ secret: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = String(describing: error)
        XCTAssertFalse(
            text.contains(secret),
            "error text leaked content: \(text)",
            file: file,
            line: line
        )
        if let installerError = error as? InstallerError {
            XCTAssertFalse(
                installerError.description.contains(secret),
                "error description leaked content",
                file: file,
                line: line
            )
        }
    }
}
