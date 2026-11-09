import Darwin
import Foundation

// MARK: - Owner identity

/// Result of probing one process for owner identity.
///
/// `measured == false` means libproc could not describe the process, so the
/// documented fallback identity was used instead (see
/// `OwnerIdentityProbe.identity(pid:)`).
struct OwnerProbe: Equatable {
    var identity: OwnerIdentity
    var measured: Bool
}

/// Derives the stable identity of the *observed agent instance*, not of the
/// short-lived hook helper.
///
/// A hook `command` is a shell command, so the helper's immediate parent is
/// often a throwaway `sh` that exists for that one emission. Naming that shell
/// as the owner would give every emission of one agent session a different
/// owner, and the model rejects a terminal transition from a different owner,
/// so the work could never close. The probe therefore starts at `getppid()`,
/// walks up the ancestry with `proc_pidinfo(PROC_PIDTBSDINFO)` (`pbi_ppid`) for
/// at most `maxAncestorHops` hops, and skips ancestors whose `pbi_comm` or
/// `pbi_name` is a documented transient wrapper (`transientWrappers`). The owner
/// is the first non-transient ancestor at or above the immediate parent, and
/// its `(pid, start time, uid, OS boot token)` tuple is also the source of the
/// canonical `instance` string.
///
/// The walk stops at PID 1, at a cycle, at an ancestor libproc cannot describe,
/// or after the hop bound. If it never finds a non-transient ancestor it keeps
/// the immediate parent, which is the conservative choice: a wrapper chain that
/// ends at launchd still names the actual caller rather than a guess.
///
/// Documented limitations:
///
/// - An unknown wrapper executable between the helper and the agent still
///   changes the owner. The failure direction is conservative: the model rejects
///   the terminal transition and holds the assertion rather than claiming idle.
/// - A process that exits and whose PID is reused can only be told apart by the
///   start time.
/// - If the process cannot be inspected at all, the fallback below is used and
///   the limitation is explicit rather than hidden.
enum OwnerIdentityProbe {
    /// Process names of documented transparent wrappers between the helper and
    /// the harness that owns it.
    ///
    /// Kept in one place so a new wrapper is one edit, not a hidden rule. Only
    /// names that actually stand in front of a hook command are listed; an
    /// arbitrary unknown program is not skipped.
    static let transientWrappers: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish",
        "env", "sudo", "script", "xargs", "timeout", "nohup", "launchctl"
    ]

    /// Ancestry limit. Real hook wrappers are two or three processes deep; the
    /// bound turns a pathological chain into the documented fallback instead of
    /// unbounded work.
    static let maxAncestorHops = 64

    /// Token for the current OS boot, from `sysctl kern.boottime`.
    ///
    /// Two processes with the same PID and start time on different boots are
    /// different owners; the model also retires owners from foreign boots. A
    /// boot time that cannot be read (unreachable in practice for a user
    /// process) yields `b0-0`, which is deliberately one shared token rather
    /// than a guess.
    static func bootToken() -> String {
        guard let boot = bootTime() else { return "b0-0" }
        return "b\(boot.sec)-\(boot.usec)"
    }

    /// Identity of the agent process that owns `pid`: `pid` itself when it is
    /// not a transient wrapper, otherwise the first non-transient ancestor.
    ///
    /// When libproc cannot describe `pid`, the documented fallback is a
    /// deliberately *unjoinable* identity: `startTimeMicros` stays 0, the
    /// instance is prefixed `x-` and carries a per-call nonce, and `measured` is
    /// false. Unmeasured emissions therefore never merge into one owner and can
    /// never close another process's work; the cost is that work started by such
    /// an emission cannot be closed by later events either. That is the
    /// conservative direction: it can hold sleep, never claim completion.
    static func measure(pid: Int32) -> OwnerProbe {
        let boot = bootToken()
        guard pid > 1, let immediate = describe(pid) else {
            return OwnerProbe(identity: fallback(pid: pid, boot: boot), measured: false)
        }
        return OwnerProbe(identity: identity(of: ownerProcess(startingAt: immediate), boot: boot), measured: true)
    }

    /// Identity only; callers that must know whether it was measured use
    /// `measure(pid:)`.
    static func identity(pid: Int32) -> OwnerIdentity {
        measure(pid: pid).identity
    }

    /// Identity of the agent ancestor of the process that spawned the helper.
    ///
    /// `getppid() <= 1` means the parent already exited and the process was
    /// re-parented to launchd; launchd is not the observed agent, so that case
    /// takes the fallback instead of naming PID 1 as the owner.
    static func parentIdentity() -> OwnerIdentity {
        identity(pid: getppid())
    }

    /// Identity of an owner the caller measured itself.
    ///
    /// A detached hook helper can outlive, or be re-parented before it probes,
    /// the process that owns the work: the ancestry walk would then name
    /// launchd, a throwaway wrapper, or a later unrelated process, and the
    /// model would reject the terminal transition. The Pi and OMP assets
    /// therefore mint one token per harness process at module load and pass it,
    /// with the process's own PID, on every emission.
    ///
    /// The helper supplies everything it can see: its own boot token and uid.
    /// It cannot measure the owner's start time, so `startTimeMicros` is 0 for
    /// a supplied identity. Owner equality is the whole tuple
    /// `(bootID, uid, pid, instance)`, and the instance is caller-owned text, so
    /// the zero start time is part of the contract rather than a failed
    /// measurement. Stage 5 owner liveness must treat such an owner
    /// conservatively: it cannot separate a live supplied owner from a reused
    /// PID by start time, and must not release that owner's work on that basis.
    static func supplied(instance: String, pid: Int32) -> OwnerIdentity {
        OwnerIdentity(
            bootID: bootToken(),
            pid: pid,
            startTimeMicros: 0,
            uid: geteuid(),
            instance: instance
        )
    }

    // MARK: - Ancestry walk

    /// The owner process for one chain start: `immediate` unless it is a
    /// transient wrapper, in which case the first non-transient ancestor.
    private static func ownerProcess(startingAt immediate: ProcessDescription) -> ProcessDescription {
        guard isTransient(immediate) else { return immediate }

        var visited: Set<Int32> = [immediate.pid]
        var candidate = immediate
        var hops = 0
        while hops < maxAncestorHops {
            let parentPID = candidate.ppid
            guard parentPID > 1, !visited.contains(parentPID),
                  let parent = describe(parentPID)
            else { return immediate }
            visited.insert(parentPID)
            hops += 1
            if !isTransient(parent) { return parent }
            candidate = parent
        }
        return immediate
    }

    /// True when either recorded process name is one of the documented
    /// wrappers. Names are compared as a lowercased last path component with a
    /// leading login-shell hyphen removed.
    private static func isTransient(_ process: ProcessDescription) -> Bool {
        for name in [process.comm, process.name] where !name.isEmpty {
            let base = name.split(separator: "/").last.map(String.init) ?? name
            let trimmed = base.hasPrefix("-") ? String(base.dropFirst()) : base
            if transientWrappers.contains(trimmed.lowercased()) { return true }
        }
        return false
    }

    private static func identity(of process: ProcessDescription, boot: String) -> OwnerIdentity {
        let startMicros = process.startTimeSec * 1_000_000 + UInt64(process.startTimeUsec)
        let instance = "p\(process.pid)-u\(process.uid)-t\(startMicros)-\(boot)"
        return OwnerIdentity(
            bootID: boot,
            pid: process.pid,
            startTimeMicros: startMicros,
            uid: process.uid,
            instance: instance
        )
    }

    // MARK: - Fallback

    /// Unjoinable identity used when the parent cannot be described.
    private static func fallback(pid: Int32, boot: String) -> OwnerIdentity {
        let uid = geteuid()
        let nonce = String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
        return OwnerIdentity(
            bootID: boot,
            pid: pid,
            startTimeMicros: 0,
            uid: uid,
            instance: "x-p\(pid)-u\(uid)-n\(nonce)"
        )
    }

    // MARK: - libproc and sysctl

    private struct ProcessDescription {
        var pid: Int32
        var ppid: Int32
        var uid: UInt32
        var startTimeSec: UInt64
        var startTimeUsec: UInt64
        var comm: String
        var name: String
    }

    private static func describe(_ pid: Int32) -> ProcessDescription? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size, info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else {
            return nil
        }
        return ProcessDescription(
            pid: pid,
            ppid: Int32(info.pbi_ppid),
            uid: info.pbi_uid,
            startTimeSec: info.pbi_start_tvsec,
            startTimeUsec: info.pbi_start_tvusec,
            comm: text(info.pbi_comm),
            name: text(info.pbi_name)
        )
    }

    /// Decodes one fixed-size C name buffer.
    private static func text<T>(_ buffer: T) -> String {
        withUnsafePointer(to: buffer) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }

    private static func bootTime() -> (sec: Int64, usec: Int32)? {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else {
            return nil
        }
        return (Int64(value.tv_sec), Int32(value.tv_usec))
    }
}

