import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

/// D3 (slice 12): the orchestrator's batch runner bridge reaches the
/// registered live provider, and a windowless submit fails fast with an
/// honest record instead of running blind.
@Suite("Batch run app wiring")
@MainActor
struct BatchRunAppTests {
    @Test("a submitted batch reaches the registered provider and records")
    func submittedBatchReachesProviderAndRecords() async throws {
        let dependencies = makeBatchTestDependencies()
        let records = RecordCollector()
        let received = ReceivedRunBox()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { await records.append($0) },
            runBatchUpdate: dependencies.makeBatchRunnerBridge()
        )))
        dependencies.batchRunProvider = { _, runID in
            received.runID = runID
            return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
        }

        let result = try await dependencies.submitBatchRun(
            input: BatchRunInput(
                options: UpdateOptions(),
                trackCount: 2,
                admission: workflowProcessingAdmission(trackCount: 2)
            )
        )

        guard case .completedNoOp = result else {
            Issue.record("Expected completedNoOp, got \(result)")
            return
        }
        let stored = await records.records
        #expect(stored.first?.intent == .batchUpdate)
        #expect(stored.first?.finishedAt == nil)
        #expect(stored.last?.finishedAt != nil)
        #expect(received.runID == stored.last?.runID)
    }

    @Test("an unregistered provider fails the batch run fast")
    func unregisteredProviderFailsBatchFast() async throws {
        let dependencies = makeBatchTestDependencies()
        let records = RecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { await records.append($0) },
            runBatchUpdate: dependencies.makeBatchRunnerBridge()
        )))

        let result = try await dependencies.submitBatchRun(
            input: BatchRunInput(
                options: UpdateOptions(),
                trackCount: 2,
                admission: workflowProcessingAdmission(trackCount: 2)
            )
        )

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        let terminal = await records.records.last
        #expect(terminal?.failureMessage?.contains("Batch runner is unavailable") == true)
    }

    @Test("a full-library batch flows through the orchestrator to done")
    func fullLibraryBatchFlowsThroughOrchestratorToDone() async {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.updateGenre = true
        viewModel.updateYear = false

        viewModel.startBatchProcessing(tracks: [
            Track(id: "batch-1", name: "Song", artist: "Artist", album: "Album", genre: "Old"),
        ])
        await viewModel.processingTask?.value

        guard case .done = viewModel.phase else {
            Issue.record("Expected done phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.result != nil)
        #expect(viewModel.pendingBatchExecution == nil)
    }

    @Test("an uncertain batch outcome leaves recovery to the orchestrator")
    func uncertainBatchOutcomeLeavesRecoveryToOrchestrator() async {
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            configure: { options in
                options.outcomeTrackIDs = ["unknown-batch"]
            }
        )
        let viewModel = fixture.viewModel
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.startBatchProcessing(tracks: [makeWritableTrack(
            "unknown-batch",
            name: "Batch Year",
            artist: "Clutch",
            album: "Pure Rock Fury",
            fields: WritableTrackFields(year: 1999)
        )])
        await viewModel.processingTask?.value

        guard case .error = viewModel.phase else {
            Issue.record("Expected error phase, got \(viewModel.phase)")
            return
        }
        // Ownership moved: the run's recovery hold lives with the
        // orchestrator's processor call, not a second view-model hold.
        #expect(viewModel.recoveryHoldID == nil)
    }

    @Test("a pre-runner terminal lands on the failure, not a stuck screen")
    func preRunnerTerminalLandsOnFailure() async {
        let fixture = makeWorkflowFixture(configure: { options in
            options.failRunRecordPersistence = true
        })
        let viewModel = fixture.viewModel

        viewModel.startBatchProcessing(tracks: [
            Track(id: "t1", name: "Song", artist: "Artist", album: "Album"),
        ])
        await viewModel.processingTask?.value

        guard case .error = viewModel.phase else {
            Issue.record("Expected error phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.pendingBatchExecution == nil)
    }

    @Test("the stash survives a queued submission and the batch executes")
    func stashSurvivesQueuedSubmissionAndExecutes() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        await fixture.observationGate.arm()
        let observation = Task {
            await fixture.orchestrator.submit(.manualObservation(requestedTestArtists: [], knownTrackCount: nil))
        }
        await fixture.observationGate.waitUntilEntered()

        viewModel.startBatchProcessing(tracks: [
            Track(id: "q1", name: "Song", artist: "Artist", album: "Album"),
        ])
        await viewModel.processingTask?.value
        #expect(viewModel.pendingBatchExecution != nil)
        let admitted = await fixture.admissionProbe.admitted.first
        #expect(admitted?.match == .exactScope)
        viewModel.updateYear.toggle()

        await fixture.observationGate.release()
        _ = await observation.value
        try await waitForTerminalPhase(viewModel)

        guard case .done = viewModel.phase else {
            Issue.record("Expected done phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.pendingBatchExecution == nil)
        let validated = await fixture.admissionProbe.validated.first
        #expect(validated?.match == .subset)
        #expect(validated?.admission == admitted?.admission)
    }

    @Test("cancelling a queued batch records an honest cancelled run")
    func cancellingQueuedBatchRecordsCancelledRun() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        await fixture.observationGate.arm()
        let observation = Task {
            await fixture.orchestrator.submit(.manualObservation(requestedTestArtists: [], knownTrackCount: nil))
        }
        await fixture.observationGate.waitUntilEntered()

        viewModel.startBatchProcessing(tracks: [
            Track(id: "c1", name: "Song", artist: "Artist", album: "Album"),
        ])
        await viewModel.processingTask?.value
        viewModel.cancel()

        guard case .configure = viewModel.phase else {
            Issue.record("Expected configure phase after cancel, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.pendingBatchExecution == nil)

        await fixture.observationGate.release()
        _ = await observation.value
        try await Task.sleep(for: .milliseconds(200))

        // Cancel either purged the trigger (no batch run at all) or the
        // fallback recorded cancelled — never a completed/failed run the
        // user did not want.
        let batchRecords = await fixture.runRecords.records.filter { $0.intent == .batchUpdate }
        // The append-only collector may retain the fallback path's OPEN
        // preflight row; only a terminal row other than cancelled would
        // betray an unwanted run.
        #expect(batchRecords.allSatisfy { $0.finishedAt == nil || $0.state == .cancelled })
    }

    @Test("a free user sees one used track after a successful batch")
    func freeBatchConsumesAllowance() async throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        let subscription = SubscriptionService(
            counterStore: MemoryCounterStore(),
            userDefaults: defaults
        )
        let gate = AppDependencies.makeFeatureGate(for: subscription)
        let fixture = makeWorkflowFixture(configure: { options in
            options.featureGate = gate
        })
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "apply-1", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        guard case .done = viewModel.phase else {
            Issue.record("Expected done phase, got \(viewModel.phase)")
            return
        }
        let batchRecords = await fixture.runRecords.records.filter { $0.intent == .batchUpdate }
        #expect(batchRecords.last?.state == .completed)
        #expect(viewModel.pendingBatchExecution == nil)
        #expect(subscription.freeTracksUsed == 1)
    }

    @Test("a free user cannot apply accepted cleaning")
    func freeUserCannotApplyCleaning() async {
        let fixture = makeWorkflowFixture(configure: { options in
            options.tier = .free
        })
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(
                id: "paid-cleaning",
                isAccepted: true,
                changeType: .trackCleaning
            ),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        guard case .error = viewModel.phase else {
            Issue.record("Expected paid cleaning admission error, got \(viewModel.phase)")
            return
        }
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("a pro user keeps the free allowance after a successful batch")
    func proBatchKeepsAllowance() async throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        let subscription = SubscriptionService(
            counterStore: MemoryCounterStore(),
            userDefaults: defaults
        )
        let gate = AppDependencies.makeFeatureGate(for: subscription, fixedTier: .pro)
        let fixture = makeWorkflowFixture(configure: { options in
            options.featureGate = gate
        })
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "pro-apply-1", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        guard case .done = viewModel.phase else {
            Issue.record("Expected done phase, got \(viewModel.phase)")
            return
        }
        #expect(subscription.freeTracksUsed == 0)
    }

    @Test("a lost terminal record surfaces recovery instead of a done screen")
    func lostTerminalRecordSurfacesRecovery() async {
        let fixture = makeWorkflowFixture(configure: { options in
            options.failTerminalRunRecordPersistence = true
        })
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "apply-lost", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        // The writes applied but the terminal record could not persist:
        // the orchestrator holds recovery, and a done screen would hide
        // that until the next write attempt.
        guard case .error = viewModel.phase else {
            Issue.record("Expected error phase, got \(viewModel.phase)")
            return
        }
    }

    @Test("cancelling a queued smart-filter apply keeps the library untouched")
    func cancellingQueuedSmartFilterApplyKeepsLibraryUntouched() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        await fixture.observationGate.arm()
        let observation = Task {
            await fixture.orchestrator.submit(.manualObservation(requestedTestArtists: [], knownTrackCount: nil))
        }
        await fixture.observationGate.waitUntilEntered()

        viewModel.mode = .smartFilter
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "sf-apply", isAccepted: true)]
        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        #expect(viewModel.pendingBatchExecution != nil)

        viewModel.cancel()
        #expect(viewModel.pendingBatchExecution == nil)

        await fixture.observationGate.release()
        _ = await observation.value
        try await Task.sleep(for: .milliseconds(200))

        // The stash gate — not the mode — makes cancel real: no write
        // and no unwanted terminal may appear after an explicit cancel.
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
        let batchRecords = await fixture.runRecords.records.filter { $0.intent == .batchUpdate }
        #expect(batchRecords.allSatisfy { $0.finishedAt == nil || $0.state == .cancelled })
    }

    @Test("an uncertain apply leaves recovery to the orchestrator")
    func uncertainApplyLeavesRecoveryToOrchestrator() async {
        let fixture = makeWorkflowFixture(configure: { options in
            options.outcomeTrackIDs = ["apply-unknown"]
        })
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "apply-unknown", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        guard case .error = viewModel.phase else {
            Issue.record("Expected error phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.recoveryHoldID == nil)
        #expect(await fixture.batchProcessor.recoveryHoldID() != nil)
        let batchRecords = await fixture.runRecords.records.filter { $0.intent == .batchUpdate }
        #expect(batchRecords.last?.state == .recoverable)
    }

    @Test("the batch request carries the configured test-artist scope")
    func batchRequestCarriesTestArtistScope() async throws {
        let dependencies = makeBatchTestDependencies()
        dependencies.config.development.testArtists = ["Clutch"]
        let records = RecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { await records.append($0) },
            runBatchUpdate: dependencies.makeBatchRunnerBridge()
        )))
        dependencies.batchRunProvider = { _, _ in
            BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
        }

        _ = try await dependencies.submitBatchRun(
            input: BatchRunInput(
                options: UpdateOptions(),
                trackCount: 1,
                admission: workflowProcessingAdmission(trackCount: 1, testArtists: ["Clutch"])
            )
        )

        #expect(await records.records.first?.scope.source == .testArtists)
    }

    private func waitForTerminalPhase(
        _ viewModel: WorkflowViewModel,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch viewModel.phase {
            case .done, .error, .configure:
                return
            default:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("Timed out waiting for a terminal phase; last: \(viewModel.phase)")
    }

    private func makeBatchTestDependencies() -> AppDependencies {
        AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to these wiring pins.
            }
        )
    }
}

private actor RecordCollector {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) {
        records.append(record)
    }
}

/// The provider closure is @MainActor; a plain box keeps the received
/// run ID observable without crossing isolation.
@MainActor
private final class ReceivedRunBox {
    var runID: RunID?
}

/// The metering closure runs on MainActor with the view-model; a box
/// keeps the accumulated count observable.
@MainActor
final class MeteredTracksBox {
    var count = 0
}

private final class MemoryCounterStore: SubscriptionCounterStore {
    private var values: [String: Int64] = [:]

    func counter(forKey key: String) -> Int64 {
        values[key, default: 0]
    }

    func setCounter(_ value: Int64, forKey key: String) {
        values[key] = value
    }
}
