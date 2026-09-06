import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — provider admission retries")
struct ProviderAdmissionRetryTests {
    @Test(
        "Retry chains retain one permit until their final attempt",
        arguments: ProviderLookup.allCases
    )
    func retryChainRetainsPermit(_ lookup: ProviderLookup) async throws {
        let probe = AdmissionRetryProbe()
        let orchestrator = retryOrchestrator(
            service: AdmissionRetryService(probe: probe),
            retryDelaySeconds: 0.2
        )
        let retrying = providerLookup(orchestrator, lookup: lookup, artist: "Retry")
        #expect(await probe.waitForRetryAttempt(1))
        let competitor = providerLookup(orchestrator, lookup: lookup, artist: "Competitor")
        #expect(await probe.waitForRetryAttempt(2))

        #expect(await probe.events == ["retry-1", "retry-2"])
        await probe.releaseRetry()
        try await awaitLookups([retrying, competitor])
        #expect(await probe.events == ["retry-1", "retry-2", "competitor"])
    }

    @Test("Hard timeout does not overlap a retry with unfinished transport")
    func hardTimeoutDoesNotOverlapRetry() async {
        let admission = ProviderAdmission(limit: 1)
        let requestPolicy = ProviderRequestPolicy(timeoutSeconds: 0.01)
        let requestStarted = EventCounter()
        let requestGate = AdmissionRetryGate()

        let request: @Sendable () async throws -> Void = {
            try await requestPolicy.performClientRequest(operation: .appleMusicCatalogSearch) {
                requestStarted.record()
                await requestGate.wait()
            }
        }
        let retry: @Sendable () async throws -> Void = {
            try await withRetry(maxAttempts: 2, initialDelay: .zero, operation: request)
        }
        let lookup = Task {
            try await admission.execute(operation: retry)
        }

        #expect(await requestStarted.wait(for: 1, timeout: .seconds(1)))
        do {
            _ = try await taskValue(lookup, timeout: .seconds(1))
            Issue.record("Expected the provider request deadline")
        } catch let error as ProviderRequestTimeout {
            #expect(error.operation == .appleMusicCatalogSearch)
            #expect(error.timeoutSeconds == 0.01)
            #expect(error.localizedDescription == "applemusic.catalog_search timed out after 0.01 seconds")
        } catch {
            Issue.record("Expected ProviderRequestTimeout, got \(error)")
        }
        #expect(await !requestStarted.wait(for: 2, timeout: .milliseconds(50)))
        await requestGate.open()
    }

    @Test("Completed transport timeout remains retryable")
    func completedTransportTimeoutRetries() async throws {
        let admission = ProviderAdmission(limit: 1)
        let requestPolicy = ProviderRequestPolicy(timeoutSeconds: 1)
        let attempts = TransportTimeoutAttempts()

        let request: @Sendable () async throws -> Int = {
            try await requestPolicy.performClientRequest(operation: .appleMusicCatalogSearch) {
                try await attempts.nextResult()
            }
        }
        let result = try await admission.execute {
            try await withRetry(maxAttempts: 2, initialDelay: .zero, operation: request)
        }

        #expect(result == 2)
        #expect(await attempts.count == 2)
    }

    private func retryOrchestrator(
        service: any ExternalAPIService,
        retryDelaySeconds: Double
    ) -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: service,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.maxAPIRetries = 1
            $0.apiRetryDelaySeconds = retryDelaySeconds
        }
    }

    private func providerLookup(
        _ orchestrator: APIOrchestrator,
        lookup: ProviderLookup,
        artist: String
    ) -> Task<Void, any Error> {
        Task {
            switch lookup {
            case .candidates:
                _ = await orchestrator.getReleaseCandidates(
                    artist: artist,
                    album: "Album",
                    currentLibraryYear: nil,
                    earliestTrackAddedYear: nil
                )
            case .albumYear:
                _ = await orchestrator.getAlbumYear(
                    artist: artist,
                    album: "Album",
                    currentLibraryYear: nil,
                    earliestTrackAddedYear: nil
                )
            }
        }
    }

    private func awaitLookups(_ tasks: [Task<Void, any Error>]) async throws {
        for task in tasks {
            _ = try await taskValue(task, timeout: .seconds(2))
        }
    }
}

private actor TransportTimeoutAttempts {
    private(set) var count = 0

    func nextResult() throws -> Int {
        count += 1
        if count == 1 {
            throw URLError(.timedOut)
        }
        return count
    }
}

private actor AdmissionRetryGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
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

enum ProviderLookup: CaseIterable, Sendable {
    case candidates
    case albumYear
}

private actor AdmissionRetryProbe {
    private(set) var events: [String] = []
    private var retryAttempts = 0
    private var retryContinuation: CheckedContinuation<Void, Never>?
    private var waitContinuation: CheckedContinuation<Bool, Never>?
    private var waitExpectedCount = 0
    private var waitTimer: Task<Void, Never>?

    func attempt(artist: String) async throws {
        guard artist == "Retry" else {
            events.append("competitor")
            return
        }

        retryAttempts += 1
        events.append("retry-\(retryAttempts)")
        resumeWaiterIfReady()
        if retryAttempts == 1 {
            throw URLError(.timedOut)
        }
        await withCheckedContinuation { continuation in
            retryContinuation = continuation
        }
    }

    func waitForRetryAttempt(_ expectedCount: Int) async -> Bool {
        guard retryAttempts < expectedCount else { return true }

        return await withCheckedContinuation { continuation in
            waitExpectedCount = expectedCount
            waitContinuation = continuation
            waitTimer = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                timeoutWaiter(expectedCount: expectedCount)
            }
        }
    }

    func releaseRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }

    private func resumeWaiterIfReady() {
        guard retryAttempts >= waitExpectedCount, let continuation = waitContinuation else { return }
        waitTimer?.cancel()
        waitTimer = nil
        waitContinuation = nil
        continuation.resume(returning: true)
    }

    private func timeoutWaiter(expectedCount: Int) {
        guard waitExpectedCount == expectedCount, let continuation = waitContinuation else { return }
        waitTimer = nil
        waitContinuation = nil
        continuation.resume(returning: false)
    }
}

private struct AdmissionRetryService: ExternalAPIService {
    let probe: AdmissionRetryProbe

    func getAlbumYear(
        artist: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await probe.attempt(artist: artist)
        return YearResult(year: 1991, confidence: 90, yearScores: [1991: 90])
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await probe.attempt(artist: artist)
        return [
            ReleaseCandidate(
                artist: artist,
                album: album,
                year: 1991,
                source: .musicBrainz
            ),
        ]
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
