import Darwin
import XCTest
@testable import AwakeLiteCore

/// Helper-path injection: every rendered asset uses the value the caller
/// supplies, the documented constant stays the library default, `apply`
/// refuses a preview built with another value, and a receipt written with the
/// old constant still removes.
///
/// Every test runs against temporary roots; nothing reads or writes the real
/// home directory, and no app is launched.
final class HelperPathTests: XCTestCase {
    private var sandbox: URL!
    private var home: URL!
    private var support: URL!
    private var applications: URL!
    private var catalog: Catalog!

    /// A path that exists nowhere: the installer renders what the caller
    /// supplies and never probes it, so tests stay hermetic.
    private let injectedHelperPath =
        "/opt/awake-lite-fixture/AwakeLite.app/Contents/MacOS/AwakeLiteHelper"
    private let otherHelperPath =
        "/opt/awake-lite-other/AwakeLite.app/Contents/MacOS/AwakeLiteHelper"

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
        catalog = try IntegrationFixtures.fixtureCatalog()
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
        try super.tearDownWithError()
    }

    // MARK: - Injected value reaches every rendered asset

    func testInjectedHelperPathIsRenderedIntoEveryInstalledAsset() throws {
        let installer = Installer(catalog: catalog, helperPath: injectedHelperPath)

        for family in IntegrationFixtures.families {
            let preview = try makePreview(family, installer: installer)
            XCTAssertEqual(preview.helperPath, injectedHelperPath, "\(family): preview restates the supplied path")
            XCTAssertTrue(preview.conflicts.isEmpty, "\(family): \(preview.conflicts)")

            let receipt = try installer.apply(preview)
            XCTAssertFalse(receipt.entries.isEmpty, "\(family) declares no owned entry")
            for entry in receipt.entries {
                let text = try read(entry.path)
                XCTAssertTrue(
                    text.contains(injectedHelperPath),
                    "\(family): \(entry.path) does not name the injected helper"
                )
                XCTAssertFalse(
                    text.contains("{" + Template.helperPath + "}"),
                    "\(family): placeholder left in \(entry.path)"
                )
                XCTAssertFalse(
                    Template.containsPlaceholder(text),
                    "\(family): a template placeholder survived in \(entry.path)"
                )
                XCTAssertFalse(
                    text.contains(IntegrationPaths.helperPath),
                    "\(family): the documented constant leaked into \(entry.path) despite the injection"
                )
            }
        }
    }

    func testInjectedHelperPathFillsTheCodexBlockAndTheExtensionAssets() throws {
        let installer = Installer(catalog: catalog, helperPath: injectedHelperPath)

        let codex = try install("codex", installer: installer)
        let codexPath = try XCTUnwrap(codex.entries.first?.path)
        let codexText = try read(codexPath)
        XCTAssertEqual(codexPath, codexConfigURL.path)
        XCTAssertTrue(codexText.contains("awake-lite BEGIN"), "the owned codex block was appended")
        XCTAssertTrue(
            codexText.contains("command = \"\\\"" + injectedHelperPath + "\\\" --family codex"),
            "the codex handler quotes the injected helper"
        )
        for event in [
            "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop",
            "Interrupt", "SubagentStart", "SubagentStop"
        ] {
            XCTAssertTrue(
                codexText.contains("--event \(event)"),
                "missing rendered handler for \(event)"
            )
        }
        XCTAssertFalse(Template.containsPlaceholder(codexText), "codex block keeps no placeholder")

        for family in ["pi", "opencode"] {
            let receipt = try install(family, installer: installer)
            let path = try XCTUnwrap(receipt.entries.first?.path)
            let text = try read(path)
            XCTAssertTrue(text.contains(injectedHelperPath), "\(family): \(path) does not name the injected helper")
            XCTAssertFalse(
                Template.containsPlaceholder(text),
                "\(family): \(path) keeps a placeholder"
            )
            XCTAssertFalse(
                text.contains(IntegrationPaths.helperPath),
                "\(family): \(path) uses the documented constant instead of the injected path"
            )
        }
    }

    // MARK: - Default stays the documented constant

    func testDefaultInstallerStillRendersTheDocumentedConstant() throws {
        let installer = Installer(catalog: catalog)
        let preview = try makePreview("codex", installer: installer)
        XCTAssertEqual(preview.helperPath, IntegrationPaths.helperPath)
        XCTAssertEqual(preview.plan.helperPath, IntegrationPaths.helperPath)

        let receipt = try installer.apply(preview)
        let text = try read(try XCTUnwrap(receipt.entries.first?.path))
        XCTAssertTrue(text.contains(IntegrationPaths.helperPath))
        XCTAssertFalse(Template.containsPlaceholder(text))
    }

    // MARK: - Staleness

    func testPreviewWithAnotherHelperPathIsRefusedByApply() throws {
        let stale = try makePreview(
            "codex",
            installer: Installer(catalog: catalog, helperPath: injectedHelperPath)
        )
        let changed = Installer(catalog: catalog, helperPath: otherHelperPath)

        XCTAssertThrowsError(try changed.apply(stale)) { error in
            XCTAssertEqual(
                error as? InstallerError,
                .stalePreview("the helper path changed since the preview was produced")
            )
        }
        XCTAssertFalse(exists(codexConfigURL), "a refused apply writes nothing")
        XCTAssertFalse(exists(support.appendingPathComponent("receipts/codex.json")))

        // A preview built after the change carries the new path, a different
        // digest, and applies.
        let fresh = try makePreview("codex", installer: changed)
        XCTAssertEqual(fresh.helperPath, otherHelperPath)
        XCTAssertNotEqual(fresh.inputDigest, stale.inputDigest, "the helper path is part of the preview digest")

        let receipt = try changed.apply(fresh)
        let text = try read(try XCTUnwrap(receipt.entries.first?.path))
        XCTAssertTrue(text.contains(otherHelperPath))
        XCTAssertFalse(text.contains(injectedHelperPath))
    }

    func testPreviewMadeWithTheResolvedBundlePathApplies() throws {
        let bundle = sandbox.appendingPathComponent("RepoBuild/AwakeLite.app", isDirectory: true)
        let helper = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("AwakeLiteHelper", isDirectory: false)
        try IntegrationFixtures.write("#!/bin/sh\nexit 0\n", to: helper)

        let resolved = try HelperResolver.resolve(appBundle: bundle)
        XCTAssertEqual(resolved, helper.path)

        let installer = Installer(catalog: catalog, helperPath: resolved)
        let preview = try makePreview("pi", installer: installer)
        XCTAssertEqual(preview.helperPath, resolved)
        let receipt = try installer.apply(preview)
        let text = try read(try XCTUnwrap(receipt.entries.first?.path))
        XCTAssertTrue(text.contains(resolved))
        XCTAssertFalse(Template.containsPlaceholder(text))
    }

    // MARK: - Removal of a receipt written with the old constant

    func testRemovalOfEntryInstalledWithTheDocumentedConstantStillSucceeds() throws {
        let foreign = "[foreign]\nmodel = \"keep-me\"\n"
        try IntegrationFixtures.write(foreign, to: codexConfigURL)

        let old = Installer(catalog: catalog) // documented constant
        let codex = try install("codex", installer: old)
        let codexPath = try XCTUnwrap(codex.entries.first?.path)
        XCTAssertEqual(codexPath, codexConfigURL.path)
        XCTAssertTrue(try read(codexPath).contains(IntegrationPaths.helperPath))
        let opencode = try install("opencode", installer: old)
        let opencodePath = URL(fileURLWithPath: try XCTUnwrap(opencode.entries.first?.path))
        XCTAssertTrue(exists(opencodePath), "the install created its owned file")

        // Removal is receipt-driven: the caller's current helper path is not an
        // input, so an upgraded app still removes what the old build installed.
        let newer = Installer(catalog: catalog, helperPath: otherHelperPath)
        let codexReport = try newer.remove(family: "codex", appSupportRoot: support)
        XCTAssertFalse(codexReport.removedPaths.isEmpty)
        XCTAssertFalse(exists(support.appendingPathComponent("receipts/codex.json")))
        let remaining = try read(codexPath)
        XCTAssertTrue(remaining.contains("[foreign]"), "foreign tables survive removal")
        XCTAssertTrue(remaining.contains("keep-me"))
        XCTAssertFalse(remaining.contains("awake-lite"), "the owned block is gone")

        _ = try newer.remove(family: "opencode", appSupportRoot: support)
        XCTAssertFalse(exists(opencodePath), "the file the install created is removed")
        XCTAssertFalse(exists(support.appendingPathComponent("receipts/opencode.json")))
    }

    // MARK: - Resolver

    func testResolverReturnsTheHelperInsideTheBundle() throws {
        let bundle = sandbox.appendingPathComponent("NotApplications/AwakeLite.app", isDirectory: true)
        let helper = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("AwakeLiteHelper", isDirectory: false)
        try IntegrationFixtures.write("#!/bin/sh\nexit 0\n", to: helper)

        XCTAssertEqual(try HelperResolver.resolve(appBundle: bundle), helper.path)
    }

    func testResolverRefusesABundleWithoutTheHelper() throws {
        let bundle = sandbox.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let expected = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("AwakeLiteHelper", isDirectory: false)
            .path

        XCTAssertThrowsError(try HelperResolver.resolve(appBundle: bundle)) { error in
            XCTAssertEqual(error as? InstallerError, .helperUnavailable(path: expected))
        }
    }

    func testResolverRefusesADirectoryAtTheHelperPath() throws {
        let bundle = sandbox.appendingPathComponent("Wrong.app", isDirectory: true)
        let helperDirectory = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("AwakeLiteHelper", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try HelperResolver.resolve(appBundle: bundle)) { error in
            XCTAssertEqual(error as? InstallerError, .helperUnavailable(path: helperDirectory.path))
        }
    }

    func testMissingHelperRefusalStillAllowsRemoval() throws {
        // The app keeps the catalog usable when its bundle has no helper; this
        // pins the property removal relies on: `remove` needs no helper path.
        let installer = Installer(catalog: catalog, helperPath: injectedHelperPath)
        _ = try install("codex", installer: installer)

        let bundle = sandbox.appendingPathComponent("NoHelper.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertThrowsError(try HelperResolver.resolve(appBundle: bundle))

        let report = try installer.remove(family: "codex", appSupportRoot: support)
        XCTAssertFalse(report.removedPaths.isEmpty)
        XCTAssertFalse(exists(support.appendingPathComponent("receipts/codex.json")))
    }

    // MARK: - Helpers

    private var codexConfigURL: URL {
        home.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    private func discovery() -> ProductDiscovery {
        ProductDiscovery(homeRoot: home, applicationRoots: [applications])
    }

    private func makePreview(_ family: String, installer: Installer) throws -> InstallPreview {
        try installer.preview(
            family: family,
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
    }

    @discardableResult
    private func install(_ family: String, installer: Installer) throws -> InstallReceipt {
        let preview = try makePreview(family, installer: installer)
        XCTAssertTrue(preview.conflicts.isEmpty, "\(family): \(preview.conflicts)")
        return try installer.apply(preview)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
