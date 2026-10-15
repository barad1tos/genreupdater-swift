import Core
import Foundation
import Testing
@testable import Genre_Updater

@Suite("Workflow recovery")
@MainActor
struct WorkflowRecoveryTests {
    @Test("Unknown write blocks alternate scopes until recovery clearance")
    func unknownWriteBlocks() async {
        let fixture = makeWorkflowFixture(configure: { options in
            options.outcomeTrackIDs = ["unknown"]
        })
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "unknown", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        // Option A (slice-12 PR C): recovery belongs to the run — no
        // view-model hold; the processor hold installed by
        // performRecoverableWrite blocks the next write attempt.
        #expect(viewModel.recoveryHoldID == nil)
        let processorHold = await fixture.batchProcessor.recoveryHoldID()
        #expect(processorHold != nil)

        viewModel.configureFullLibraryScope(tracks: [Track(id: "safe", name: "Safe", artist: "Artist", album: "Album")])
        viewModel.updateGenre = true
        viewModel.updateYear = false
        viewModel.previewOnly = false
        viewModel.phase = .review
        viewModel.proposedChanges = [makeProposedChange(id: "safe", isAccepted: true)]
        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
        // The blocked second attempt adopts the processor hold, so the
        // view-model's clear flow remains reachable.
        #expect(viewModel.recoveryHoldID == processorHold)
        #expect(!viewModel.canStart)

        await viewModel.clearRecoveryHold()
        #expect(viewModel.recoveryHoldID == nil)
        #expect(viewModel.canStart)
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "safe", isAccepted: true)]
        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        #expect(await fixture.scriptClient.updatedProperties().map(\.databaseID.rawValue) == ["safe"])
    }

    @Test("Fallback marker blocks a restarted workflow")
    func fallbackMarkerBlocksRestart() async throws {
        let checkpointRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Workflow-invalid-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: checkpointRoot)
        defer { try? FileManager.default.removeItem(at: checkpointRoot) }
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let suiteName = temporaryDefaults.suiteName
        let firstFixture = makeWorkflowFixture(configure: { options in
            options.checkpointDirectory = checkpointRoot
            options.recoverySuiteName = suiteName
        })
        let recoveryID = await firstFixture.batchProcessor.beginRecoveryHold()
        let restarted = makeWorkflowFixture(configure: { options in
            options.checkpointDirectory = checkpointRoot
            options.recoverySuiteName = suiteName
        })
        let viewModel = restarted.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "safe", isAccepted: true)]
        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        #expect(viewModel.recoveryHoldID == recoveryID)
        #expect(!viewModel.canStart)
        #expect(await restarted.scriptClient.updatedProperties().isEmpty)

        try FileManager.default.removeItem(at: checkpointRoot)
        try FileManager.default.createDirectory(at: checkpointRoot, withIntermediateDirectories: true)
        await viewModel.clearRecoveryHold()
        #expect(viewModel.recoveryHoldID == nil)
        #expect(await restarted.batchProcessor.recoveryHoldID() == nil)
    }
}