// MARK: - Owner liveness

/// Decides whether a recorded owner process provably no longer exists.
///
/// This is the only path that retires work without a lifecycle event, so every
/// rule is deliberately conservative: a wrong "dead" would claim idle while the
/// harness is still working and release the sleep assertion, so anything the
/// probe cannot prove keeps the work. The direction of every uncertainty is
/// therefore "not dead".
///
/// Production (`system()`) rules, in order:
///
/// 1. A boot token that differs from the current boot is dead: the recorded
///    process cannot exist on this boot.
/// 2. `pid <= 1` is dead: no harness and no process this app may own.
/// 3. `kill(pid, 0)` returning `-1` with `ESRCH` is dead. Any other failure,
///    including `EPERM`, and any result the OS does not make determinate, is
///    not dead.
/// 4. A measured owner (`startTimeMicros > 0`) is dead only when a fresh
///    `OwnerIdentityProbe.measure(pid:)` is measured and disagrees on pid,
///    uid, start time, or boot token; an unmeasurable process is not dead.
/// 5. A supplied owner (`startTimeMicros == 0`, the OMP extension contract) is
///    dead only when the pid is provably absent. A live pid cannot be
///    distinguished from a reused PID, so it is never treated as dead.
///
/// `instance` is caller-owned text and is never compared here.
struct OwnerLiveness {
    /// Three-state answer to "does this pid exist". `unknown` is not dead.
    enum Presence {
        case alive
        case absent
        case unknown
    }

