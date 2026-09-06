import Core
import Foundation
import Testing
@testable import Services

@Suite("Domain 12 parity replay")
struct Domain12ParityReplayTests {
    private let sourceRunID = RunID()
    private let producedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Python bounded fan-out preserves Swift plan admission and source order")
    func replaysBoundedPlanning() async throws {
        let reference = try loadReference()

        #expect(reference.schemaVersion == 1)
        #expect(reference.pythonBaseline == "0f6dca1f36eab74a6899a0f770511927b68d3e15")

        for replayCase in reference.cases.compactMap(\.concurrency) {
            try await replay(replayCase)
        }
    }

    @Test("Python full-pipeline triggers preserve Swift preview and write outcomes")
    func replaysCanonicalTriggers() async throws {
        let reference = try loadReference()

        for replayCase in reference.cases.compactMap(\.orchestration) {
            try await replay(replayCase)
        }
    }

    @MainActor
    @Test("Week Pass expiry changes live access at the exact clock boundary")
    func replaysWeekPassBoundary() async throws {
        let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = purchaseDate.addingTimeInterval(7 * 86400)
        let date = TestDate(expiry.addingTimeInterval(-1))
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(weekPassPurchases: [purchaseDate])
        )
        let sleeper = TestSleeper()
        var tierChangeCount = 0
        let service = try SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: #require(UserDefaults(suiteName: UUID().uuidString)),
            dateProvider: date.now,
            entitlementSource: source,
            sleep: sleeper.sleep,
            tierChangeHandler: { tierChangeCount += 1 }
        )

        await service.refreshEntitlements()
        #expect(service.currentTier == .weekPass)
        #expect(await sleeper.waitForDelay() == .seconds(1))

        date.set(expiry)
        await sleeper.resume()
        await source.waitForSnapshots(2)

        #expect(service.currentTier == .free)
        #expect(tierChangeCount == 2)
    }

    @Test("Pro billing grace ends at the signed StoreKit boundary")
    func replaysBillingGraceBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let graceExpiry = now.addingTimeInterval(3 * 86400)
        let snapshot = StoreEntitlementSnapshot(
            proStatuses: [.billingGrace(expiresAt: graceExpiry)]
        )

        let beforeExpiry = SubscriptionService.resolveEntitlements(
            snapshot,
            at: graceExpiry.addingTimeInterval(-1)
        )
        let atExpiry = SubscriptionService.resolveEntitlements(snapshot, at: graceExpiry)

        #expect(beforeExpiry.tier == .pro)
        #expect(beforeExpiry.proAccess == .billingGrace(expiresAt: graceExpiry))
        #expect(beforeExpiry.nextBoundary == graceExpiry)
        #expect(atExpiry.tier == .free)
        #expect(atExpiry.proAccess == nil)
        #expect(atExpiry.nextBoundary == nil)
    }

    private func replay(_ replayCase: ConcurrencyCase) async throws {
        #expect(replayCase.kind == "concurrency")
        let firstUnit = try #require(replayCase.input.units.first)
        let secondUnit = try #require(replayCase.input.units.dropFirst().first)
        #expect(firstUnit.delayMilliseconds > secondUnit.delayMilliseconds)
        let tracks = replayCase.input.units.map {
            track($0.id, artist: $0.artist, album: $0.album)
        }
        let outcomes = Dictionary(uniqueKeysWithValues: zip(replayCase.input.units, tracks).map { unit, currentTrack in
            let outcome: DeterminationOutcome = switch unit.failureKind {
            case nil: .changes([proposal(for: currentTrack)])
            case .writeEligibility: .trackNotEditable
            case .unclassified: .failure
            }
            return (unit.id, outcome)
        })
        let concurrency = PlanConcurrencyProbe(trackDelays: Dictionary(uniqueKeysWithValues:
            replayCase.input.units.map { ($0.id, Duration.milliseconds($0.delayMilliseconds)) }
        ))
        let spy = FixPlanProducerSpy(
            tracks: tracks,
            outcomes: outcomes,
            concurrency: concurrency
        )
        let configuration = makeConfiguration(replayCase.input.limits)

        let produce = {
            try await makeProducer(spy).producePlan(
                sourceRunID: sourceRunID,
                scope: certifiedScope(ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: tracks.count,
                    createdAt: Date(timeIntervalSince1970: 100),
                    reason: "domain-12-replay"
                )),
                configuration: configuration
            )
        }
        switch replayCase.expected.swiftDisposition {
        case .continuePlanning:
            _ = try await produce()
            let saved = try #require(await spy.savedPlans().first)
            #expect(
                saved.plan.items.map(\.identity.readID) == replayCase.expected.pythonProposalOrder,
                Comment(rawValue: "[\(replayCase.id)] \(replayCase.description): proposal order differs")
            )
        case .abort:
            await #expect(throws: ProducerTestError.self) {
                _ = try await produce()
            }
            #expect(await spy.savedPlans().isEmpty)
        }
        #expect(
            await concurrency.maximumActiveCount() == replayCase.expected.swiftMaximumActive,
            Comment(rawValue: "[\(replayCase.id)] \(replayCase.description): admission differs")
        )
        assertDivergences(in: replayCase)
    }

    private func assertDivergences(in replayCase: ConcurrencyCase) {
        #expect(replayCase.divergences.allSatisfy { !$0.reason.isEmpty })
        let maximum = replayCase.divergences.first { $0.field == "maximumActive" }
        if replayCase.expected.pythonMaximumActive == replayCase.expected.swiftMaximumActive {
            #expect(maximum == nil)
        } else {
            #expect(maximum?.pythonValue == String(replayCase.expected.pythonMaximumActive))
            #expect(maximum?.swiftValue == String(replayCase.expected.swiftMaximumActive))
        }

        let failure = replayCase.divergences.first { $0.field == "failureDisposition" }
        if replayCase.expected.swiftDisposition == .abort {
            #expect(failure?.pythonValue == "continue")
            #expect(failure?.swiftValue == "abort")
        } else {
            #expect(failure == nil)
        }
    }

    private func makeProducer(_ spy: FixPlanProducerSpy) -> FixPlanProducer {
        FixPlanProducer(dependencies: .init(
            loadAdmission: { scope, _ in
                await .admitted(
                    processingAdmission(scope: scope),
                    tracks: spy.loadTracks()
                )
            },
            makeRuntime: { _, _ in
                FixPlanProducer.Runtime(
                    refreshIdentity: { try await spy.refreshWriteIdentity(for: $0, scope: $1) },
                    albumContext: { await spy.albumContextTracksByTrackID(for: $0) },
                    artistContext: { await spy.artistContextTracksByTrackID(for: $0) },
                    determineChanges: { track, albumTracks, artistTracks, options, _ in
                        try await spy.determineTrackChanges(
                            track: track,
                            albumTracks: albumTracks,
                            artistTracks: artistTracks,
                            options: options
                        )
                    }
                )
            },
            savePlan: { await spy.savePlan($0, decision: $1) },
            now: { producedAt }
        ))
    }

    private func makeConfiguration(_ limits: Limits) -> FixPlanConfig {
        var configuration = AppConfiguration()
        configuration.genreUpdate.concurrentLimit = limits.artist
        configuration.applescript.concurrency = limits.musicApp
        configuration.yearRetrieval.rateLimits.concurrentAlbums = limits.albumWorkflows
        return FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(updateGenre: true, updateYear: true, minConfidence: 60),
            capturedAt: producedAt
        )
    }

    private func replay(_ replayCase: OrchestrationCase) async throws {
        let trigger = try #require(RunTrigger(rawValue: replayCase.input.trigger))
        let mode = try #require(RunProcessingMode(rawValue: replayCase.input.swiftMode))
        let automation = try #require(AutomationStrategy(rawValue: replayCase.input.automation))
        let planID = FixPlanID()
        let records = RunRecordProbe()
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: producedAt
        )
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                automaticInput(planID: producedPlanID, planning: planning, capturedAt: producedAt)
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            now: { producedAt }
        ))

        let result = await orchestrator.submit(.preview(
            trigger: trigger,
            configuration: configuration,
            mode: mode,
            automation: automation,
            requestedTestArtists: [],
            knownTrackCount: 1
        ))

        let finished = await records.records.filter { $0.finishedAt != nil }
        #expect(finished.map(\.intent.rawValue) == replayCase.swiftExpected.persistedIntents)
        #expect(result.lifecycle?.intent.rawValue == replayCase.swiftExpected.terminalIntent)
        #expect(await writeProbe.calls.count == replayCase.swiftExpected.writeCount)
        #expect(replayCase.pythonExpected.pipelineRuns == 1)
        #expect(!replayCase.pythonExpected.force)
        #expect(!replayCase.pythonExpected.fresh)
        let expectedDryRunMode = replayCase.input.pythonDryRun ? "dry_run" : nil
        #expect(replayCase.pythonExpected.dryRunMode == expectedDryRunMode)
        #expect(replayCase.divergences.allSatisfy { !$0.reason.isEmpty })
        let modeDivergence = replayCase.divergences.first { $0.field == "mode" }
        if replayCase.input.pythonDryRun == (mode == .preview) {
            #expect(modeDivergence == nil)
        } else {
            #expect(modeDivergence != nil)
        }
        if replayCase.swiftExpected.writeCount == 1 {
            #expect(finished.last?.writeTarget?.planID == planID)
        }
    }

    private func loadReference() throws -> Reference {
        let url = try #require(
            Bundle.module.url(
                forResource: "domain_12_reference",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }
}

