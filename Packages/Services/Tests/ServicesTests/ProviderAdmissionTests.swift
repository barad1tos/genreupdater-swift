import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — global provider admission")
struct ProviderAdmissionTests {
    @Test("Default provider admission uses the centralized runtime limit")
    func usesCentralizedDefaultLimit() {
        #expect(
            APIOrchestratorConfiguration().maxConcurrentSourceCalls
                == APIRateLimits.defaultConcurrentProviderCalls
        )
    }

    @Test("Candidate and direct-year lookups fan out to all providers concurrently")
    func runsAllProviders() async {
        let grantGate = ProviderGrantGate()
        let service = MockAPIService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: service,
            appleMusic: service
        ) {
            $0.maxConcurrentSourceCalls = 6
            $0.providerAdmissionHooks = (
                didEnqueue: nil,
                afterGrant: { await grantGate.arriveAndWait() }
            )
        }

        async let candidates: Void = {
            _ = await orchestrator.getReleaseCandidates(
                artist: "Candidate Artist",
                album: "Candidate Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }()
        async let year: Void = {
            _ = await orchestrator.getAlbumYear(
                artist: "Year Artist",
                album: "Year Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }()

        #expect(await grantGate.waitForArrivals(6))
        await grantGate.open()
        _ = await (candidates, year)
    }

    @Test("Candidate and direct-year lookups share one concurrency budget")
    func sharesConcurrencyBudget() async {
        let enqueueProbe = ProviderEnqueueProbe()
        let grantGate = ProviderGrantGate()
        let service = MockAPIService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: service,
            appleMusic: service
        ) {
            $0.maxConcurrentSourceCalls = 2
            $0.providerAdmissionHooks = (
                didEnqueue: { enqueueProbe.record() },
                afterGrant: { await grantGate.arriveAndWait() }
            )
        }

        async let candidates: Void = {
            _ = await orchestrator.getReleaseCandidates(
                artist: "Candidate Artist",
                album: "Candidate Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }()
        async let year: Void = {
            _ = await orchestrator.getAlbumYear(
                artist: "Year Artist",
                album: "Year Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }()

        #expect(await grantGate.waitForArrivals(2))
        #expect(await enqueueProbe.waitForCount(4))
        await grantGate.open()
        _ = await (candidates, year)
    }

    @Test(
        "Workflow cancellation stops after each nonthrowing provider boundary",
        arguments: CancellationBoundary.allCases
    )
    func workflowCancellationPropagates(_ boundary: CancellationBoundary) async {
        let probe = CancellationBoundaryProbe(boundary: boundary)
        let service = CancellationProviderService(probe: probe)
        let pendingVerification = PendingRecorder()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
        }
        let coordinator = makeCoordinator(
            apiOrchestrator: orchestrator,
            pendingVerificationService: pendingVerification
        )
        let track = Track(
            id: "cancelled-year",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: nil,
            trackStatus: nil
        )
        let lookup: Task<ProposedChange?, any Error> = Task {
            try await coordinator.determineYearChange(
                track: track,
                albumTracks: [track],
                forceYearLookup: true
            )
        }
        #expect(await probe.waitUntilEntered())

        lookup.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(lookup, timeout: .milliseconds(200))
        }
        #expect(await probe.calls == boundary.expectedCalls)
        #expect(await pendingVerification.markCount() == 0)
        #expect(await pendingVerification.removalCount() == 0)
    }

    @Test("Cancelled pending verification does not update retry state")
    func pendingVerificationCancellationPropagates() async {
        let probe = CancellationBoundaryProbe(boundary: .albumYear)
        let pendingVerification = PendingRecorder()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: CancellationProviderService(probe: probe),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
        }
        let coordinator = makeCoordinator(
            apiOrchestrator: orchestrator,
            pendingVerificationService: pendingVerification
        )
        let track = Track(
            id: "pending-cancellation",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: nil,
            trackStatus: nil
        )
        let entry = PendingAlbumEntry(
            id: "pending-cancellation",
            artist: "Artist",
            album: "Album",
            reason: "no_year_found"
        )
        let verification = Task {
            try await coordinator.verifyPendingAlbum(entry, albumTracks: [track])
        }
        #expect(await probe.waitUntilEntered())

        verification.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(verification, timeout: .milliseconds(200))
        }
        #expect(await pendingVerification.markCount() == 0)
        #expect(await pendingVerification.removalCount() == 0)
    }

    private func makeCoordinator(
        apiOrchestrator: APIOrchestrator,
        pendingVerificationService: (any PendingVerificationService)? = nil
    ) -> UpdateCoordinator {
        let bridge = MusicAppTestAccess()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAdmissionTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: apiOrchestrator,
                writer: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: MockCacheService()
                ),
                undoCoordinator: UndoCoordinator(
                    musicApp: bridge,
                    directory: directory
                ),
                idMapper: nil,
                librarySnapshotService: nil,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}

enum CancellationBoundary: CaseIterable, Sendable {
    case candidates
    case albumYear
    case activityPeriod
    case region

    var expectedCalls: [Self] {
        switch self {
        case .candidates: [.candidates]
        case .albumYear: [.candidates, .albumYear]
        case .activityPeriod: [.candidates, .activityPeriod]
        case .region: [.candidates, .activityPeriod, .region]
        }
    }
}

private enum ProviderAdmissionTestTiming {
    static let probeTimeout = Duration.seconds(10)
}

private final class ProviderEnqueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock {
            count += 1
        }
    }

    func waitForCount(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: ProviderAdmissionTestTiming.probeTimeout)
        while currentCount < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return currentCount >= expectedCount
    }

    private var currentCount: Int {
        lock.withLock { count }
    }
}