    var isDead: (OwnerIdentity) -> Bool

    /// Production implementation: current boot token, `kill`, and libproc.
    static func system() -> OwnerLiveness {
        OwnerLiveness { owner in
            evaluate(
                owner: owner,
                bootToken: OwnerIdentityProbe.bootToken(),
                presence: presence(pid: owner.pid),
                measure: { OwnerIdentityProbe.measure(pid: $0) }
            )
        }
    }

    /// The documented rules without process access, so XCTest can prove the
    /// measured-owner comparison and the unknown-presence rule without forcing
    /// a real PID reuse.
    static func evaluate(
        owner: OwnerIdentity,
        bootToken: String,
        presence: Presence,
        measure: (Int32) -> OwnerProbe
    ) -> Bool {
        guard owner.bootID == bootToken else { return true }
        guard owner.pid > 1 else { return true }

        switch presence {
        case .absent:
            return true
        case .unknown:
            return false
        case .alive:
            break
        }

        // A supplied owner carries no start time by contract; presence is all
        // the evidence there is, and a live pid is never enough to release it.
        guard owner.startTimeMicros > 0 else { return false }

        let probe = measure(owner.pid)
        guard probe.measured else { return false }
        let measured = probe.identity
        return measured.pid != owner.pid
            || measured.uid != owner.uid
            || measured.startTimeMicros != owner.startTimeMicros
            || measured.bootID != owner.bootID
    }

    /// Maps `kill(pid, 0)` onto the three states. Only `ESRCH` proves absence;
    /// `EPERM` proves the process exists but not that it is the recorded one,
    /// so both that and any unexpected error stay indeterminate.
    private static func presence(pid: Int32) -> Presence {
        if kill(pid, 0) == 0 { return .alive }
        return errno == ESRCH ? .absent : .unknown
    }
}
