import Core
import Foundation
import Services
import Testing

@Suite("FixPlanProducer")
struct FixPlanProducerTests {
    private let sourceRunID = RunID()
    private let producedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("rejected admission fails instead of masquerading as an empty plan")
    func rejectsAdmission() async {
        let spy = FixPlanProducerSpy(
            tracks: [track("BLOCKED")],
            admissionRejection: .scopeMismatch
        )

        await #expect(throws: ProcessingAdmissionRejection.scopeMismatch) {
            _ = try await makeProducer(spy).producePlan(
                sourceRunID: sourceRunID,
                scope: scope(requestedTestArtists: [], knownTrackCount: 1),
                configuration: configuration()
            )
        }

        #expect(await spy.runtimeCreationCount() == 0)
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("planning uses the exact tracks returned by admission")
    func plansAdmittedTracks() async throws {
        let admitted = track("ADMITTED", artist: "Canonical Artist")
        let spy = FixPlanProducerSpy(
            tracks: [admitted],
            admittedTracks: [admitted],
            outcomes: ["ADMITTED": .changes([proposal(for: admitted)])]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: ["Configured Artist"], knownTrackCount: 1),
            configuration: configuration(UpdateOptions(minConfidence: 60))
        )

        #expect(production.proposalCount == 1)
        #expect(await spy.refreshInputs() == [["ADMITTED"]])
        #expect(await spy.determinationCalls().map(\.trackID) == ["ADMITTED"])
    }

    @Test("scoping skips out-of-scope artists before determination")
    func filtersBeforePlanning() async throws {
        let inScope = track("IN", artist: "Aphex Twin")
        let outOfScope = track("OUT", artist: "Boards of Canada")
        let spy = FixPlanProducerSpy(
            tracks: [inScope, outOfScope],
            outcomes: ["IN": .changes([proposal(for: inScope)])]
        )
        let currentScope = scope(requestedTestArtists: ["aphex twin"], knownTrackCount: 2)

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: currentScope,
            configuration: configuration(UpdateOptions(minConfidence: 60))
        )

        #expect(production.producedPlan)
        #expect(production.proposalCount == 1)
        #expect(await spy.refreshInputs() == [["IN"]])
        #expect(await spy.refreshScopes() == [currentScope])
        #expect(await spy.albumContextInputs() == [["IN"]])
        #expect(await spy.determinationCalls().map(\.trackID) == ["IN"])
        #expect(await spy.eventLog() == ["refresh", "context", "determine:IN"])
    }

    @Test("empty scope skips enrichment and determination")
    func emptyScopeSkipsWork() async throws {
        let spy = FixPlanProducerSpy(tracks: [track("OUT", artist: "Other")])

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: ["In Scope"], knownTrackCount: 1),
            configuration: configuration()
        )

        #expect(production == .empty)
        #expect(await spy.eventLog().isEmpty)
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("a testArtists snapshot with an empty list plans nothing")
    func degenerateScopeFailsClosed() async throws {
        // capture() cannot produce this shape; a decoded or hand-built
        // snapshot can. ArtistAllowList.filter's empty-list arm would
        // widen the plan to the whole library — the producer must fail
        // closed instead.
        let spy = FixPlanProducerSpy(tracks: [track("ANY", artist: "Anyone")])
        let degenerateScope = ProcessingScopeSnapshot(
            createdAt: Date(timeIntervalSince1970: 100),
            source: .testArtists,
            normalizedTestArtists: [],
            matchingRule: "Core.ArtistAllowList.effectiveArtist.localizedCaseInsensitiveCompare",
            knownTrackCount: 1,
            fingerprint: "degenerate",
            reason: "unit-test"
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: degenerateScope,
            configuration: configuration()
        )

        #expect(production == .empty)
        #expect(await spy.eventLog().isEmpty)
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("an album target narrows the plan to that album within scope")
    func albumTargetNarrowsWithinScope() async throws {
        let targetTrack = track("HIT", artist: "Aphex Twin", album: "Drukqs")
        let otherAlbum = track("MISS", artist: "Aphex Twin", album: "Syro")
        let spy = FixPlanProducerSpy(
            tracks: [targetTrack, otherAlbum],
            outcomes: ["HIT": .changes([proposal(for: targetTrack)])]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: ["Aphex Twin"], knownTrackCount: 2),
            configuration: configuration(
                UpdateOptions(minConfidence: 60),
                albumTarget: FixPlanAlbumTarget(artist: "Aphex Twin", album: "Drukqs")
            )
        )

        #expect(production.proposalCount == 1)
        #expect(await spy.refreshInputs() == [["HIT", "MISS"]])
        let calls = await spy.determinationCalls()
        #expect(calls.map(\.trackID) == ["HIT"])
        // Full-scope artist context: the artist's OTHER album still
        // informs dominant-genre determination, so a targeted preview
        // proposes the same metadata a whole-scope one would.
        #expect(calls[0].artistTrackIDs == ["HIT", "MISS"])
    }

    @Test("an album target outside the scope plans nothing")
    func albumTargetOutsideScopeFailsClosed() async throws {
        // The album exists in the library, but its artist is outside the
        // Test Artists scope — intersection must be empty, never widened.
        let spy = FixPlanProducerSpy(tracks: [track("OUT", artist: "Boards of Canada", album: "Geogaddi")])

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: ["Aphex Twin"], knownTrackCount: 1),
            configuration: configuration(
                UpdateOptions(),
                albumTarget: FixPlanAlbumTarget(artist: "Boards of Canada", album: "Geogaddi")
            )
        )

        #expect(production == .empty)
        #expect(await spy.eventLog().isEmpty)
    }

    @Test("album target matching tolerates identity alias forms")
    func albumTargetMatchesAliasForms() async throws {
        // albumArtist-grouped and feature-suffixed tracks belong to the
        // same album identity the target names.
        let grouped = track("GRP", artist: "Someone Else", album: "Drukqs", albumArtist: "Aphex Twin")
        let featured = track("FEAT", artist: "Aphex Twin feat. Guest", album: "Drukqs")
        let spy = FixPlanProducerSpy(
            tracks: [grouped, featured],
            outcomes: [
                "GRP": .changes([proposal(for: grouped)]),
                "FEAT": .changes([proposal(for: featured)]),
            ]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 2),
            configuration: configuration(
                UpdateOptions(minConfidence: 60),
                albumTarget: FixPlanAlbumTarget(artist: "Aphex Twin", album: "Drukqs")
            )
        )

        #expect(production.proposalCount == 2)
        #expect(await spy.determinationCalls().map(\.trackID).sorted() == ["FEAT", "GRP"])
    }

    @Test("an album target never pulls a neighboring node's tracks")
    func albumTargetExcludesNeighborNodes() async throws {
        // Two DISTINCT browse nodes share the album title and even a raw
        // track artist: alias-expanded matching would merge them.
        let compilation = track("VA", artist: "Clutch", album: "Greatest Hits", albumArtist: "Various Artists")
        let own = track("CL", artist: "Clutch", album: "Greatest Hits", albumArtist: "Clutch")
        let spy = FixPlanProducerSpy(
            tracks: [compilation, own],
            outcomes: ["CL": .changes([proposal(for: own)])]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 2),
            configuration: configuration(
                UpdateOptions(minConfidence: 60),
                albumTarget: FixPlanAlbumTarget(artist: "Clutch", album: "Greatest Hits")
            )
        )

        #expect(production.proposalCount == 1)
        #expect(await spy.refreshInputs() == [["VA", "CL"]])
        #expect(await spy.determinationCalls().map(\.trackID) == ["CL"])
    }

    @Test("write identity refresh failure stops plan production")
    func propagatesRefreshFailure() async {
        let spy = FixPlanProducerSpy(tracks: [track("TRACK")], refreshFails: true)

        await #expect(throws: ProducerTestError.intentional) {
            _ = try await makeProducer(spy).producePlan(
                sourceRunID: sourceRunID,
                scope: scope(requestedTestArtists: [], knownTrackCount: 1),
                configuration: configuration()
            )
        }
        #expect(await spy.eventLog() == ["refresh"])
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("album context and artist groups are passed into determination")
    func passesAlbumAndArtistContext() async throws {
        let first = track("T1", artist: "Artist", album: "First")
        let second = track("T2", artist: "artist", album: "Second")
        let third = track("T3", artist: "Other", album: "First")
        let spy = FixPlanProducerSpy(
            tracks: [first, second, third],
            albumContextIDs: ["T1": ["T1", "T3"], "T2": ["T2"], "T3": ["T1", "T3"]]
        )
        let currentScope = scope(requestedTestArtists: [], knownTrackCount: 3)

        _ = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: currentScope,
            configuration: configuration(UpdateOptions(updateGenre: false, updateYear: true, minConfidence: 70))
        )

        let calls = await spy.determinationCalls()
        let callsByTrackID = Dictionary(uniqueKeysWithValues: calls.map { ($0.trackID, $0) })
        #expect(await spy.refreshInputs() == [["T1", "T2", "T3"]])
        #expect(await spy.refreshScopes() == [currentScope])
        #expect(Set(calls.map(\.trackID)) == ["T1", "T2", "T3"])
        #expect(callsByTrackID["T1"]?.albumTrackIDs == ["T1", "T3"])
        #expect(callsByTrackID["T1"]?.artistTrackIDs == ["T1", "T2"])
        #expect(callsByTrackID["T1"]?.updateGenre == false)
        #expect(callsByTrackID["T1"]?.updateYear == true)
        #expect(callsByTrackID["T1"]?.minConfidence == 70)
        #expect(callsByTrackID["T3"]?.artistTrackIDs == ["T3"])
    }

    @Test("feature credits share artist context during plan production")
    func featureCreditContext() async throws {
        let source = track("SOURCE", artist: "Artist", album: "Earlier")
        let target = track("TARGET", artist: "Artist feat. Guest", album: "Later")
        let spy = FixPlanProducerSpy(tracks: [source, target])

        _ = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 2),
            configuration: configuration(UpdateOptions(updateGenre: true, updateYear: false))
        )

        let calls = await spy.determinationCalls()
        #expect(calls.map(\.artistTrackIDs) == [["SOURCE", "TARGET"], ["SOURCE", "TARGET"]])
    }

    @Test("write eligibility errors skip tracks and continue")
    func skipsEligibilityErrors() async throws {
        let blocked = track("BLOCKED")
        let missingID = track("MISSING")
        let valid = track("VALID")
        let spy = FixPlanProducerSpy(
            tracks: [blocked, missingID, valid],
            outcomes: [
                "BLOCKED": .trackNotEditable,
                "MISSING": .missingAppleScriptID,
                "VALID": .changes([proposal(for: valid)]),
            ]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 3),
            configuration: configuration(UpdateOptions(minConfidence: 60))
        )

        let saved = try #require(await spy.savedPlans().first)
        #expect(production.proposalCount == 1)
        #expect(saved.plan.items.map(\.identity.readID) == ["VALID"])
        #expect(await spy.determinationCalls().map(\.trackID) == ["BLOCKED", "MISSING", "VALID"])
    }

    @Test("non eligibility errors propagate without saving")
    func propagatesOtherErrors() async {
        let failing = track("FAIL")
        let spy = FixPlanProducerSpy(
            tracks: [failing],
            outcomes: ["FAIL": .failure]
        )

        await #expect(throws: ProducerTestError.intentional) {
            _ = try await makeProducer(spy).producePlan(
                sourceRunID: sourceRunID,
                scope: scope(requestedTestArtists: [], knownTrackCount: 1),
                configuration: configuration()
            )
        }
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("year confidence excludes weak years without suppressing genre work")
    func scopesYearConfidence() async throws {
        let genre = track("GENRE")
        let weakYear = track("WEAK-YEAR")
        let strongYear = track("STRONG-YEAR")
        let spy = FixPlanProducerSpy(
            tracks: [genre, weakYear, strongYear],
            outcomes: [
                "GENRE": .changes([proposal(for: genre, confidence: 80)]),
                "WEAK-YEAR": .changes([proposal(for: weakYear, changeType: .yearUpdate, confidence: 80)]),
                "STRONG-YEAR": .changes([proposal(for: strongYear, changeType: .yearUpdate, confidence: 100)]),
            ]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 3),
            configuration: configuration(UpdateOptions(minConfidence: 100))
        )

        let saved = try #require(await spy.savedPlans().first)
        #expect(production.proposalCount == 2)
        #expect(saved.plan.items.map(\.identity.readID) == ["GENRE", "STRONG-YEAR"])
    }

    @Test("saved plan carries source scope configuration order and initial decision")
    func savesPlanAndInitialDecision() async throws {
        let first = track("A")
        let second = track("B")
        let currentScope = scope(requestedTestArtists: [], knownTrackCount: 2)
        let options = UpdateOptions(updateGenre: true, updateYear: false, minConfidence: 60)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: options,
            capturedAt: producedAt
        )
        let firstProposal = proposal(for: first, confidence: 95)
        let secondProposal = proposal(for: second, confidence: 96)
        let spy = FixPlanProducerSpy(
            tracks: [first, second],
            outcomes: [
                "A": .changes([firstProposal]),
                "B": .changes([secondProposal]),
            ]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: currentScope,
            configuration: configuration
        )

        let saved = try #require(await spy.savedPlans().first)
        #expect(production.planID == saved.plan.id)
        #expect(saved.plan.sourceRunID == sourceRunID)
        #expect(saved.plan.scope == currentScope)
        #expect(saved.plan.configuration == configuration)
        let admission = try #require(await spy.loadedAdmissions().first)
        #expect(saved.plan.admission == .certified(admission))
        #expect(saved.plan.items.map(\.id) == [firstProposal.id, secondProposal.id])
        #expect(saved.decision.planID == saved.plan.id)
        #expect(saved.decision.planRevision == .initial)
        #expect(saved.decision.revision == .initial)
        #expect(saved.decision.decidedAt == producedAt)
        #expect(saved.decision.itemDecisions.map(\.verdict) == [.accepted, .accepted])
        #expect(saved.decision.itemDecisions.map(\.itemID) == saved.plan.items.map(\.id))
    }

    @Test("planning admits bounded albums and preserves source order")
    func boundsAlbumPlanning() async throws {
        let first = track("A1", album: "First")
        let second = track("A2", album: "First")
        let third = track("B1", album: "Second")
        let fourth = track("C1", album: "Third")
        let concurrency = PlanConcurrencyProbe(trackDelays: [
            "A1": .milliseconds(80),
            "A2": .milliseconds(5),
            "B1": .milliseconds(50),
            "C1": .milliseconds(10),
        ])
        let spy = FixPlanProducerSpy(
            tracks: [first, third, second, fourth],
            outcomes: [
                "A1": .changes([proposal(for: first)]),
                "A2": .changes([proposal(for: second)]),
                "B1": .changes([proposal(for: third)]),
                "C1": .changes([proposal(for: fourth)]),
            ],
            concurrency: concurrency
        )
        var appConfiguration = AppConfiguration()
        appConfiguration.genreUpdate.concurrentLimit = 4
        appConfiguration.applescript.concurrency = 3
        appConfiguration.yearRetrieval.rateLimits.concurrentAlbums = 2
        appConfiguration.yearRetrieval.rateLimits.concurrentProviderCalls = 7

        _ = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 4),
            configuration: configuration(
                UpdateOptions(updateGenre: true, updateYear: true, minConfidence: 60),
                appConfiguration: appConfiguration
            )
        )

        let saved = try #require(await spy.savedPlans().first)
        #expect(await concurrency.maximumActiveCount() == 2)
        #expect(await concurrency.maximumAlbumActiveCount() == 1)
        #expect(saved.plan.items.map(\.identity.readID) == ["A1", "B1", "A2", "C1"])
    }

    @Test("empty proposals return empty production and do not save")
    func emptyDoesNotSave() async throws {
        let spy = FixPlanProducerSpy(
            tracks: [track("EMPTY")],
            outcomes: ["EMPTY": .changes([])]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 1),
            configuration: configuration()
        )

        #expect(production == .empty)
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("cancellation propagates")
    func propagatesCancellation() async {
        let cancelled = track("CANCEL")
        let spy = FixPlanProducerSpy(
            tracks: [cancelled],
            outcomes: ["CANCEL": .cancellation]
        )

        await #expect(throws: CancellationError.self) {
            _ = try await makeProducer(spy).producePlan(
                sourceRunID: sourceRunID,
                scope: scope(requestedTestArtists: [], knownTrackCount: 1),
                configuration: configuration()
            )
        }
    }

    private func makeProducer(_ spy: FixPlanProducerSpy) -> FixPlanProducer {
        FixPlanProducer(dependencies: FixPlanProducer.Dependencies(
            loadAdmission: { try await spy.loadAdmission(scope: $0, configuration: $1) },
            makeRuntime: { _, _ in
                await spy.recordRuntimeCreation()
                return FixPlanProducer.Runtime(
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
            now: { self.producedAt }
        ))
    }

    private func scope(requestedTestArtists: [String], knownTrackCount: Int?) -> ProcessingScopeSnapshot {
        certifiedScope(ProcessingScopeSnapshot.capture(
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "unit-test"
        ))
    }

    private func configuration(
        _ options: UpdateOptions = UpdateOptions(),
        appConfiguration: AppConfiguration = AppConfiguration(),
        albumTarget: FixPlanAlbumTarget? = nil
    ) -> FixPlanConfig {
        FixPlanConfig.capture(
            configuration: appConfiguration,
            options: options,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            albumTarget: albumTarget
        )
    }
}

actor FixPlanProducerSpy {
    private let tracks: [Track]
    private let admittedTracks: [Track]?
    private let albumContextIDs: [String: [String]]
    private let outcomes: [String: DeterminationOutcome]
    private let refreshFails: Bool
    private let concurrency: PlanConcurrencyProbe?
    private let admissionRejection: ProcessingAdmissionRejection?
    private var runtimeCreations = 0
    private var admissions: [ProcessingAdmission] = []
    private var refreshInputIDs: [[String]] = []
    private var capturedScopes: [ProcessingScopeSnapshot] = []
    private var albumContextInputIDs: [[String]] = []
    private var calls: [DeterminationCall] = []
    private var saved: [(plan: FixPlan, decision: FixPlanReviewDecision)] = []
    private var events: [String] = []

    init(
        tracks: [Track],
        admittedTracks: [Track]? = nil,
        albumContextIDs: [String: [String]] = [:],
        outcomes: [String: DeterminationOutcome] = [:],
        refreshFails: Bool = false,
        concurrency: PlanConcurrencyProbe? = nil,
        admissionRejection: ProcessingAdmissionRejection? = nil
    ) {
        self.tracks = tracks
        self.admittedTracks = admittedTracks
        self.albumContextIDs = albumContextIDs
        self.outcomes = outcomes
        self.refreshFails = refreshFails
        self.concurrency = concurrency
        self.admissionRejection = admissionRejection
    }

    func loadAdmission(
        scope: ProcessingScopeSnapshot,
        configuration _: FixPlanConfig
    ) throws -> ProcessingAdmissionDecision {
        if let admissionRejection {
            return .rejected(admissionRejection)
        }
        let admittedTracks = admittedTracks ?? Self.scopedTracks(tracks, scope: scope)
        let admission = processingAdmission(scope: scope)
        admissions.append(admission)
        return .admitted(admission, tracks: admittedTracks)
    }

    func recordRuntimeCreation() {
        runtimeCreations += 1
    }

    func runtimeCreationCount() -> Int {
        runtimeCreations
    }

    func loadedAdmissions() -> [ProcessingAdmission] {
        admissions
    }

    func loadTracks() -> [Track] {
        tracks
    }

    private static func scopedTracks(_ tracks: [Track], scope: ProcessingScopeSnapshot) -> [Track] {
        switch scope.source {
        case .fullLibrary:
            return tracks
        case .testArtists:
            guard !scope.normalizedTestArtists.isEmpty else { return [] }
            return ArtistAllowList.filter(tracks, allowedArtists: scope.normalizedTestArtists)
        }
    }

    func refreshWriteIdentity(for tracks: [Track], scope: ProcessingScopeSnapshot) throws {
        refreshInputIDs.append(tracks.map(\.id))
        capturedScopes.append(scope)
        events.append("refresh")
        if refreshFails {
            throw ProducerTestError.intentional
        }
    }

    func albumContextTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        events.append("context")
        albumContextInputIDs.append(tracks.map(\.id))
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: tracks.map { track in
            let contextIDs = albumContextIDs[track.id] ?? [track.id]
            let contextTracks = contextIDs.compactMap { tracksByID[$0] }
            return (track.id, contextTracks)
        })
    }

    func artistContextTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        let tracksByArtist = Dictionary(grouping: tracks) {
            normalizeForMatching(AlbumIdentity.groupingArtist(for: $0))
        }
        return Dictionary(uniqueKeysWithValues: tracks.map { track in
            let key = normalizeForMatching(AlbumIdentity.groupingArtist(for: track))
            return (track.id, tracksByArtist[key] ?? [])
        })
    }

    func determineTrackChanges(
        track: Track,
        albumTracks: [Track],
        artistTracks: [Track],
        options: UpdateOptions
    ) async throws -> [ProposedChange] {
        events.append("determine:\(track.id)")
        calls.append(DeterminationCall(
            trackID: track.id,
            albumTrackIDs: albumTracks.map(\.id),
            artistTrackIDs: artistTracks.map(\.id),
            updateGenre: options.updateGenre,
            updateYear: options.updateYear,
            minConfidence: options.minConfidence
        ))
        try await concurrency?.pause(
            trackID: track.id,
            albumKey: AlbumIdentity.key(for: track)
        )

        switch outcomes[track.id] ?? .changes([]) {
        case let .changes(changes):
            return changes
        case .trackNotEditable:
            throw UpdateCoordinatorError.trackNotEditable(trackID: track.id)
        case .missingAppleScriptID:
            throw UpdateCoordinatorError.missingAppleScriptID(trackID: track.id)
        case .failure:
            throw ProducerTestError.intentional
        case .cancellation:
            throw CancellationError()
        }
    }

    func savePlan(_ plan: FixPlan, decision: FixPlanReviewDecision) {
        saved.append((plan, decision))
    }

    func albumContextInputs() -> [[String]] {
        albumContextInputIDs
    }

    func refreshInputs() -> [[String]] {
        refreshInputIDs
    }

    func refreshScopes() -> [ProcessingScopeSnapshot] {
        capturedScopes
    }

    func eventLog() -> [String] {
        events
    }

    fileprivate func determinationCalls() -> [DeterminationCall] {
        calls
    }

    func savedPlans() -> [(plan: FixPlan, decision: FixPlanReviewDecision)] {
        saved
    }
}

