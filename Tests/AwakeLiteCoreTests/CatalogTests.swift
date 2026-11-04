import Darwin
import XCTest
@testable import AwakeLiteCore

/// Unit 2.1: manifest schema 1, loader, catalog, discovery.
final class CatalogTests: XCTestCase {
    /// The single source of truth for shipped verification levels.
    ///
    /// A level is declared data (ARCHITECTURE, "Package manifest"): it is raised
    /// only by an adapter fixture or a recorded live check, never by discovery
    /// and never by the presence of an installed product. Four targets have
    /// adapter fixtures after Stage 3 (units 3.2–3.4); the remaining six,
    /// including both desktop-only and not-yet-adapter families, stay
    /// `unverified` because no fixture or live check exists for them.
    static let expectedVerificationLevels: [String: VerificationLevel] = [
        "antigravity.cli": .unverified,
        "antigravity.desktop": .unverified,
        "claude-code.cli": .unverified,
        "claude-code.desktop": .unverified,
        "codex.cli": .fixture,
        "codex.desktop": .unverified,
        "cursor.desktop": .unverified,
        "omp.cli": .fixture,
        "opencode.tui": .fixture,
        "pi.cli": .fixture
    ]

    // MARK: - Bundled catalog

    func testBundledCatalogDecodesAllSevenFamilies() throws {
        let catalog = try IntegrationFixtures.bundledCatalog()

        XCTAssertEqual(catalog.familyNames, IntegrationFixtures.families)
        XCTAssertEqual(catalog.allManifests.count, 7)
        for family in IntegrationFixtures.families {
            let manifest = try catalog.manifest(for: family)
            XCTAssertEqual(manifest.schema, 1)
            XCTAssertEqual(manifest.family, family, "family must match its directory")
            XCTAssertFalse(manifest.displayName.isEmpty)
            XCTAssertFalse(manifest.packageVersion.isEmpty)
            XCTAssertFalse(manifest.targets.isEmpty)
            XCTAssertFalse(manifest.steps.isEmpty)
            XCTAssertFalse(manifest.assets.isEmpty)
            for target in manifest.targets {
                XCTAssertTrue(target.id.hasPrefix("\(family)."), "target \(target.id) has the wrong prefix")
                let expected = try XCTUnwrap(
                    Self.expectedVerificationLevels[target.id],
                    "target \(target.id) has no recorded level"
                )
                XCTAssertEqual(target.verificationLevel, expected, "target \(target.id) must declare its recorded level")
            }
            for step in manifest.steps {
                XCTAssertNotNil(manifest.target(withID: step.target))
                for entry in step.ownedEntries {
                    XCTAssertNotNil(manifest.asset(withID: entry.asset))
                }
            }
        }
    }

    func testCatalogDeclaresExactlyTheTenCompatibilityTargets() throws {
        let catalog = try IntegrationFixtures.bundledCatalog()
        XCTAssertEqual(catalog.compatibilityTargetIDs, IntegrationFixtures.targetIDs.sorted())
        XCTAssertEqual(catalog.compatibilityTargets.count, 10)

        let modes = Dictionary(
            uniqueKeysWithValues: catalog.compatibilityTargets.map { ($0.id, $0.mode) }
        )
        XCTAssertEqual(modes["claude-code.cli"], .cli)
        XCTAssertEqual(modes["claude-code.desktop"], .desktop)
        XCTAssertEqual(modes["codex.cli"], .cli)
        XCTAssertEqual(modes["codex.desktop"], .desktop)
        XCTAssertEqual(modes["cursor.desktop"], .desktop)
        XCTAssertEqual(modes["antigravity.cli"], .cli)
        XCTAssertEqual(modes["antigravity.desktop"], .desktop)
        XCTAssertEqual(modes["pi.cli"], .cli)
        XCTAssertEqual(modes["omp.cli"], .cli)
        XCTAssertEqual(modes["opencode.tui"], .cli)
    }

    /// The declared matrix is data, so the whole table is asserted at once: a
    /// level that moves without an accompanying fixture or live check, and a
    /// new target that appears without a recorded level, both fail here.
    func testBundledTargetsDeclareTheRecordedVerificationLevels() throws {
        let catalog = try IntegrationFixtures.bundledCatalog()
        let declared = Dictionary(
            uniqueKeysWithValues: catalog.compatibilityTargets.map { ($0.id, $0.verificationLevel) }
        )

        XCTAssertEqual(Set(declared.keys), Set(Self.expectedVerificationLevels.keys))
        XCTAssertEqual(declared, Self.expectedVerificationLevels)
        XCTAssertEqual(declared.values.filter { $0 == .fixture }.count, 4, "pi, omp, opencode, and codex.cli have fixtures")
        XCTAssertFalse(declared.values.contains(.live), "no target has a recorded live acceptance yet")
        XCTAssertEqual(declared["codex.desktop"], .unverified, "desktop delivery is unproven")
    }

