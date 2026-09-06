import Foundation
import Testing
@testable import Core
@testable import Services

#if DEBUG
@Suite("APIOrchestrator — provider admission cache")
struct ProviderAdmissionCacheTests {
    @Test("Candidate cache hits bypass a busy permit")
    func candidateHitSkipsAdmission() async {
        let fixture = makeFixture()
        let seeded = await fixture.orchestrator.getReleaseCandidates(
            artist: "Cached Candidate",
            album: "Cached Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(seeded.map(\.year) == [1990])

        let candidates = await cachedWhileBusy(fixture) {
            await fixture.orchestrator.getReleaseCandidates(
                artist: "Cached Candidate",
                album: "Cached Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        #expect(candidates.map(\.year) == [1990])
    }

    @Test("Direct-year cache hits bypass a busy permit")
    func yearHitSkipsAdmission() async {
        let fixture = makeFixture()
        let seeded = await fixture.orchestrator.getAlbumYear(
            artist: "Cached Year",
            album: "Cached Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(seeded.year == 2000)

        let year = await cachedWhileBusy(fixture) {
            await fixture.orchestrator.getAlbumYear(
                artist: "Cached Year",
                album: "Cached Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        #expect(year.year == 2000)
    }

    private func makeFixture() -> AdmissionCacheFixture {
        let cache = MockCacheService()
        let probe = AdmissionCacheProbe()
        let service = AdmissionCacheService(probe: probe)
        let hooks: ProviderAdmission.TestHooks = (
            didEnqueue: {
                Task { await probe.recordEnqueue() }
            },
            afterGrant: {
                await probe.blockArmedGrant()
            }
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.providerAdmissionHooks = hooks
        }
        return AdmissionCacheFixture(orchestrator: orchestrator, probe: probe)
    }

    private func cachedWhileBusy<Result: Sendable>(
        _ fixture: AdmissionCacheFixture,
        operation: @escaping @Sendable () async -> Result
    ) async -> Result {
        await fixture.probe.armGrantBlock()
        let blocker = Task {
            await fixture.orchestrator.getAlbumYear(
                artist: "Blocker",
                album: "Blocked Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        await fixture.probe.waitForGrant()
        let blockedCalls = await fixture.probe.callCounts
        let enqueueCount = await fixture.probe.enqueueCount
        let cached = Task {
            await operation()
        }

        let result = await cached.value
        #expect(await fixture.probe.enqueueCount == enqueueCount)
        #expect(await fixture.probe.callCounts == blockedCalls)
        await fixture.probe.releaseGrantBlock()
        _ = await blocker.value
        return result
    }
}

private struct AdmissionCacheFixture: Sendable {
    let orchestrator: APIOrchestrator
    let probe: AdmissionCacheProbe
}

private actor AdmissionCacheProbe {
    private var candidateCalls = 0
    private var yearCalls = 0
    private var enqueuedCalls = 0
    private var isGrantArmed = false
    private var isGrantBlocked = false
    private var grantBlockContinuation: CheckedContinuation<Void, Never>?
    private var grantEntryContinuations: [CheckedContinuation<Void, Never>] = []

    var callCounts: (candidate: Int, year: Int) {
        (candidate: candidateCalls, year: yearCalls)
    }

    var enqueueCount: Int {
        enqueuedCalls
    }

    func candidates(artist: String, album: String) -> [ReleaseCandidate] {
        candidateCalls += 1
        return [
            ReleaseCandidate(
                artist: artist,
                album: album,
                year: 1990,
                source: .musicBrainz
            ),
        ]
    }

    func year(artist _: String) async -> YearResult {
        yearCalls += 1
        return YearResult(year: 2000, confidence: 90, yearScores: [2000: 90])
    }

    func armGrantBlock() {
        isGrantArmed = true
    }

    func blockArmedGrant() async {
        guard isGrantArmed else { return }
        isGrantArmed = false
        isGrantBlocked = true
        let entryContinuations = grantEntryContinuations
        grantEntryContinuations.removeAll()
        entryContinuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            grantBlockContinuation = continuation
        }
        isGrantBlocked = false
    }

    func waitForGrant() async {
        guard !isGrantBlocked else { return }
        await withCheckedContinuation { continuation in
            grantEntryContinuations.append(continuation)
        }
    }

    func recordEnqueue() {
        enqueuedCalls += 1
        releaseGrantBlock()
    }

    func releaseGrantBlock() {
        grantBlockContinuation?.resume()
        grantBlockContinuation = nil
    }
}

private struct AdmissionCacheService: ExternalAPIService {
    let probe: AdmissionCacheProbe

    func getAlbumYear(
        artist: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await probe.year(artist: artist)
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await probe.candidates(artist: artist, album: album)
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
#endif
