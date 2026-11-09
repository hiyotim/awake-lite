import Darwin
import XCTest
@testable import AwakeLiteCore

final class LocalEventStoreTests: XCTestCase {
    private var root: URL!
    private var store: LocalEventStore!

    private let family = "codex"
    private let instance = "cli"
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwakeLiteCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        store = LocalEventStore(root: root)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        store = nil
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Reconcile

    func testReconcileAppliesEventsPersistsCheckpointAndEmptiesInbox() throws {
        try store.enqueue(event("e1", work: "one", at: epoch))
        try store.enqueue(event("e2", work: "two", at: epoch.addingTimeInterval(1)))

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.applied, 2)
        XCTAssertEqual(report.processedFiles, 2)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(report.rejectedFiles, 0)
        XCTAssertFalse(report.overflowed)
        XCTAssertEqual(try inboxNames(), [])
        XCTAssertEqual(model.works.count, 2)
        XCTAssertEqual(model.decision.state, .working)

        let reloaded = try store.loadModel()
        XCTAssertEqual(reloaded.works.count, 2)
        XCTAssertEqual(reloaded.decision.state, .working)
    }

    func testRecoveryAfterCheckpointButBeforeDeletionReplaysAsDuplicates() throws {
        for index in 0..<3 {
            try store.enqueue(event("c\(index)", work: "work-\(index)", at: epoch.addingTimeInterval(Double(index))))
        }

        var model = activatedModel()
        let first = try store.reconcile(&model, deletingProcessed: false)
        XCTAssertEqual(first.applied, 3)
        XCTAssertEqual(try inboxNames().count, 3)

        var reloaded = try store.loadModel()
        XCTAssertEqual(reloaded.works.count, 3)

        let second = try store.reconcile(&reloaded)
        XCTAssertEqual(second.applied, 0)
        XCTAssertEqual(second.duplicates, 3)
        XCTAssertEqual(second.rejectedFiles, 0)
        XCTAssertEqual(second.processedFiles, 3)
        XCTAssertEqual(reloaded.decision.state, model.decision.state)
        XCTAssertEqual(reloaded.decision.holdAssertion, model.decision.holdAssertion)
        XCTAssertEqual(try inboxNames(), [])
    }

    func testConcurrentWritersLoseNoEvents() throws {
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<40 {
                let event = self.event(
                    "w\(worker)-\(index)",
                    work: "work-\(worker)-\(index)",
                    at: self.epoch.addingTimeInterval(Double(worker * 40 + index))
                )
                do {
                    try self.store.enqueue(event)
                } catch {
                    failures.append("\(error)")
                }
            }
        }

        XCTAssertTrue(failures.values.isEmpty, "enqueue failures: \(failures.values)")
        XCTAssertEqual(try inboxNames().count, 320)

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.applied, 320)
        XCTAssertEqual(report.processedFiles, 320)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(report.rejectedFiles, 0)
        XCTAssertEqual(model.works.count, 320)
        XCTAssertEqual(try inboxNames(), [])
    }

    func testInboxOverflowRecordsGapAndPreventsIdle() throws {
        var limits = LocalEventStore.Limits()
        limits.maxInboxFiles = 4
        let limited = LocalEventStore(root: root, limits: limits)
        try limited.prepare()

        // Written directly: `enqueue` refuses past the bound, and reconcile
        // must still notice a queue that an older or non-cooperating producer
        // left above it.
        for index in 0..<8 {
            let instanceName = index.isMultiple(of: 2) ? instance : "other"
            let event = event(
                "o\(index)",
                work: "work-\(index)",
                instanceName: instanceName,
                at: epoch.addingTimeInterval(Double(index))
            )
            let name = EventFileName.make(event: event, at: event.timestamp)
            let data = try JSONEncoder().encode(event)
            try data.write(to: limited.inbox.appendingPathComponent(name))
        }

        var model = activatedModel()
        let report = try limited.reconcile(&model)

        XCTAssertTrue(report.overflowed)
        XCTAssertEqual(report.applied, 8)
        let overflowGaps = model.gaps.values.filter { $0.reasons.contains(.storageOverflow) }
        XCTAssertEqual(overflowGaps.count, 2)
        XCTAssertNotEqual(model.decision.state, .idle)
    }

    func testEnqueueRefusesAtTheInboxBoundBeforeCreatingAnything() throws {
        var limits = LocalEventStore.Limits()
        limits.maxInboxFiles = 3
        let limited = LocalEventStore(root: root, limits: limits)

        for index in 0..<3 {
            try limited.enqueue(
                event("cap-\(index)", work: "work-\(index)", at: epoch.addingTimeInterval(Double(index)))
            )
        }
        XCTAssertEqual(try inboxNames().filter { $0.hasSuffix(".event") }.count, 3)

        XCTAssertThrowsError(
            try limited.enqueue(
                event("cap-3", work: "work-3", at: epoch.addingTimeInterval(3)))
        ) { error in
            XCTAssertEqual(error as? StoreError, .inboxFull)
        }

        let names = try inboxNames()
        XCTAssertEqual(names.filter { $0.hasSuffix(".event") }.count, 3)
        XCTAssertFalse(names.contains { $0.contains(".tmp") }, "the refused write leaves no temporary file: \(names)")
        XCTAssertFalse(names.contains { $0.contains("cap-3") })
    }

    func testInboxAtTheBoundRecordsOverflowGapAndPreventsIdle() throws {
        var limits = LocalEventStore.Limits()
        limits.maxInboxFiles = 3
        let limited = LocalEventStore(root: root, limits: limits)

        for index in 0..<3 {
            try limited.enqueue(
                event("full-\(index)", work: "work-\(index)", at: epoch.addingTimeInterval(Double(index)))
            )
        }

        // No active generation: the events are inert and leave no
        // `eventRejected` gap, so the full queue is the only reason the pass
        // cannot claim idle.
        var model = ActivityModel()
        let report = try limited.reconcile(&model)

        XCTAssertTrue(report.overflowed)
        XCTAssertEqual(report.applied, 0)
        XCTAssertEqual(report.ignored["inactiveSource"], 3)
        XCTAssertEqual(report.processedFiles, 3)
        let overflowGaps = model.gaps.values.filter { $0.reasons.contains(.storageOverflow) }
        XCTAssertEqual(overflowGaps.count, 1)
        XCTAssertEqual(overflowGaps.first?.family, family)
        XCTAssertEqual(overflowGaps.first?.instance, instance)
        XCTAssertEqual(model.decision.state, .unknown)
        XCTAssertFalse(model.decision.holdAssertion)
        XCTAssertEqual(try inboxNames(), [], "the pass drains the files as usual")
    }

    // MARK: - Rejection

    func testMalformedEventIsRejectedWithGap() throws {
        try store.prepare()
        let name = EventFileName.make(event: event("bad", work: "w"), at: epoch)
        try Data("{not json".utf8).write(to: store.inbox.appendingPathComponent(name))

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.rejectedFiles, 1)
        XCTAssertEqual(report.applied, 0)
        XCTAssertEqual(try inboxNames(), [])
        XCTAssertEqual(try rejectedNames(), [name])
        XCTAssertTrue(model.gaps.contains { $0.key.family == family && $0.value.reasons.contains(.eventRejected) })
        XCTAssertEqual(model.decision.state, .unknown)
    }

    func testOversizeEventIsRejectedWithGap() throws {
        var limits = LocalEventStore.Limits()
        limits.maxEventBytes = 64
        let limited = LocalEventStore(root: root, limits: limits)
        try limited.prepare()

        let name = EventFileName.make(event: event("big", work: "w"), at: epoch)
        try Data(repeating: 0x20, count: 256).write(to: limited.inbox.appendingPathComponent(name))

        var model = activatedModel()
        let report = try limited.reconcile(&model)

        XCTAssertEqual(report.rejectedFiles, 1)
        XCTAssertEqual(report.applied, 0)
        XCTAssertEqual(report.processedFiles, 0)
        XCTAssertEqual(try inboxNames(), [])
        XCTAssertEqual(try rejectedNames(), [name])
        XCTAssertTrue(model.gaps.contains { $0.value.reasons.contains(.eventRejected) })
    }

    func testRejectedDirectoryStaysBounded() throws {
        var limits = LocalEventStore.Limits()
        limits.maxRejectedFiles = 2
        let limited = LocalEventStore(root: root, limits: limits)
        try limited.prepare()

        for index in 0..<4 {
            let name = EventFileName.make(event: event("r\(index)", work: "w"), at: epoch.addingTimeInterval(Double(index)))
            try Data("{broken".utf8).write(to: limited.inbox.appendingPathComponent(name))
        }

        var model = activatedModel()
        _ = try limited.reconcile(&model)

        XCTAssertEqual(try rejectedNames().count, 2)
    }

    func testUnparseableFileNameIsRejectedWithEmptyScopeGap() throws {
        try store.prepare()
        let name = "not-an-event-name.event"
        try Data("{not json".utf8).write(to: store.inbox.appendingPathComponent(name))

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.rejectedFiles, 1)
        XCTAssertEqual(report.processedFiles, 0)
        XCTAssertEqual(try inboxNames(), [])
        XCTAssertEqual(try rejectedNames(), [name])

        let gap = model.gaps[GapKey(family: "", instance: "", session: nil)]
        XCTAssertEqual(gap?.reasons, [.eventRejected])
        XCTAssertEqual(model.decision.state, .unknown)
    }

    func testFilenameContentScopeMismatchIsRejected() throws {
        try store.prepare()
        let payload = event("mismatch", work: "w", source: "cursor")
        let name = fileName(family: family, id: "mismatch")
        try JSONEncoder().encode(payload).write(to: store.inbox.appendingPathComponent(name))

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.applied, 0)
        XCTAssertEqual(report.rejectedFiles, 1)
        XCTAssertEqual(try inboxNames(), [])
        XCTAssertEqual(try rejectedNames(), [name])
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(
            model.gaps[GapKey(family: family, instance: instance, session: nil)]?.reasons,
            [.eventRejected]
        )
        XCTAssertEqual(model.decision.state, .unknown)
    }

    func testUnknownWorkEventRecordsGap() throws {
        try store.enqueue(event("ghost", work: "never-started", transition: .completed))

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.applied, 0)
        XCTAssertEqual(report.ignored["unknownWork"], 1)
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(
            model.gaps[GapKey(family: family, instance: instance, session: "s1")]?.reasons,
            [.eventRejected]
        )
        XCTAssertEqual(model.decision.state, .unknown)
        XCTAssertEqual(try inboxNames(), [])
    }

    /// Rejections are recorded and the evidence is kept until the checkpoint
    /// that contains the gap is durable.
    func testRejectedFileIsKeptWhenCheckpointSaveFails() throws {
        try store.prepare()
        try FileManager.default.createDirectory(at: store.checkpoint, withIntermediateDirectories: true)

        let name = EventFileName.make(event: event("broken", work: "w"), at: epoch)
        try Data("{not json".utf8).write(to: store.inbox.appendingPathComponent(name))

        var model = activatedModel()
        XCTAssertThrowsError(try store.reconcile(&model))
        XCTAssertEqual(try inboxNames(), [name], "inbox files must survive a failed save")
        XCTAssertEqual(try rejectedNames(), [])

        try FileManager.default.removeItem(at: store.checkpoint)

        let report = try store.reconcile(&model)
        XCTAssertEqual(report.rejectedFiles, 1)
        XCTAssertEqual(report.processedFiles, 0)
        XCTAssertEqual(try inboxNames(), [])
        XCTAssertEqual(try rejectedNames(), [name])
        XCTAssertTrue(model.gaps.values.contains { $0.reasons.contains(.eventRejected) })
        XCTAssertFalse(try store.loadModel().gaps.isEmpty)
    }

    /// A processed file is also kept until the checkpoint that records it is
    /// durable, so the event is not lost when the save fails.
    func testProcessedFileIsKeptWhenCheckpointSaveFails() throws {
        try store.enqueue(event("kept", work: "w", at: epoch))
        try store.prepare()
        try FileManager.default.createDirectory(at: store.checkpoint, withIntermediateDirectories: true)

        var model = activatedModel()
        XCTAssertThrowsError(try store.reconcile(&model))
        XCTAssertEqual(try inboxNames().count, 1, "a processed file must survive a failed save")
        XCTAssertEqual(try rejectedNames(), [])

        try FileManager.default.removeItem(at: store.checkpoint)

        var retried = activatedModel()
        let report = try store.reconcile(&retried)
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(try inboxNames(), [])
        XCTAssertEqual(try store.loadModel().works.count, 1)
    }

    /// A well-formed event above the size bound is rejected, not applied.
    func testValidButOversizeEventIsRejected() throws {
        var limits = LocalEventStore.Limits()
        limits.maxEventBytes = 128
        let limited = LocalEventStore(root: root, limits: limits)
        try limited.prepare()

        let sample = event("fat", work: "w", at: epoch)
        var data = try JSONEncoder().encode(sample)
        data.append(Data(repeating: 0x20, count: 512))
        XCTAssertGreaterThan(data.count, limits.maxEventBytes)

        let name = EventFileName.make(event: sample, at: epoch)
        try data.write(to: limited.inbox.appendingPathComponent(name))

        var model = activatedModel()
        let report = try limited.reconcile(&model)

        XCTAssertEqual(report.rejectedFiles, 1)
        XCTAssertEqual(report.applied, 0)
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(try rejectedNames(), [name])
        XCTAssertEqual(
            model.gaps[GapKey(family: family, instance: instance, session: nil)]?.reasons,
            [.eventRejected]
        )
    }

    /// A stamp far in the future is rejected instead of trusted, and it does
    /// not disturb events that follow normal time.
    func testFutureDatedEventIsRejected() throws {
        try store.enqueue(event("future", work: "ahead", at: Date().addingTimeInterval(7200)))

        var model = activatedModel()
        let rejected = try store.reconcile(&model)
        XCTAssertEqual(rejected.rejectedFiles, 1)
        XCTAssertEqual(rejected.applied, 0)
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(try rejectedNames().count, 1)
        XCTAssertEqual(
            model.gaps[GapKey(family: family, instance: instance, session: "s1")]?.reasons,
            [.eventRejected]
        )
        XCTAssertEqual(model.decision.state, .unknown)

        try store.enqueue(event("normal", work: "behind", at: Date().addingTimeInterval(-1)))
        let applied = try store.reconcile(&model)
        XCTAssertEqual(applied.applied, 1)
        XCTAssertEqual(model.works.count, 1)
        XCTAssertEqual(model.decision.state, .working)
    }

    /// A liveness beat for work this model never saw must not pin the
    /// aggregate to unknown.
    func testUnknownWorkHeartbeatDoesNotLeaveGap() throws {
        try store.enqueue(event("beat", work: "ghost", transition: .heartbeat))

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.ignored["unknownWork"], 1)
        XCTAssertEqual(report.applied, 0)
        XCTAssertTrue(model.gaps.isEmpty)
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertEqual(try inboxNames(), [], "the event itself was understood and consumed")
    }

    /// The gap is dated from the inbox file, not from the reconciling clock.
    func testRejectionGapUsesInboxFileTime() throws {
        try store.prepare()
        let name = EventFileName.make(event: event("timed", work: "w"), at: epoch)
        let file = store.inbox.appendingPathComponent(name)
        try Data("{not json".utf8).write(to: file)
        let created = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date
        )

        var model = activatedModel()
        _ = try store.reconcile(&model)

        let gap = try XCTUnwrap(model.gaps[GapKey(family: family, instance: instance, session: nil)])
        XCTAssertEqual(gap.detectedAt, created)
    }

    func testRejectedDirectoryCollisionKeepsBothFiles() throws {
        try store.prepare()
        let name = EventFileName.make(event: event("collide", work: "w"), at: epoch)
        let retained = store.rejected.appendingPathComponent(name)
        try Data("retained".utf8).write(to: retained)
        try Data("{not json".utf8).write(to: store.inbox.appendingPathComponent(name))

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.rejectedFiles, 1)
        XCTAssertEqual(try rejectedNames().count, 2)
        XCTAssertTrue(try rejectedNames().contains(name))
        XCTAssertEqual(try Data(contentsOf: retained), Data("retained".utf8))
        XCTAssertEqual(try inboxNames(), [])
    }

    /// A file that cannot be deleted is counted, and the pass continues.
    func testDeleteFailureIsReportedAndPassContinues() throws {
        try store.enqueue(event("sticky", work: "one", at: epoch))
        try store.enqueue(event("plain", work: "two", at: epoch.addingTimeInterval(1)))

        let stickyName = try XCTUnwrap(try inboxNames().first { $0.contains("sticky") })
        let sticky = store.inbox.appendingPathComponent(stickyName)
        XCTAssertEqual(sticky.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }, 0)
        defer { _ = sticky.path.withCString { chflags($0, 0) } }

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.applied, 2)
        XCTAssertEqual(report.deleteFailures, 1)
        XCTAssertEqual(try inboxNames(), [stickyName])
        XCTAssertEqual(try store.loadModel().works.count, 2)
    }

    /// Sixteen identical producers race for the same file name. The event is
    /// the same fact, so exactly one file is stored and every producer
    /// succeeds; the model still applies it once.
    func testConcurrentIdenticalEnqueuesCoalesceIntoOneFact() throws {
        let sample = event("same-id", work: "same", at: epoch)
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                try self.store.enqueue(sample)
            } catch {
                failures.append("\(error)")
            }
        }

        XCTAssertTrue(failures.values.isEmpty, "enqueue failures: \(failures.values)")
        XCTAssertEqual(try inboxNames().count, 1, "an identical replay must not add a second file")

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(report.processedFiles, 1)
        XCTAssertEqual(model.works.count, 1)
        XCTAssertEqual(try inboxNames(), [])
    }

    /// The same event arriving twice is one fact: the second write is accepted
    /// without adding a file, so a producer that retries is not an error.
    func testIdenticalReplayUnderOneNameIsAcceptedWithoutANewFile() throws {
        let sample = event("replay", work: "w", at: epoch)

        try store.enqueue(sample)
        XCTAssertNoThrow(try store.enqueue(sample))

        XCTAssertEqual(try inboxNames(), [EventFileName.make(event: sample, at: sample.timestamp)])

        var model = activatedModel()
        let report = try store.reconcile(&model)
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(model.works.count, 1)
    }

    /// Two different payloads under one name would merge two facts, so the
    /// second write is refused with a detail and the first stays intact.
    func testDifferentContentUnderOneEventNameIsRefused() throws {
        let first = event("reused", work: "one", at: epoch)
        let second = event("reused", work: "two", at: epoch)

        try store.enqueue(first)
        XCTAssertThrowsError(try store.enqueue(second)) { error in
            guard case .writeFailed(let detail)? = error as? StoreError else {
                return XCTFail("expected a content conflict, got \(error)")
            }
            XCTAssertEqual(
                detail,
                "an event with the same identifier already exists with different content"
            )
        }

        XCTAssertEqual(try inboxNames(), [EventFileName.make(event: first, at: first.timestamp)])

        var model = activatedModel()
        let report = try store.reconcile(&model)
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(model.works.count, 1)
        XCTAssertEqual(model.works.first?.key.work, "one", "the stored fact must stay the first one")
    }

    // MARK: - Checkpoint

    func testCorruptCheckpointThrows() throws {
        try store.prepare()
        try Data("not a checkpoint".utf8).write(to: store.checkpoint)

        XCTAssertThrowsError(try store.loadModel()) { error in
            XCTAssertEqual(error as? StoreError, .invalidCheckpoint(self.store.checkpoint.path))
        }
    }

    func testMissingCheckpointLoadsEmptyModel() throws {
        let model = try store.loadModel()
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertTrue(model.gaps.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testCheckpointRequiresEnvelopeCompleteModelAndCurrentSchema() throws {
        try store.prepare()

        // A bare model has no envelope.
        try JSONEncoder().encode(ActivityModel()).write(to: store.checkpoint)
        XCTAssertThrowsError(try store.loadModel()) { error in
            XCTAssertEqual(error as? StoreError, .invalidCheckpoint(self.store.checkpoint.path))
        }

        // A newer store version is named explicitly, not treated as corrupt.
        let future = LocalEventStore.Checkpoint(schema: LocalEventStore.Checkpoint.currentSchema + 1, model: ActivityModel())
        try JSONEncoder().encode(future).write(to: store.checkpoint)
        XCTAssertThrowsError(try store.loadModel()) { error in
            XCTAssertEqual(
                error as? StoreError,
                .unsupportedCheckpoint(self.store.checkpoint.path, LocalEventStore.Checkpoint.currentSchema + 1)
            )
        }

        // A truncated model never decodes as an empty, idle model.
        let truncated = Data(#"{"schema":1,"model":{"activeGenerations":{},"gaps":{},"recentEventIDs":[]}}"#.utf8)
        try truncated.write(to: store.checkpoint)
        XCTAssertThrowsError(try store.loadModel()) { error in
            XCTAssertEqual(error as? StoreError, .invalidCheckpoint(self.store.checkpoint.path))
        }

        // A directory is not a checkpoint.
        try FileManager.default.removeItem(at: store.checkpoint)
        try FileManager.default.createDirectory(at: store.checkpoint, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.loadModel()) { error in
            XCTAssertEqual(error as? StoreError, .invalidCheckpoint(self.store.checkpoint.path))
        }

        try FileManager.default.removeItem(at: store.checkpoint)
        XCTAssertEqual(try store.loadModel().decision.state, .idle)
    }

    func testOversizedCheckpointIsRejected() throws {
        try store.prepare()
        try Data().write(to: store.checkpoint)
        let handle = try FileHandle(forWritingTo: store.checkpoint)
        try handle.truncate(atOffset: UInt64(LocalEventStore.maxCheckpointBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try store.loadModel()) { error in
            XCTAssertEqual(error as? StoreError, .invalidCheckpoint(self.store.checkpoint.path))
        }
    }

    /// Omitting any single model key must fail to load, not reset to idle.
    func testCheckpointOmittingAnyModelKeyIsInvalid() throws {
        try store.prepare()

        var saved = activatedModel()
        XCTAssertEqual(saved.apply(event("matrix", work: "w", at: epoch)), .applied)
        saved.recordGap(family: family, instance: instance, session: nil, reason: .observerLost, at: epoch)

        let encoded = try JSONEncoder().encode(
            LocalEventStore.Checkpoint(schema: LocalEventStore.Checkpoint.currentSchema, model: saved)
        )
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let modelObject = try XCTUnwrap(document["model"] as? [String: Any])
        XCTAssertEqual(Set(modelObject.keys), ["activeGenerations", "works", "gaps", "recentEventIDs"])

        for key in ["activeGenerations", "works", "gaps", "recentEventIDs"] {
            var truncated = modelObject
            truncated.removeValue(forKey: key)
            let data = try JSONSerialization.data(
                withJSONObject: ["schema": document["schema"] ?? 1, "model": truncated]
            )
            try data.write(to: store.checkpoint)

            XCTAssertThrowsError(try store.loadModel(), "omitting \(key) must not load") { error in
                XCTAssertEqual(error as? StoreError, .invalidCheckpoint(self.store.checkpoint.path))
            }
        }

        try encoded.write(to: store.checkpoint)
        XCTAssertEqual(try store.loadModel().works.count, 1)
        XCTAssertEqual(try store.loadModel().gaps.count, 1)
    }

    func testCheckpointSymlinkIsRejected() throws {
        try store.prepare()
        let target = root.appendingPathComponent("elsewhere.json")
        var saved = ActivityModel()
        saved.activate(family: family, generation: 1)
        try store.saveModel(saved)
        try FileManager.default.moveItem(at: store.checkpoint, to: target)
        try FileManager.default.createSymbolicLink(at: store.checkpoint, withDestinationURL: target)

        XCTAssertThrowsError(try store.loadModel()) { error in
            XCTAssertEqual(error as? StoreError, .invalidCheckpoint(self.store.checkpoint.path))
        }
    }

    func testStaleTemporaryFilesAreSwept() throws {
        try store.prepare()
        let staleNames = [
            store.root.appendingPathComponent(".checkpoint.json.stale.tmp"),
            store.inbox.appendingPathComponent(".abc.event.stale.tmp"),
            store.rejected.appendingPathComponent(".old.event.stale.tmp")
        ]
        let live = store.root.appendingPathComponent(".checkpoint.json.live.tmp")
        for file in staleNames + [live] {
            try Data("partial".utf8).write(to: file)
        }
        for file in staleNames {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-2 * LocalEventStore.staleTemporaryAge)],
                ofItemAtPath: file.path
            )
        }

        try store.prepare()

        for file in staleNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) should be swept")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    // MARK: - Writer lock

    func testWriterLockBlocksReconcile() throws {
        try store.prepare()
        try store.enqueue(event("locked", work: "w", at: epoch))

        let descriptor = store.lock.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        var model = activatedModel()
        XCTAssertThrowsError(try store.reconcile(&model)) { error in
            XCTAssertEqual(error as? StoreError, .locked)
        }
        XCTAssertEqual(try inboxNames().count, 1)

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        _ = Darwin.close(descriptor)

        let report = try store.reconcile(&model)
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(try inboxNames(), [])
    }

    func testReconcileWaitsForAProducerHoldingTheWriterLock() throws {
        try store.prepare()
        try store.enqueue(event("waited", work: "w", at: epoch))

        let descriptor = store.lock.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        // A producer releases the shared lock well inside the bounded wait, so
        // the pass must retry and apply instead of reporting `locked`.
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
            _ = Darwin.close(descriptor)
            released.signal()
        }

        var model = activatedModel()
        let report = try store.reconcile(&model)

        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(try inboxNames(), [])
        released.wait()
    }

    // MARK: - Permissions

    func testCheckpointAndDirectoriesHaveOwnerOnlyPermissions() throws {
        try store.saveModel(ActivityModel())
        try store.enqueue(event("perm", work: "w"))

        XCTAssertEqual(try permissions(store.root), 0o700)
        XCTAssertEqual(try permissions(store.inbox), 0o700)
        XCTAssertEqual(try permissions(store.rejected), 0o700)
        XCTAssertEqual(try permissions(store.checkpoint), 0o600)

        let names = try inboxNames()
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(try permissions(store.inbox.appendingPathComponent(names[0])), 0o600)
    }

    /// Existing directories are left exactly as they are; only new ones get
    /// owner-only access.
    func testPrepareDoesNotRewriteExistingDirectoryPermissions() throws {
        try store.prepare()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.root.path)

        try store.prepare()

        XCTAssertEqual(try permissions(store.root), 0o755)
        XCTAssertEqual(try permissions(store.inbox), 0o700)
        XCTAssertEqual(try permissions(store.rejected), 0o700)
    }

    // MARK: - File names

    func testCanonicalIdentifiersProduceParseableNames() throws {
        let sample = event("evt-1", work: "w", instanceName: "cli")

        try store.enqueue(sample)

        let names = try inboxNames()
        XCTAssertEqual(names.count, 1)
        let name = names[0]
        XCTAssertEqual(name, EventFileName.make(event: sample, at: sample.timestamp))

        let parts = name.split(separator: "@", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[2].count, 20)

        let scope = try XCTUnwrap(EventFileName.scope(of: name))
        XCTAssertEqual(scope.family, family)
        XCTAssertEqual(scope.instance, instance)

        var model = activatedModel()
        let report = try store.reconcile(&model)
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(model.works.count, 1)
    }

    func testEnqueueRejectsUnsafeIdentifiersAndOversizePayloads() throws {
        XCTAssertThrowsError(try store.enqueue(event("id/../x", work: "w"))) { error in
            XCTAssertEqual(error as? StoreError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try store.enqueue(event("ok", work: "w", source: "../../evil"))) { error in
            XCTAssertEqual(error as? StoreError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try store.enqueue(event("ok", work: "w", instanceName: "in/stance"))) { error in
            XCTAssertEqual(error as? StoreError, .invalidIdentifier)
        }
        XCTAssertEqual(try inboxNames(), [])

        var limits = LocalEventStore.Limits()
        limits.maxEventBytes = 32
        let limited = LocalEventStore(root: root, limits: limits)
        XCTAssertThrowsError(try limited.enqueue(event("big", work: "w"))) { error in
            XCTAssertEqual(error as? StoreError, .eventTooLarge)
        }
        XCTAssertEqual(try inboxNames(), [])
    }

    /// Two identifiers that differ only by case must never be folded into one
    /// stored fact. On a case-insensitive volume the second write is refused as
    /// a content conflict; on a case-sensitive volume it is a separate file.
    func testIdentifiersDifferingOnlyByCaseAreNeverConflated() throws {
        let upper = event("Same", work: "one", at: epoch)
        let lower = event("same", work: "two", at: epoch)
        try store.prepare()

        let probe = root.appendingPathComponent("CaseProbe")
        try Data().write(to: probe)
        let foldsCase = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("caseprobe").path
        )
        try FileManager.default.removeItem(at: probe)

        try store.enqueue(upper)
        var model = activatedModel()

        if foldsCase {
            XCTAssertThrowsError(try store.enqueue(lower)) { error in
                guard case .writeFailed? = error as? StoreError else {
                    return XCTFail("expected a content conflict, got \(error)")
                }
            }
            XCTAssertEqual(try inboxNames().count, 1)
            XCTAssertEqual(try store.reconcile(&model).applied, 1)
            XCTAssertEqual(model.works.first?.key.work, "one")
        } else {
            try store.enqueue(lower)
            XCTAssertEqual(try inboxNames().count, 2)
            XCTAssertEqual(try store.reconcile(&model).applied, 2)
            XCTAssertEqual(model.works.count, 2)
        }
        XCTAssertEqual(try inboxNames(), [])
    }

    func testScopeParsingRequiresTimestampAndFourParts() {
        XCTAssertNil(EventFileName.scope(of: "codex@cli.event"))
        XCTAssertNil(EventFileName.scope(of: "codex@cli@not-a-stamp@id.event"))
        XCTAssertNil(EventFileName.scope(of: "codex@cli@1700000000000000@id.event"), "16-digit stamps are not ours")
        XCTAssertNil(EventFileName.scope(of: "codex@cli@17000000000000000000@id@extra.event"))
        XCTAssertNil(EventFileName.scope(of: "@cli@17000000000000000000@id.event"))

        let parsed = EventFileName.scope(of: "codex@cli@17000000000000000000@id.event")
        XCTAssertEqual(parsed?.family, "codex")
        XCTAssertEqual(parsed?.instance, "cli")
    }

    func testSanitizeBoundsAndFallback() {
        XCTAssertEqual(EventFileName.sanitize(""), "_")
        XCTAssertEqual(EventFileName.sanitize("a/b c.d"), "a_b_c_d")
        XCTAssertEqual(EventFileName.sanitize(String(repeating: "x", count: 200)).count, 64)
    }

    // MARK: - Helpers

    private func activatedModel() -> ActivityModel {
        var model = ActivityModel()
        model.activate(family: family, generation: 1)
        return model
    }

    private func inboxNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.inbox.path).sorted()
    }

    private func rejectedNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.rejected.path).sorted()
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func fileName(
        family: String,
        id: String,
        at date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> String {
        let micros = UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded(.down)))
        return "\(family)@\(instance)@\(String(format: "%020llu", micros))@\(id).event"
    }

    private func event(
        _ id: String,
        work: String,
        source: String = "codex",
        instanceName: String? = nil,
        transition: ActivityTransition = .started,
        at date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            source: source,
            activationGeneration: 1,
            owner: OwnerIdentity(
                bootID: "boot-1",
                pid: 42,
                startTimeMicros: 1_000,
                uid: 501,
                instance: instanceName ?? instance
            ),
            session: SessionIdentity(
                family: source,
                instance: instanceName ?? instance,
                session: "s1"
            ),
            transition: transition,
            work: work,
            generation: 1,
            timestamp: date
        )
    }
}

private final class FailureBox {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