actor PlanConcurrencyProbe {
    private let trackDelays: [String: Duration]
    private var activeCount = 0
    private var maximumActive = 0
    private var activeByAlbum: [String: Int] = [:]
    private var maximumAlbumActive = 0

    init(trackDelays: [String: Duration]) {
        self.trackDelays = trackDelays
    }

    func pause(trackID: String, albumKey: String) async throws {
        activeCount += 1
        maximumActive = max(maximumActive, activeCount)
        activeByAlbum[albumKey, default: 0] += 1
        maximumAlbumActive = max(maximumAlbumActive, activeByAlbum[albumKey, default: 0])
        defer {
            activeCount -= 1
            activeByAlbum[albumKey, default: 0] -= 1
        }

        try await Task.sleep(for: trackDelays[trackID] ?? .zero)
    }

    func maximumActiveCount() -> Int {
        maximumActive
    }

    func maximumAlbumActiveCount() -> Int {
        maximumAlbumActive
    }
}

private struct DeterminationCall: Equatable {
    let trackID: String
    let albumTrackIDs: [String]
    let artistTrackIDs: [String]
    let updateGenre: Bool
    let updateYear: Bool
    let minConfidence: Int
}

enum DeterminationOutcome {
    case changes([ProposedChange])
    case trackNotEditable
    case missingAppleScriptID
    case failure
    case cancellation
}

enum ProducerTestError: Error, Equatable {
    case intentional
}

func track(
    _ id: String,
    artist: String = "Artist",
    album: String = "Album",
    albumArtist: String? = nil
) -> Track {
    Track(id: id, name: "Track \(id)", artist: artist, album: album, albumArtist: albumArtist)
}

func proposal(
    for track: Track,
    changeType: ChangeType = .genreUpdate,
    confidence: Int = 80
) -> ProposedChange {
    ProposedChange(
        track: track,
        changeType: changeType,
        oldValue: "Rock",
        newValue: "Electronic",
        confidence: confidence,
        source: "unit-test"
    )
}