private actor ProviderGrantGate {
    private var arrivals = 0
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForArrivals(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: ProviderAdmissionTestTiming.probeTimeout)
        while arrivals < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return arrivals >= expectedCount
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor CancellationBoundaryProbe {
    let boundary: CancellationBoundary
    private(set) var calls: [CancellationBoundary] = []
    private var hasEnteredBoundary = false
    private var entryContinuation: CheckedContinuation<Bool, Never>?
    private var entryTimer: Task<Void, Never>?

    init(boundary: CancellationBoundary) {
        self.boundary = boundary
    }

    func record(_ call: CancellationBoundary) async throws {
        calls.append(call)
        guard call == boundary else { return }
        hasEnteredBoundary = true
        entryTimer?.cancel()
        entryTimer = nil
        entryContinuation?.resume(returning: true)
        entryContinuation = nil
        try await Task.sleep(for: .seconds(30))
    }

    func waitUntilEntered() async -> Bool {
        guard !hasEnteredBoundary else { return true }

        return await withCheckedContinuation { continuation in
            entryContinuation = continuation
            entryTimer = Task {
                try? await Task.sleep(for: ProviderAdmissionTestTiming.probeTimeout)
                guard !Task.isCancelled else { return }
                timeoutEntryWait()
            }
        }
    }

    private func timeoutEntryWait() {
        entryTimer = nil
        entryContinuation?.resume(returning: false)
        entryContinuation = nil
    }
}

private struct CancellationProviderService: ExternalAPIService {
    let probe: CancellationBoundaryProbe

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await probe.record(.albumYear)
        return YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await probe.record(.candidates)
        let boundary = probe.boundary
        guard boundary == .activityPeriod || boundary == .region else { return [] }
        return [
            ReleaseCandidate(
                artist: "Artist",
                album: "Album",
                year: 2000,
                source: .musicBrainz
            ),
        ]
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        try await probe.record(.activityPeriod)
        return (nil, nil)
    }

    func getArtistRegion(artist _: String) async throws -> String? {
        try await probe.record(.region)
        return nil
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