    func testCatalogExposesRestartAndTrustFlags() throws {
        let catalog = try IntegrationFixtures.bundledCatalog()
        XCTAssertTrue(try catalog.manifest(for: "codex").requiresRestart)
        XCTAssertTrue(try catalog.manifest(for: "codex").requiresHookTrust)
        XCTAssertFalse(try catalog.manifest(for: "claude-code").requiresHookTrust)
        XCTAssertFalse(try catalog.manifest(for: "claude-code").notes.isEmpty)
    }

    // MARK: - Discovery

    /// Discovery reads files only. The family used here has one `fixture` target
    /// and one `unverified` target, so the check compares discovered status
    /// against the manifest value instead of a blanket expectation: appearing on
    /// disk neither raises nor lowers a declared level.
    func testDiscoveryReportsAvailabilityWithoutRaisingVerification() throws {
        let sandbox = try IntegrationFixtures.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let applications = sandbox.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        let catalog = try IntegrationFixtures.bundledCatalog()
        let discovery = ProductDiscovery(homeRoot: home, applicationRoots: [applications])
        let declared = Dictionary(
            uniqueKeysWithValues: try catalog.manifest(for: "codex").targets.map { ($0.id, $0.verificationLevel) }
        )
        XCTAssertEqual(declared["codex.cli"], .fixture)
        XCTAssertEqual(declared["codex.desktop"], .unverified)

        let before = try catalog.targetStatuses(for: "codex", discovery: discovery)
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.allSatisfy { !$0.isAvailable })
        XCTAssertTrue(before.allSatisfy { $0.verificationLevel == declared[$0.id] })
        XCTAssertTrue(
            before.flatMap(\.searchedPaths).allSatisfy {
                $0.hasPrefix(home.path) || $0.hasPrefix(applications.path)
            },
            "discovery must not look outside the injected roots"
        )

        // A CLI binary and a desktop application bundle appear.
        let binary = home.appendingPathComponent(".local/bin/codex")
        try IntegrationFixtures.write("#!/bin/sh\n", to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let appInfo = applications.appendingPathComponent("Codex.app/Contents/Info.plist")
        try IntegrationFixtures.write("<plist/>", to: appInfo)

        let after = try catalog.targetStatuses(for: "codex", discovery: discovery)
        let cli = try XCTUnwrap(after.first { $0.id == "codex.cli" })
        let desktop = try XCTUnwrap(after.first { $0.id == "codex.desktop" })
        XCTAssertTrue(cli.isAvailable)
        XCTAssertTrue(cli.presentPaths.contains(binary.path))
        XCTAssertTrue(desktop.isAvailable)
        XCTAssertTrue(desktop.presentPaths.contains(applications.appendingPathComponent("Codex.app").path))
        // Discovery never raises a verification level: each status still reports
        // exactly what the manifest declares.
        XCTAssertEqual(cli.verificationLevel, declared["codex.cli"])
        XCTAssertEqual(desktop.verificationLevel, declared["codex.desktop"])
        XCTAssertEqual(cli.verificationLevel, .fixture)
        XCTAssertEqual(desktop.verificationLevel, .unverified)
    }

    func testDiscoveryIgnoresNonExecutableFileAndBrokenAppBundle() throws {
        let sandbox = try IntegrationFixtures.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let applications = sandbox.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        // Present but not executable.
        let binary = home.appendingPathComponent(".local/bin/codex")
        try IntegrationFixtures.write("not a program\n", to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        // A directory named like an app without an Info.plist.
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("Codex.app"),
            withIntermediateDirectories: true
        )

        let catalog = try IntegrationFixtures.bundledCatalog()
        let discovery = ProductDiscovery(homeRoot: home, applicationRoots: [applications])
        let statuses = try catalog.targetStatuses(for: "codex", discovery: discovery)
        XCTAssertTrue(statuses.allSatisfy { !$0.isAvailable })
        // An unusable candidate is absence; it never edits the declared level.
        for status in statuses {
            XCTAssertEqual(status.verificationLevel, Self.expectedVerificationLevels[status.id])
        }
    }

