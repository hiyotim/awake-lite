import Darwin
import XCTest
@testable import AwakeLiteCore

/// Unit 2.2: installer core. Every test runs against temporary roots; nothing
/// reads or writes the real home directory.
final class InstallerTests: XCTestCase {
    private struct SimulatedCrash: Error {}

    private var sandbox: URL!
    private var home: URL!
    private var support: URL!
    private var applications: URL!
    private var catalog: Catalog!
    private var installer: Installer!

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
        installer = nil
        catalog = nil
        sandbox = nil
        home = nil
        support = nil
        applications = nil
        try super.tearDownWithError()
    }

    // MARK: - 1. Fresh install for each family

    func testFreshInstallForEveryFamily() throws {
        for family in IntegrationFixtures.families {
            let preview = try makePreview(family)
            XCTAssertTrue(preview.conflicts.isEmpty, "\(family): \(preview.conflicts)")
            XCTAssertFalse(preview.entries.isEmpty, "\(family) declares no owned entry")
            XCTAssertEqual(preview.activationGeneration, 1)
            XCTAssertNil(preview.previousGeneration)

            let receipt = try installer.apply(preview)
            XCTAssertEqual(receipt.schema, 1)
            XCTAssertEqual(receipt.family, family)
            XCTAssertEqual(receipt.stage, .committed)
            XCTAssertEqual(receipt.activationGeneration, 1)
            XCTAssertEqual(receipt.entries.count, preview.entries.count)
            XCTAssertEqual(
                Set(receipt.entries.map { "\($0.path)|\($0.marker)" }),
                Set(preview.entries.map { "\($0.path)|\($0.marker)" }),
                "receipt entries are exactly the planned owned entries"
            )

            for entry in receipt.entries {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: entry.path),
                    "\(family): missing \(entry.path)"
                )
                let text = try String(contentsOfFile: entry.path, encoding: .utf8)
                XCTAssertFalse(Template.containsPlaceholder(text), "\(family): placeholder left in \(entry.path)")
                XCTAssertTrue(text.contains(IntegrationPaths.helperPath), "\(family): helper path not rendered")
                XCTAssertTrue(text.contains(entry.marker), "\(family): marker not rendered")
            }

            XCTAssertTrue(journalFiles().isEmpty, "\(family): journal file left behind")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: support.appendingPathComponent("packages/\(family)/manifest.json").path)
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: support.appendingPathComponent("receipts/\(family).json").path)
            )
        }
    }

    func testPreviewWritesNothing() throws {
        try seedFile(at: home.appendingPathComponent(".claude/settings.json"), text: "{\"theme\":\"dark\"}\n")
        let before = tree(sandbox)
        let preview = try makePreview("claude-code")
        XCTAssertTrue(preview.conflicts.isEmpty)
        XCTAssertEqual(tree(sandbox), before, "preview must not write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    // MARK: - 2. Idempotent reinstall

    func testRepeatedInstallIsIdempotentAndIssuesNewGeneration() throws {
        let first = try install("claude-code")
        let settingsPath = try XCTUnwrap(first.entries.first?.path)
        let firstObject = try IntegrationFixtures.jsonObject(URL(fileURLWithPath: settingsPath))
        let firstAwake = try XCTUnwrap(firstObject["awakeLite"] as? [String: Any])
        XCTAssertEqual(firstAwake.count, 2)

        let second = try install("claude-code")
        XCTAssertEqual(second.activationGeneration, first.activationGeneration + 1)
        XCTAssertEqual(second.previousGeneration, first.activationGeneration)
        XCTAssertEqual(second.entries.count, first.entries.count)
        XCTAssertEqual(Set(second.entries.map(\.marker)), Set(first.entries.map(\.marker)))

        let secondObject = try IntegrationFixtures.jsonObject(URL(fileURLWithPath: settingsPath))
        let secondAwake = try XCTUnwrap(secondObject["awakeLite"] as? [String: Any])
        XCTAssertEqual(secondAwake.count, 2, "reinstall must not duplicate an entry")
        let text = try String(contentsOfFile: settingsPath, encoding: .utf8)
        XCTAssertTrue(text.contains("\"generation\": \"\(second.activationGeneration)\""))
        XCTAssertFalse(text.contains("\"generation\": \"\(first.activationGeneration)\""))
        XCTAssertTrue(journalFiles().isEmpty)
    }

    func testReinstallPreservesAForeignKeyInsideTheOwnedContainer() throws {
        _ = try install("claude-code")
        let settings = home.appendingPathComponent(".claude/settings.json")
        var object = try IntegrationFixtures.jsonObject(settings)
        var awake = try XCTUnwrap(object["awakeLite"] as? [String: Any])
        awake["user-note"] = "keep me"
        object["awakeLite"] = awake
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settings)

        let second = try install("claude-code")
        object = try IntegrationFixtures.jsonObject(settings)
        awake = try XCTUnwrap(object["awakeLite"] as? [String: Any])
        XCTAssertEqual(awake["user-note"] as? String, "keep me")
        XCTAssertEqual(awake.count, 3)
        XCTAssertEqual(second.activationGeneration, 2)

        _ = try installer.remove(family: "claude-code", appSupportRoot: support)
        object = try IntegrationFixtures.jsonObject(settings)
        awake = try XCTUnwrap(object["awakeLite"] as? [String: Any])
        XCTAssertEqual(awake.count, 1, "only our two markers are removed")
        XCTAssertEqual(awake["user-note"] as? String, "keep me")
    }

    func testRemovalAfterReinstallRemovesOnlyOwnedEntries() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try seedFile(at: settings, text: "{\n  \"foreign\": 1\n}\n")
        _ = try install("claude-code")
        _ = try install("claude-code")

        let report = try installer.remove(family: "claude-code", appSupportRoot: support)
        XCTAssertEqual(Set(report.removedPaths), [settings.path])
        let object = try IntegrationFixtures.jsonObject(settings)
        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(object["foreign"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL("claude-code").path))
    }

    func testForeignPluginFileSurvivesInstallAndRemoval() throws {
        let foreign = home.appendingPathComponent(".pi/agent/extensions/foreign.js")
        try seedFile(at: foreign, text: "// someone else's extension\n")

        let receipt = try install("pi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "// someone else's extension\n")

        _ = try installer.remove(family: "pi", appSupportRoot: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "// someone else's extension\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(receipt.entries.first?.path)))
    }

    func testRemovalRefusesAUserEditedJSONEntry() throws {
        let receipt = try install("claude-code")
        let settings = home.appendingPathComponent(".claude/settings.json")
        var object = try IntegrationFixtures.jsonObject(settings)
        var awake = try XCTUnwrap(object["awakeLite"] as? [String: Any])
        let marker = try XCTUnwrap(receipt.entries.first?.marker)
        awake[marker] = ["user": "replaced our entry"]
        object["awakeLite"] = awake
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settings)

        XCTAssertThrowsError(try installer.remove(family: "claude-code", appSupportRoot: support)) { error in
            guard case .conflicts? = error as? InstallerError else {
                return XCTFail("expected conflicts, got \(error)")
            }
        }
        let unchanged = try Data(contentsOf: settings)
        XCTAssertEqual(unchanged, data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL("claude-code").path))
    }

    // MARK: - 3. Foreign entries preserved

    func testInstallPreservesForeignHooksAndKeys() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        let foreign = """
        {
          "theme": "dark",
          "hooks": {
            "PreToolUse": [{"command": "echo foreign"}]
          },
          "awakeLite": {
            "foreign-entry": {"keep": true}
          }
        }
        """
        try seedFile(at: settings, text: foreign)

        let preview = try makePreview("claude-code")
        XCTAssertTrue(preview.conflicts.isEmpty, "\(preview.conflicts)")
        _ = try installer.apply(preview)

        let object = try IntegrationFixtures.jsonObject(settings)
        XCTAssertEqual(object["theme"] as? String, "dark")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["PreToolUse"] as? [Any])?.count, 1)
        let awake = try XCTUnwrap(object["awakeLite"] as? [String: Any])
        XCTAssertNotNil(awake["foreign-entry"])
        XCTAssertEqual(awake.count, 3, "two owned markers plus the foreign key")
        XCTAssertNotNil(awake["awake-lite/claude-code.cli/hooks"])
        XCTAssertNotNil(awake["awake-lite/claude-code.desktop/hooks"])
    }

    // MARK: - 4. Conflicts and unsupported formats

    func testUnsupportedFormatIsRefused() throws {
        let custom = try catalogCopy { manifest in
            var steps = manifest["steps"] as! [[String: Any]]
            steps[0]["format"] = "directory"
            steps[0].removeValue(forKey: "keyPath")
            manifest["steps"] = steps
        }
        let installer = Installer(catalog: custom)
        XCTAssertThrowsError(
            try installer.preview(
                family: "claude-code",
                configRoot: home,
                appSupportRoot: support,
                discovery: discovery()
            )
        ) { error in
            guard case .unsupportedFormat(let step, let format, _)? = error as? InstallerError else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
            XCTAssertEqual(step, 0)
            XCTAssertEqual(format, .directory)
        }
    }

    func testConflictingForeignMarkerFailsWithoutReplacingTheFile() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        let foreign = """
        {
          "awakeLite": {
            "awake-lite/claude-code.cli/hooks": "a foreign value"
          }
        }
        """
        try seedFile(at: settings, text: foreign)
        let before = try Data(contentsOf: settings)

        let preview = try makePreview("claude-code")
        XCTAssertFalse(preview.conflicts.isEmpty, "a foreign value at the marker must be a conflict")
        XCTAssertEqual(preview.entries.first?.action, .conflict)

        XCTAssertThrowsError(try installer.apply(preview))
        XCTAssertEqual(try Data(contentsOf: settings), before, "the foreign file must be untouched")
        XCTAssertTrue(journalFiles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL("claude-code").path))
    }

    func testMalformedJSONIsRefusedWithoutReplacement() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        let broken = "{\"hooks\": [ this is not json"
        try seedFile(at: settings, text: broken)
        let before = try Data(contentsOf: settings)

        let preview = try makePreview("claude-code")
        XCTAssertFalse(preview.conflicts.isEmpty)
        XCTAssertThrowsError(try installer.apply(preview))
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    // MARK: - 5. Symlinks

    func testSymlinkedConfigDirectoryIsRefused() throws {
        let target = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude"),
            withDestinationURL: target
        )

        XCTAssertThrowsError(try makePreview("claude-code")) { error in
            guard case .symlinked(let path)? = error as? InstallerError else {
                return XCTFail("expected symlinked error, got \(error)")
            }
            XCTAssertTrue(path.contains(".claude"))
        }
    }

    func testSymlinkedConfigFileIsRefused() throws {
        let real = home.appendingPathComponent("real/settings.json")
        try seedFile(at: real, text: "{}")
        let directory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("settings.json"),
            withDestinationURL: real
        )

        XCTAssertThrowsError(try makePreview("claude-code")) { error in
            guard case .symlinked? = error as? InstallerError else {
                return XCTFail("expected symlinked error, got \(error)")
            }
        }
    }

    // MARK: - 6. Stale preview

    func testStalePreviewIsRefusedBeforeAnyMutation() throws {
        let preview = try makePreview("claude-code")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try seedFile(at: settings, text: "{\"theme\":\"light\"}\n")
        let edited = try Data(contentsOf: settings)

        XCTAssertThrowsError(try installer.apply(preview)) { error in
            guard case .stalePreview? = error as? InstallerError else {
                return XCTFail("expected stalePreview, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: settings), edited)
        XCTAssertTrue(journalFiles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL("claude-code").path))
    }

    // MARK: - 7. Interruption and recovery

    func testInterruptionAfterEveryJournalStepRecovers() throws {
        let points: [InstallerFaultPoint] = [
            .journalWritten,
            .beforeStep(0),
            .afterStep(0),
            .beforeStep(1),
            .afterStep(1),
            .beforeReceipt,
            .afterReceipt
        ]
        for point in points {
            let fresh = try IntegrationFixtures.makeSandbox()
            defer { try? FileManager.default.removeItem(at: fresh) }
            let freshHome = fresh.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: freshHome, withIntermediateDirectories: true)
            let freshSupport = fresh.appendingPathComponent("support", isDirectory: true)

            let crashed = Installer(catalog: catalog, faults: { seen in
                if seen == point { throw SimulatedCrash() }
            })
            let preview = try installer.preview(
                family: "claude-code",
                configRoot: freshHome,
                appSupportRoot: freshSupport,
                discovery: ProductDiscovery(homeRoot: freshHome, applicationRoots: [applications])
            )
            XCTAssertTrue(preview.conflicts.isEmpty)
            XCTAssertThrowsError(try crashed.apply(preview), "fault \(point) should interrupt")
            XCTAssertEqual(
                journalFiles(in: freshSupport).count, 1,
                "fault \(point): journal must exist after an interruption"
            )

            let reports = try installer.recoverPending(appSupportRoot: freshSupport)
            XCTAssertEqual(reports.count, 1, "fault \(point)")
            let report = try XCTUnwrap(reports.first)
            XCTAssertNotEqual(report.outcome, .recoveryRequired, "fault \(point): \(report.conflicts)")
            XCTAssertTrue(journalFiles(in: freshSupport).isEmpty, "fault \(point): journal not cleared")

            let settings = freshHome.appendingPathComponent(".claude/settings.json")
            let markers = preview.entries.map(\.marker)
            let present = try markersPresent(in: settings, markers: markers)
            let receipt = try InstallerStorage(root: freshSupport).loadReceipt(family: "claude-code")

            switch report.outcome {
            case .forwardCommitted:
                XCTAssertEqual(present.count, markers.count, "fault \(point): forward commit incomplete")
                let receipt = try XCTUnwrap(receipt, "fault \(point): forward commit needs a receipt")
                XCTAssertEqual(receipt.stage, .committed)
                XCTAssertEqual(receipt.activationGeneration, 1)
            case .rolledBack:
                XCTAssertTrue(present.isEmpty, "fault \(point): rollback left owned entries")
                XCTAssertNil(receipt)
            case .recoveryRequired:
                XCTFail("fault \(point): unexpected recoveryRequired")
            }

            // The package is installable again and consistent afterwards.
            let retry = try installer.preview(
                family: "claude-code",
                configRoot: freshHome,
                appSupportRoot: freshSupport,
                discovery: ProductDiscovery(homeRoot: freshHome, applicationRoots: [applications])
            )
            XCTAssertTrue(retry.conflicts.isEmpty, "fault \(point): \(retry.conflicts)")
            let final = try installer.apply(retry)
            XCTAssertEqual(final.stage, .committed)
            XCTAssertEqual(
                try markersPresent(in: settings, markers: markers).count,
                markers.count,
                "fault \(point): final install incomplete"
            )
            XCTAssertTrue(journalFiles(in: freshSupport).isEmpty)
        }
    }

    func testJournalFileNameCarriesAMonotonicOperationId() throws {
        let crashed = Installer(catalog: catalog, faults: { point in
            if point == .afterStep(0) { throw SimulatedCrash() }
        })
        let preview = try makePreview("claude-code")
        XCTAssertThrowsError(try crashed.apply(preview))
        let names = journalFiles().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(
            name.range(of: #"^\d{20}-[0-9a-f]{16}\.json$"#, options: .regularExpression) != nil,
            "unexpected journal name \(name)"
        )
        _ = try installer.recoverPending(appSupportRoot: support)
    }

    // MARK: - 8. Rollback refuses a user edit

    func testRollbackRefusesUserEditedFile() throws {
        let crashed = Installer(catalog: catalog, faults: { point in
            if point == .beforeStep(1) { throw SimulatedCrash() }
        })
        let preview = try makePreview("claude-code")
        XCTAssertThrowsError(try crashed.apply(preview))

        let settings = home.appendingPathComponent(".claude/settings.json")
        let object = try IntegrationFixtures.jsonObject(settings)
        var edited = object
        edited["userEdit"] = "made after the interruption"
        let data = try JSONSerialization.data(withJSONObject: edited, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settings)

        let reports = try installer.recoverPending(appSupportRoot: support)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.outcome, .recoveryRequired)
        XCTAssertFalse(report.conflicts.isEmpty)
        XCTAssertTrue(report.conflicts.joined().contains(settings.path))
        XCTAssertEqual(try Data(contentsOf: settings), data, "a user edit must never be overwritten")
        XCTAssertEqual(journalFiles().count, 1, "an unresolved operation stays on disk")

        // A new operation is blocked until the conflict is resolved.
        let next = try makePreview("claude-code")
        XCTAssertFalse(next.conflicts.isEmpty)
        XCTAssertThrowsError(try installer.apply(next)) { error in
            guard case .blockedByRecovery? = error as? InstallerError else {
                return XCTFail("expected blockedByRecovery, got \(error)")
            }
        }
    }

    // MARK: - 9. Removal

    func testRemovalPreservesForeignEntriesAndDeletesCreatedFiles() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try seedFile(
            at: settings,
            text: "{\n  \"theme\": \"dark\",\n  \"hooks\": {\"Stop\": [{\"command\": \"other\"}]}\n}\n"
        )
        _ = try install("claude-code")

        let report = try installer.remove(family: "claude-code", appSupportRoot: support)
        XCTAssertFalse(report.removedPaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL("claude-code").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: support.appendingPathComponent("packages/claude-code").path)
        )
        XCTAssertTrue(journalFiles().isEmpty)

        let object = try IntegrationFixtures.jsonObject(settings)
        XCTAssertEqual(object["theme"] as? String, "dark")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 1)
        XCTAssertNil(object["awakeLite"], "the empty app-owned container is pruned")
    }

    func testRemovalDeletesAppCreatedCopyAndDirectories() throws {
        let receipt = try install("pi")
        let file = try XCTUnwrap(receipt.entries.first?.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        XCTAssertTrue(receipt.entries.allSatisfy(\.createdFile))

        let report = try installer.remove(family: "pi", appSupportRoot: support)
        XCTAssertTrue(report.removedPaths.contains(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path),
            "directories created by the install are removed when empty"
        )
    }

    func testRemovalRefusesToDestroyAUserEditedEntry() throws {
        let receipt = try install("pi")
        let file = URL(fileURLWithPath: try XCTUnwrap(receipt.entries.first?.path))
        let edited = "// user edited after installation\n"
        try Data(edited.utf8).write(to: file)

        XCTAssertThrowsError(try installer.remove(family: "pi", appSupportRoot: support)) { error in
            guard case .conflicts(let conflicts)? = error as? InstallerError else {
                return XCTFail("expected conflicts, got \(error)")
            }
            XCTAssertTrue(conflicts.joined().contains(file.path))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL("pi").path), "receipt stays for a retry")
        XCTAssertTrue(journalFiles().isEmpty, "nothing is mutated when the pre-check fails")
    }

    // MARK: - Block format

    func testTOMLBlockInstallReinstallAndRemoval() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        let foreign = "model = \"gpt-5\"\napproval_policy = \"on-request\"\n"
        try seedFile(at: config, text: foreign)

        _ = try install("codex")
        var text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(foreign), "foreign bytes must be preserved")
        XCTAssertEqual(occurrences(of: ">>> awake-lite BEGIN", in: text), 2)
        XCTAssertTrue(text.contains("generation=1"))
        XCTAssertTrue(text.contains(IntegrationPaths.helperPath))

        let second = try install("codex")
        text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(foreign))
        XCTAssertEqual(occurrences(of: ">>> awake-lite BEGIN", in: text), 2, "no duplicate block")
        XCTAssertTrue(text.contains("generation=\(second.activationGeneration)"))

        _ = try installer.remove(family: "codex", appSupportRoot: support)
        let restored = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(restored, foreign, "removal restores the foreign bytes exactly")
    }

    func testDuplicatedBlockIsAConflict() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        let seed = """
        model = "gpt-5"
        # >>> awake-lite BEGIN awake-lite/codex.cli/hooks generation=1
        marker = "x"
        # <<< awake-lite END awake-lite/codex.cli/hooks
        # >>> awake-lite BEGIN awake-lite/codex.cli/hooks generation=1
        marker = "x"
        # <<< awake-lite END awake-lite/codex.cli/hooks
        """
        try seedFile(at: config, text: seed)
        let preview = try makePreview("codex")
        XCTAssertFalse(preview.conflicts.isEmpty)
        XCTAssertThrowsError(try installer.apply(preview))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), seed)
    }

    // MARK: - Copy steps

    func testCopyStepRendersTemplateAndRemovalCleansUp() throws {
        let receipt = try install("pi")
        let entry = try XCTUnwrap(receipt.entries.first)
        let text = try String(contentsOfFile: entry.path, encoding: .utf8)
        XCTAssertFalse(Template.containsPlaceholder(text))
        XCTAssertTrue(text.contains(IntegrationPaths.helperPath))
        XCTAssertTrue(text.contains(entry.marker))
        XCTAssertTrue(text.contains("\"\(entry.target)\""))
        XCTAssertTrue(entry.createdFile)

        _ = try installer.remove(family: "pi", appSupportRoot: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
    }

    func testCopyStepReinstallIsIdempotentAndRemovable() throws {
        let first = try install("pi")
        let file = try XCTUnwrap(first.entries.first?.path)
        let firstText = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(firstText.contains("generation: \"1\""))

        let second = try install("pi")
        XCTAssertEqual(second.activationGeneration, 2)
        XCTAssertEqual(second.previousGeneration, 1)
        let secondText = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(secondText.contains("generation: \"2\""))
        XCTAssertFalse(secondText.contains("generation: \"1\""))

        let directory = URL(fileURLWithPath: file).deletingLastPathComponent()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
            1,
            "reinstall must not leave a second file behind"
        )
        XCTAssertTrue(journalFiles().isEmpty)

        _ = try installer.remove(family: "pi", appSupportRoot: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    // MARK: - Privacy (matrix 11)

    func testReceiptsAndJournalsContainNoConversationContent() throws {
        let secrets = [
            "PROMPT-secret-42",
            "response-text-abc",
            "tool-arguments-xyz",
            "sk-live-0000"
        ]
        let settings = home.appendingPathComponent(".claude/settings.json")
        try seedFile(
            at: settings,
            text: "{\n  \"prompt\": \"\(secrets[0])\",\n  \"response\": \"\(secrets[1])\",\n"
                + "  \"tool\": \"\(secrets[2])\",\n  \"key\": \"\(secrets[3])\"\n}\n"
        )

        // Capture an in-flight journal by interrupting after the first step.
        let crashed = Installer(catalog: catalog, faults: { point in
            if point == .afterStep(0) { throw SimulatedCrash() }
        })
        let preview = try makePreview("claude-code")
        XCTAssertThrowsError(try crashed.apply(preview))
        try assertNoSecrets(secrets, under: support)

        _ = try installer.recoverPending(appSupportRoot: support)
        _ = try install("claude-code")
        try assertNoSecrets(secrets, under: support)

        let receipt = try String(contentsOf: receiptURL("claude-code"), encoding: .utf8)
        XCTAssertFalse(receipt.contains("prompt"))
        XCTAssertFalse(receipt.contains("response"))
    }

    // MARK: - Storage hygiene

    func testNoFilesOutsideInjectedRootsAreCreated() throws {
        let before = tree(sandbox)
        let preview = try makePreview("claude-code")
        let homePath = home.resolvingSymlinksInPath().path
        let supportPath = support.resolvingSymlinksInPath().path
        for path in preview.paths {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            XCTAssertTrue(
                resolved.hasPrefix(homePath) || resolved.hasPrefix(supportPath),
                "planned path escapes the injected roots: \(path)"
            )
        }
        _ = try installer.apply(preview)
        _ = try install("pi")

        let after = tree(sandbox)
        let created = after.subtracting(before)
        XCTAssertFalse(created.isEmpty)
        // The temporary root may be a symlink target (`/var` -> `/private/var`),
        // so compare resolved paths.
        for path in created {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            XCTAssertTrue(
                resolved.hasPrefix(homePath) || resolved.hasPrefix(supportPath),
                "unexpected path outside the injected roots: \(path)"
            )
        }
    }

    func testStorageUsesOwnerOnlyPermissions() throws {
        _ = try install("claude-code")
        let directories: [URL] = [
            support,
            support.appendingPathComponent("packages"),
            support.appendingPathComponent("receipts"),
            support.appendingPathComponent("journal")
        ]
        for directory in directories {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o700, "\(directory.path)")
        }
        let receipt = try FileManager.default.attributesOfItem(atPath: receiptURL("claude-code").path)
        XCTAssertEqual((receipt[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777, 0o600)
        for path in tree(support) where !isDirectory(path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(permissions & 0o077, 0, "\(path) is group/world accessible")
        }
    }

    // MARK: - Helpers

    private func discovery() -> ProductDiscovery {
        ProductDiscovery(homeRoot: home, applicationRoots: [applications])
    }

    private func makePreview(_ family: String) throws -> InstallPreview {
        let preview = try installer.preview(
            family: family,
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertEqual(preview.plan.family, family)
        return preview
    }

    @discardableResult
    private func install(_ family: String) throws -> InstallReceipt {
        let preview = try makePreview(family)
        XCTAssertTrue(preview.conflicts.isEmpty, "\(family): \(preview.conflicts)")
        let receipt = try installer.apply(preview)
        XCTAssertEqual(receipt.activationGeneration, preview.activationGeneration)
        return receipt
    }

    private func receiptURL(_ family: String) -> URL {
        support.appendingPathComponent("receipts/\(family).json")
    }

    private func journalFiles(in root: URL? = nil) -> [URL] {
        let directory = (root ?? support).appendingPathComponent("journal", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().map {
            directory.appendingPathComponent($0)
        }
    }

    private func seedFile(at url: URL, text: String) throws {
        try IntegrationFixtures.write(text, to: url)
    }

    private func markersPresent(in file: URL, markers: [String]) throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let text = try String(contentsOf: file, encoding: .utf8)
        return markers.filter { text.contains($0) }
    }

    private func tree(_ root: URL) -> Set<String> {
        var result: Set<String> = [root.path]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                result.insert(url.path)
            }
        }
        return result
    }

    private func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func assertNoSecrets(
        _ secrets: [String],
        under root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for path in IntegrationFixtures.files(under: root) {
            let data = try Data(contentsOf: path)
            let text = String(decoding: data, as: UTF8.self)
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

    /// Copies the bundled catalog into the sandbox so one manifest can be made
    /// deliberately non-conforming without touching Resources/.
    private func catalogCopy(
        mutating family: String = "claude-code",
        _ change: (inout [String: Any]) -> Void
    ) throws -> Catalog {
        let root = sandbox.appendingPathComponent("catalog-copy", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in IntegrationFixtures.families {
            try FileManager.default.copyItem(
                at: IntegrationFixtures.integrationsRoot.appendingPathComponent(name, isDirectory: true),
                to: root.appendingPathComponent(name, isDirectory: true)
            )
        }
        let manifestURL = root.appendingPathComponent("\(family)/manifest.json")
        var manifest = try IntegrationFixtures.jsonObject(manifestURL)
        change(&manifest)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL)
        return try Catalog(loading: root)
    }
}
