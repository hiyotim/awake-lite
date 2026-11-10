import Foundation

/// Whether an installed package matches the bytes this bundle would write.
///
/// A receipt records the hash of what an install wrote. Those bytes contain the
/// absolute helper path and the activation generation, so a moved app bundle
/// leaves an installed hook that can never run: spawning the helper fails and
/// the extension ignores exit codes. This comparison is read-only and decides
/// only whether the user should be offered a repair; it never writes. The
/// existing preview/apply path performs the repair with a new generation.
enum PackageDrift: Equatable {
    /// No receipt: a first install, not drift.
    case notInstalled
    /// The installed owned file already holds the bytes this bundle writes.
    case current
    /// A receipt exists and the installed file differs: a moved bundle, an
    /// updated bundled asset, or a deleted owned file.
    case needsUpdate
    /// The comparison cannot run or must not be repaired automatically
    /// (missing helper, stale preview, or a user-edited owned file).
    case blocked(String)
}

/// Inputs for one installed package's drift decision.
struct InstallDriftInput {
    var hasReceipt: Bool
    /// The helper path resolved from the running bundle, or `nil` when the
    /// bundle cannot name one.
    var helperPath: String?
    /// A preview built with that same helper path. Used for its conflicts and
    /// to prove the compared bytes belong to this helper.
    var preview: InstallPreview
    /// The one wholly app-owned file this package installs: its current bytes
    /// (nil when missing) and the bytes this bundle would write at the
    /// receipt's generation. `nil` when the package installs no comparable
    /// file.
    var copy: (installed: Data?, expected: Data?)?
}

/// Pure drift rule, separated from `Bundle.main` and the file system.
///
/// The preview's entry action alone cannot answer this: every preview renders
/// at the next activation generation, so an installed file always differs from
/// a fresh render. `copy.expected` is rendered at the *receipt's* generation,
/// so equality means the helper path and asset text still match; only a
/// genuine move or asset change differs.
enum InstallDrift {
    static func evaluate(_ input: InstallDriftInput) -> PackageDrift {
        guard input.hasReceipt else { return .notInstalled }
        guard let helperPath = input.helperPath else {
            return .blocked("путь помощника AwakeLite не определён")
        }
        guard input.preview.helperPath == helperPath else {
            return .blocked("предпросмотр построен для другого помощника")
        }
        if let conflict = input.preview.conflicts.first {
            return .blocked(conflict)
        }
        if input.preview.entries.contains(where: { $0.action == .conflict }) {
            return .blocked("установленная запись изменена вручную и не принадлежит поддержке")
        }
        guard let copy = input.copy else { return .current }
        return copy.installed == copy.expected ? .current : .needsUpdate
    }
}