    func testDiscoveryHasDocumentedCandidatesForEveryTarget() throws {
        let catalog = try IntegrationFixtures.bundledCatalog()
        for id in catalog.compatibilityTargetIDs {
            XCTAssertFalse(
                (ProductDiscovery.candidates[id] ?? []).isEmpty,
                "target \(id) has no documented install location"
            )
        }
    }

    // MARK: - Manifest rejection

    func testUnknownSchemaIsRejected() throws {
        var manifest = baseManifest()
        manifest["schema"] = 2
        try assertManifestError(manifest, field: "schema")
    }

    func testFamilyMustMatchDirectory() throws {
        var manifest = baseManifest()
        manifest["family"] = "other"
        try assertManifestError(manifest, field: "family")
    }

    func testEmptyDisplayNameIsRejected() throws {
        var manifest = baseManifest()
        manifest["displayName"] = ""
        try assertManifestError(manifest, field: "displayName")
    }

    func testEmptyPackageVersionIsRejected() throws {
        var manifest = baseManifest()
        manifest["packageVersion"] = ""
        try assertManifestError(manifest, field: "packageVersion")
    }

    func testUnknownTopLevelKeyIsRejected() throws {
        var manifest = baseManifest()
        manifest["command"] = "curl example.com"
        try assertManifestError(manifest, field: "command")
    }

    func testMissingRequiredTopLevelKeyIsRejected() throws {
        var manifest = baseManifest()
        manifest.removeValue(forKey: "requiresRestart")
        try assertManifestError(manifest, field: "requiresRestart")
    }

    func testTargetsMustNotBeEmpty() throws {
        var manifest = baseManifest()
        manifest["targets"] = []
        try assertManifestError(manifest, field: "targets")
    }

    func testDuplicateTargetIDIsRejected() throws {
        var manifest = baseManifest()
        var targets = manifest["targets"] as! [[String: Any]]
        targets.append(targets[0])
        manifest["targets"] = targets
        try assertManifestError(manifest, field: "targets[1].id")
    }

    func testTargetIDMustCarryTheFamilyPrefix() throws {
        var manifest = baseManifest()
        var targets = manifest["targets"] as! [[String: Any]]
        targets[0]["id"] = "probecli"
        manifest["targets"] = targets
        try assertManifestError(manifest, field: "targets[0].id")
    }

    func testUnknownModeIsRejected() throws {
        var manifest = baseManifest()
        var targets = manifest["targets"] as! [[String: Any]]
        targets[0]["mode"] = "daemon"
        manifest["targets"] = targets
        try assertManifestError(manifest, field: "targets[0].mode")
    }

    func testUnknownVerificationLevelIsRejected() throws {
        var manifest = baseManifest()
        var targets = manifest["targets"] as! [[String: Any]]
        targets[0]["verificationLevel"] = "certified"
        manifest["targets"] = targets
        try assertManifestError(manifest, field: "targets[0].verificationLevel")
    }

    func testUnknownCapabilityIsRejected() throws {
        var manifest = baseManifest()
        var targets = manifest["targets"] as! [[String: Any]]
        targets[0]["capabilities"] = ["shellExecution"]
        manifest["targets"] = targets
        try assertManifestError(manifest, field: "targets[0].capabilities[0]")
    }

    func testUnknownTargetKeyIsRejected() throws {
        var manifest = baseManifest()
        var targets = manifest["targets"] as! [[String: Any]]
        targets[0]["command"] = "run"
        manifest["targets"] = targets
        try assertManifestError(manifest, field: "targets[0].command")
    }