private struct Reference: Decodable {
    let schemaVersion: Int
    let pythonBaseline: String
    let cases: [ReplayCase]
}

private enum ReplayCase: Decodable {
    case concurrency(ConcurrencyCase)
    case orchestration(OrchestrationCase)

    private enum Kind: String, Decodable {
        case concurrency
        case orchestration
    }

    private enum CodingKeys: CodingKey {
        case kind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .concurrency:
            self = try .concurrency(ConcurrencyCase(from: decoder))
        case .orchestration:
            self = try .orchestration(OrchestrationCase(from: decoder))
        }
    }

    var concurrency: ConcurrencyCase? {
        guard case let .concurrency(replayCase) = self else { return nil }
        return replayCase
    }

    var orchestration: OrchestrationCase? {
        guard case let .orchestration(replayCase) = self else { return nil }
        return replayCase
    }
}

private struct ConcurrencyCase: Decodable {
    let id: String
    let kind: String
    let description: String
    let input: Input
    let expected: Expected
    let divergences: [Divergence]

    struct Input: Decodable {
        let limits: Limits
        let units: [Unit]
    }

    struct Unit: Decodable {
        let id: String
        let artist: String
        let album: String
        let delayMilliseconds: Int64
        let failureKind: FailureKind?
    }

    struct Expected: Decodable {
        let pythonMaximumActive: Int
        let swiftMaximumActive: Int
        let pythonProposalOrder: [String]
        let swiftDisposition: SwiftDisposition
    }

    struct Divergence: Decodable {
        let field: String
        let pythonValue: String
        let swiftValue: String
        let reason: String
    }

    enum FailureKind: String, Decodable {
        case writeEligibility
        case unclassified
    }

    enum SwiftDisposition: String, Decodable {
        case continuePlanning = "continue"
        case abort
    }
}

private struct Limits: Decodable {
    let artist: Int
    let musicApp: Int
    let albumWorkflows: Int
}

private struct OrchestrationCase: Decodable {
    let id: String
    let description: String
    let input: Input
    let pythonExpected: PythonExpected
    let swiftExpected: SwiftExpected
    let divergences: [Divergence]

    struct Input: Decodable {
        let trigger: String
        let swiftMode: String
        let automation: String
        let pythonDryRun: Bool
    }

    struct PythonExpected: Decodable {
        let pipelineRuns: Int
        let dryRunMode: String?
        let force: Bool
        let fresh: Bool
    }

    struct SwiftExpected: Decodable {
        let persistedIntents: [String]
        let terminalIntent: String
        let writeCount: Int
    }

    struct Divergence: Decodable {
        let field: String
        let reason: String
    }
}
