import XCTest
@testable import AwakeLiteCore

/// Release-safe drift detection: an installed OMP extension bakes the helper
/// path at install time, so a moved app bundle must surface as a repair
/// instead of failing silently.
///
/// Every test runs against temporary home and support roots; no real install
/// state is read or written and nothing is applied except into the sandbox.
final class InstallDriftTests: XCTestCase {
    private var sandbox: URL!
    private var home: URL!
    private var support: URL!
    private var catalog: Catalog!

    private let currentHelper =
        "/opt/awake-lite-fixture/AwakeLite.app/Contents/MacOS/AwakeLiteHelper"
    private let movedHelper =
        "/Applications/AwakeLite.app/Contents/MacOS/AwakeLiteHelper"

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try IntegrationFixtures.makeSandbox()
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        support = sandbox.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        catalog = try IntegrationFixtures.shippedCatalog()
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        home = nil
        support = nil
        catalog = nil
        try super.tearDownWithError()
    }

    func testInstalledPackageWithTheCurrentHelperIsCurrent() throws {
        let installer = Installer(catalog: catalog, helperPath: currentHelper)
        try install(family: "omp", installer: installer)

        let input = try driftInput(
            family: "omp",
            installer: installer,
            helperPath: currentHelper
        )

        XCTAssertEqual(
            InstallDrift.evaluate(input),
            .current,
            "a fresh preview renders the next generation; drift must compare at the receipt's generation"
        )
    }

    func testMovedBundleNeedsAnUpdate() throws {
        let original = Installer(catalog: catalog, helperPath: currentHelper)
        try install(family: "omp", installer: original)

        let moved = Installer(catalog: catalog, helperPath: movedHelper)
        let input = try driftInput(
            family: "omp",
            installer: moved,
            helperPath: movedHelper
        )

        XCTAssertEqual(InstallDrift.evaluate(input), .needsUpdate)
        let installedPath = try installedCopyPath(family: "omp")
        let installedText = try String(contentsOfFile: installedPath, encoding: .utf8)
        XCTAssertTrue(installedText.contains(currentHelper))
        XCTAssertFalse(installedText.contains(movedHelper))
    }

    func testMissingHelperStalePreviewAndUserEditAreBlocked() throws {
        let installer = Installer(catalog: catalog, helperPath: currentHelper)
        try install(family: "omp", installer: installer)
        let beforeEdit = try makePreview(family: "omp", installer: installer)
        XCTAssertTrue(beforeEdit.conflicts.isEmpty)
        XCTAssertFalse(beforeEdit.entries.contains { $0.action == .conflict })

        // A bundle that cannot name its helper cannot be compared.
        var missingHelper = try driftInput(
            family: "omp",
            installer: installer,
            helperPath: currentHelper
        )
        missingHelper.helperPath = nil
        guard case .blocked = InstallDrift.evaluate(missingHelper) else {
            return XCTFail("a missing helper must be surfaced, not hidden")
        }

        // A preview built for another path describes different bytes.
        var stale = try driftInput(
            family: "omp",
            installer: installer,
            helperPath: currentHelper
        )
        stale.helperPath = movedHelper
        guard case .blocked = InstallDrift.evaluate(stale) else {
            return XCTFail("a stale preview must be refused")
        }

        // A user-edited owned file is a conflict, not an automatic repair.
        let installedPath = try installedCopyPath(family: "omp")
        try IntegrationFixtures.write("// edited by hand\n", to: URL(fileURLWithPath: installedPath))
        let conflicted = try driftInput(
            family: "omp",
            installer: installer,
            helperPath: currentHelper
        )
        XCTAssertTrue(conflicted.preview.entries.contains { $0.action == .conflict })
        guard case .blocked = InstallDrift.evaluate(conflicted) else {
            return XCTFail("a user-edited file must be blocked, not overwritten")
        }
    }

    func testNoReceiptIsNotDrift() throws {
        let installer = Installer(catalog: catalog, helperPath: currentHelper)
        let input = try driftInput(
            family: "omp",
            installer: installer,
            helperPath: currentHelper
        )

        XCTAssertNil(try InstallerStorage(root: support).loadReceipt(family: "omp"))
        XCTAssertEqual(InstallDrift.evaluate(input), .notInstalled)
    }

    // MARK: - Helpers

    /// Mirrors the store: preview with the current helper, then render the
    /// app-owned copy at the receipt's generation for comparison.
    private func driftInput(
        family: String,
        installer: Installer,
        helperPath: String?
    ) throws -> InstallDriftInput {
        let preview = try makePreview(family: family, installer: installer)
        let receipt = try InstallerStorage(root: support).loadReceipt(family: family)
        var comparison: (installed: Data?, expected: Data?)?
        if let receipt, let generation = preview.previousGeneration,
           let copy = copyEntry(in: preview) {
            let planner = InstallPlanner(
                manifest: try catalog.manifest(for: family),
                receipt: receipt,
                helperPath: helperPath ?? installer.helperPath
            )
            let expected = try planner.renderedCopyAsset(
                assetID: copy.assetID,
                marker: copy.marker,
                target: copy.entry.target,
                generation: generation
            )
            let installed = try ConfigEditor.readIfPresent(
                URL(fileURLWithPath: copy.path, isDirectory: false)
            )
            comparison = (installed: installed, expected: expected)
        }
        return InstallDriftInput(
            hasReceipt: receipt != nil,
            helperPath: helperPath,
            preview: preview,
            copy: comparison
        )
    }

    private func copyEntry(in preview: InstallPreview) -> PlannedEntry? {
        preview.plan.steps.flatMap(\.entries).first { planned in
            switch planned.entry.kind {
            case .pluginFile, .extensionFile, .commandWrapper:
                return true
            case .hookConfig:
                return false
            }
        }
    }

    private func makePreview(family: String, installer: Installer) throws -> InstallPreview {
        try installer.preview(
            family: family,
            configRoot: home,
            appSupportRoot: support,
            discovery: ProductDiscovery(homeRoot: home)
        )
    }

    @discardableResult
    private func install(family: String, installer: Installer) throws -> InstallReceipt {
        let preview = try makePreview(family: family, installer: installer)
        XCTAssertTrue(preview.conflicts.isEmpty, "\(family): \(preview.conflicts)")
        return try installer.apply(preview)
    }

    private func installedCopyPath(family: String) throws -> String {
        let receipt = try XCTUnwrap(InstallerStorage(root: support).loadReceipt(family: family))
        return try XCTUnwrap(receipt.entries.first { entry in
            switch entry.kind {
            case .pluginFile, .extensionFile, .commandWrapper: return true
            case .hookConfig: return false
            }
        }).path
    }
}