    func testDuplicateAssetIDIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        var second = assets[0]
        second["source"] = "assets/second.json"
        second["destination"] = "hooks/second.json"
        assets.append(second)
        manifest["assets"] = assets
        try assertManifestError(
            manifest,
            field: "assets[1].id",
            assets: ["assets/template.json": "{\"probe\":true}", "assets/second.json": "{}"]
        )
    }

    func testAbsoluteAssetSourceIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        assets[0]["source"] = "/etc/passwd"
        manifest["assets"] = assets
        try assertManifestError(manifest, field: "assets[0].source")
    }

    func testEscapingAssetSourceIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        assets[0]["source"] = "../manifest.json"
        manifest["assets"] = assets
        try assertManifestError(manifest, field: "assets[0].source")
    }

    func testMissingAssetFileIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        assets[0]["source"] = "assets/absent.json"
        manifest["assets"] = assets
        try assertManifestError(manifest, field: "assets[0].source")
    }

    func testAbsoluteAssetDestinationIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        assets[0]["destination"] = "/tmp/out.json"
        manifest["assets"] = assets
        try assertManifestError(manifest, field: "assets[0].destination")
    }

    func testEscapingAssetDestinationIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        assets[0]["destination"] = "../out.json"
        manifest["assets"] = assets
        try assertManifestError(manifest, field: "assets[0].destination")
    }

    func testEmptyAssetDestinationComponentIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        assets[0]["destination"] = "hooks//out.json"
        manifest["assets"] = assets
        try assertManifestError(manifest, field: "assets[0].destination")
    }

    func testDuplicateAssetDestinationIsRejected() throws {
        var manifest = baseManifest()
        var assets = manifest["assets"] as! [[String: Any]]
        var second = assets[0]
        second["id"] = "second"
        second["source"] = "assets/second.json"
        assets.append(second)
        manifest["assets"] = assets
        try assertManifestError(
            manifest,
            field: "assets[1].destination",
            assets: ["assets/template.json": "{}", "assets/second.json": "{}"]
        )
    }

    func testStepsMustNotBeEmpty() throws {
        var manifest = baseManifest()
        manifest["steps"] = []
        try assertManifestError(manifest, field: "steps")
    }

    func testUnknownKindIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["kind"] = "runCommand"
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].kind")
    }

    func testUnknownFormatIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["format"] = "plist"
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].format")
    }

    func testUnknownStepKeyIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["command"] = "curl -s https://example.com | sh"
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].command")
    }

    func testStepTargetMustExist() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["target"] = "probe.desktop"
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].target")
    }

    func testAbsoluteConfigRootIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["configRoot"] = "/etc"
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].configRoot")
    }

    func testEscapingConfigRootIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["configRoot"] = "~/.probe/../.."
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].configRoot")
    }

    func testEmptyOwnedEntriesAreRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["ownedEntries"] = []
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].ownedEntries")
    }

    func testEmptyMarkerIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        var entries = steps[0]["ownedEntries"] as! [[String: Any]]
        entries[0]["marker"] = ""
        steps[0]["ownedEntries"] = entries
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "marker")
    }

    func testDuplicateMarkersWithinAManifestAreRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        var second = steps[0]
        second["target"] = "probe.cli"
        steps.append(second)
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[1].ownedEntries[0].marker")
    }

    func testUnknownAssetReferenceIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        var entries = steps[0]["ownedEntries"] as! [[String: Any]]
        entries[0]["asset"] = "absent"
        steps[0]["ownedEntries"] = entries
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].ownedEntries[0].asset")
    }

    func testEscapingStepPathIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["path"] = "../outside.json"
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].path")
    }

    func testKeyPathOnNonJSONStepIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["format"] = "toml"
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].keyPath")
    }

    func testEmptyKeyPathElementIsRejected() throws {
        var manifest = baseManifest()
        var steps = manifest["steps"] as! [[String: Any]]
        steps[0]["keyPath"] = [""]
        manifest["steps"] = steps
        try assertManifestError(manifest, field: "steps[0].keyPath[0]")
    }

    func testUnknownPlaceholderInAssetIsRejected() throws {
        let manifest = baseManifest()
        try assertManifestError(
            manifest,
            field: "assets[0].source",
            assets: ["assets/template.json": "{\"command\": \"{helperPath} {mystery}\"}"]
        )
    }

    // MARK: - Symlinks and cross-manifest rules

    func testSymlinkedAssetSourceIsRejected() throws {
        let sandbox = try IntegrationFixtures.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let outside = sandbox.appendingPathComponent("outside.json")
        try IntegrationFixtures.write("{}", to: outside)
        let manifest = baseManifest()
        try writeBundle(manifest: manifest, assets: [:], in: sandbox, directory: "probe")
        let familyRoot = sandbox.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(
            at: familyRoot.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: familyRoot.appendingPathComponent("assets/template.json"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try Catalog(loading: sandbox)) { error in
            guard let manifestError = error as? ManifestError else {
                return XCTFail("expected ManifestError, got \(error)")
            }
            XCTAssertEqual(manifestError.field, "assets[0].source")
            XCTAssertTrue(manifestError.description.contains("probe/manifest.json"))
        }
    }

    func testSymlinkedAssetDirectoryIsRejected() throws {
        let sandbox = try IntegrationFixtures.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let outside = sandbox.appendingPathComponent("assets", isDirectory: true)
        try IntegrationFixtures.write("{}", to: outside.appendingPathComponent("template.json"))
        let manifest = baseManifest()
        try writeBundle(manifest: manifest, assets: [:], in: sandbox, directory: "probe")
        let familyRoot = sandbox.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: familyRoot.appendingPathComponent("assets"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try Catalog(loading: sandbox)) { error in
            guard let manifestError = error as? ManifestError else {
                return XCTFail("expected ManifestError, got \(error)")
            }
            XCTAssertEqual(manifestError.field, "assets[0].source")
        }
    }

    func testDuplicateMarkerAcrossFamiliesIsRejected() throws {
        let sandbox = try IntegrationFixtures.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var first = baseManifest(family: "probe")
        var steps = first["steps"] as! [[String: Any]]
        var entries = steps[0]["ownedEntries"] as! [[String: Any]]
        entries[0]["marker"] = "awake-lite/shared/marker"
        steps[0]["ownedEntries"] = entries
        first["steps"] = steps
        try writeBundle(manifest: first, assets: ["assets/template.json": "{}"], in: sandbox)

        var second = baseManifest(family: "second")
        var secondSteps = second["steps"] as! [[String: Any]]
        secondSteps[0]["target"] = "second.cli"
        var secondEntries = secondSteps[0]["ownedEntries"] as! [[String: Any]]
        secondEntries[0]["marker"] = "awake-lite/shared/marker"
        secondSteps[0]["ownedEntries"] = secondEntries
        second["steps"] = secondSteps
        try writeBundle(
            manifest: second,
            assets: ["assets/template.json": "{}"],
            in: sandbox
        )

        XCTAssertThrowsError(try Catalog(loading: sandbox)) { error in
            guard let catalogError = error as? CatalogError else {
                return XCTFail("expected CatalogError, got \(error)")
            }
            guard case .duplicateMarker(let marker, _, _) = catalogError else {
                return XCTFail("unexpected error \(catalogError)")
            }
            XCTAssertEqual(marker, "awake-lite/shared/marker")
            XCTAssertTrue(catalogError.description.contains("probe/manifest.json"))
        }
    }

    func testEmptyCatalogRootIsRejected() throws {
        let sandbox = try IntegrationFixtures.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        XCTAssertThrowsError(try Catalog(loading: sandbox))
        XCTAssertThrowsError(try Catalog(loading: sandbox.appendingPathComponent("absent")))
    }

    // MARK: - Fixtures

    func baseManifest(family: String = "probe") -> [String: Any] {
        [
            "schema": 1,
            "family": family,
            "displayName": "Probe",
            "packageVersion": "1",
            "requiresRestart": false,
            "requiresHookTrust": false,
            "notes": ["fixture package"],
            "targets": [[
                "id": "\(family).cli",
                "mode": "cli",
                "capabilities": ["lifecycleHooks"],
                "verificationLevel": "unverified"
            ]],
            "assets": [[
                "id": "hooks",
                "source": "assets/template.json",
                "destination": "hooks/template.json"
            ]],
            "steps": [[
                "kind": "hookConfig",
                "target": "\(family).cli",
                "format": "json",
                "configRoot": "~/.\(family)",
                "path": "settings.json",
                "keyPath": ["awakeLite"],
                "ownedEntries": [[
                    "marker": "awake-lite/\(family).cli/hooks",
                    "asset": "hooks"
                ]]
            ]]
        ]
    }

    private func writeBundle(
        manifest: [String: Any],
        assets: [String: String],
        in root: URL,
        directory: String? = nil
    ) throws {
        let family = directory ?? manifest["family"] as! String
        let familyRoot = root.appendingPathComponent(family, isDirectory: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: familyRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: familyRoot.appendingPathComponent("manifest.json"))
        for (path, content) in assets {
            try IntegrationFixtures.write(content, to: familyRoot.appendingPathComponent(path))
        }
    }

    private func assertManifestError(
        _ manifest: [String: Any],
        field: String,
        assets: [String: String] = ["assets/template.json": "{\"probe\":true}"],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sandbox = try IntegrationFixtures.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try writeBundle(manifest: manifest, assets: assets, in: sandbox, directory: "probe")

        do {
            _ = try Catalog(loading: sandbox)
            XCTFail("manifest was accepted; expected rejection at \(field)", file: file, line: line)
        } catch let error as ManifestError {
            XCTAssertTrue(
                error.description.contains("probe/manifest.json"),
                "message must name the manifest: \(error.description)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                error.field.contains(field),
                "message must name field \(field), got \(error.description)",
                file: file,
                line: line
            )
        } catch {
            XCTFail("expected ManifestError, got \(error)", file: file, line: line)
        }
    }
}
