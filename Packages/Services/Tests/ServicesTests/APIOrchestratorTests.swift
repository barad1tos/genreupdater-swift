import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — parallel multi-source year aggregation")
struct APIOrchestratorTests {
    private let startOf2026 = Date(timeIntervalSince1970: 1_767_225_600)

    @Test("Aggregates results from multiple sources with combined confidence > 80")
    func aggregateResultsFromMultipleSources() async {
        let musicBrainz = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 80,
                yearScores: [1984: 80]
            )
        )
        let discogs = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 75,
                yearScores: [1984: 75]
            )
        )
        let appleMusic = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 70,
                yearScores: [1984: 70]
            )
        )

        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1984)
        #expect(result.confidence > 80)
        #expect(result.isDefinitive == true)
    }

    @Test("Continues when one source fails, returns surviving source result")
    func continuesWhenOneSourceFails() async {
        let musicBrainz = MockAPIService(
            yearResult: YearResult(
                year: 1986,
                confidence: 80,
                yearScores: [1986: 80]
            )
        )
        let discogs = MockAPIService(shouldThrow: true)
        let appleMusic = MockAPIService(shouldThrow: true)

        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Metallica",
            album: "Master of Puppets",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1986)
    }

    @Test("Returns empty result when all sources fail")
    func returnsEmptyWhenAllSourcesFail() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(shouldThrow: true),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Nobody",
            album: "Nothing",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
        #expect(result.confidence == 0)
    }

    @Test("Limits concurrent source calls")
    func limitsConcurrentSourceCalls() async {
        let probe = APIConcurrencyProbe()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: RecordingAPIService(
                probe: probe,
                yearResult: YearResult(year: 2000, confidence: 60, yearScores: [2000: 60]),
                delay: .milliseconds(50)
            ),
            discogs: RecordingAPIService(
                probe: probe,
                yearResult: YearResult(year: 2001, confidence: 60, yearScores: [2001: 60]),
                delay: .milliseconds(50)
            ),
            appleMusic: RecordingAPIService(
                probe: probe,
                yearResult: YearResult(year: 2002, confidence: 60, yearScores: [2002: 60]),
                delay: .milliseconds(50)
            )
        ) {
            $0.maxConcurrentSourceCalls = 1
        }

        _ = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let maxActive = await probe.maxActive()
        #expect(maxActive == 1)
    }

    @Test("Artist metadata lookups share the source-call limit")
    func limitsArtistMetadataCalls() async {
        let probe = APIConcurrencyProbe()
        let musicBrainz = RecordingAPIService(
            probe: probe,
            yearResult: YearResult(),
            delay: .milliseconds(50)
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        ) {
            $0.maxConcurrentSourceCalls = 1
        }

        async let activityPeriod = orchestrator.getArtistActivityPeriod(normalizedArtist: "Test")
        async let region = orchestrator.getArtistRegion(normalizedArtist: "Test")
        _ = await (activityPeriod, region)

        #expect(await probe.maxActive() == 1)
    }

    @Test("Cancelled source calls leave the concurrency probe balanced")
    func cancelledSourceCallBalancesProbe() async {
        let probe = APIConcurrencyProbe()
        let service = RecordingAPIService(
            probe: probe,
            yearResult: YearResult(year: 2000, confidence: 60, yearScores: [2000: 60]),
            delay: .seconds(10)
        )
        let call = Task {
            try await service.getAlbumYear(
                artist: "Test",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        while await probe.active() == 0 {
            await Task.yield()
        }

        call.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await call.value
        }
        #expect(await probe.active() == 0)
    }

    @Test("Preferred API breaks tied source scores")
    func preferredAPIBreaksTiedSourceScores() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(year: 2000, confidence: 60, yearScores: [2000: 60])
            ),
            discogs: MockAPIService(
                yearResult: YearResult(year: 2001, confidence: 60, yearScores: [2001: 60])
            ),
            appleMusic: MockAPIService()
        ) {
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(preferredAPI: .discogs)
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 2001)
        #expect(result.confidence == 60)
    }

    @Test("Script API priority overrides preferred API")
    func scriptAPIPriorityOverridesPreferredAPI() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(year: 2000, confidence: 60, yearScores: [2000: 60])
            ),
            discogs: MockAPIService(
                yearResult: YearResult(year: 2001, confidence: 60, yearScores: [2001: 60])
            ),
            appleMusic: MockAPIService()
        ) {
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(
                preferredAPI: .musicbrainz,
                scriptPriorities: [
                    "cyrillic": ScriptAPIPriority(primary: ["discogs"], fallback: ["musicbrainz"]),
                ]
            )
        }

        let result = await orchestrator.getAlbumYear(
            artist: "МУР",
            album: "Альбом",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 2001)
        #expect(result.confidence == 60)
    }

    @Test("Best year selected by highest combined score across sources")
    func bestYearSelectedByHighestCombinedScore() async {
        // MB returns 1984 (80), DC returns 1985 (60), AM returns 1984 (70)
        // Combined: 1984 = 150, 1985 = 60 => 1984 wins
        let musicBrainz = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 80,
                yearScores: [1984: 80]
            )
        )
        let discogs = MockAPIService(
            yearResult: YearResult(
                year: 1985,
                confidence: 60,
                yearScores: [1985: 60]
            )
        )
        let appleMusic = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 70,
                yearScores: [1984: 70]
            )
        )

        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        // 1984 has combined score 150 (80+70) vs 1985 at 60
        #expect(result.year == 1984)
        // Confidence capped at 100
        #expect(result.confidence == 100)
        #expect(result.isDefinitive == true)
        // yearScores preserves both years
        #expect(result.yearScores[1984] == 150)
        #expect(result.yearScores[1985] == 60)
    }

    @Test("A future-only source result is excluded from aggregation")
    func futureYearExcluded() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(year: 2027, confidence: 100, yearScores: [2027: 100])
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        ) {
            $0.dateProvider = { startOf2026 }
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
        #expect(result.confidence == 0)
        #expect(result.yearScores.isEmpty)
    }

    @Test("A valid year survives a stronger future source result")
    func validYearBeatsFuture() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(year: 2027, confidence: 100, yearScores: [2027: 100])
            ),
            discogs: MockAPIService(
                yearResult: YearResult(year: 2020, confidence: 70, yearScores: [2020: 70])
            ),
            appleMusic: MockAPIService()
        ) {
            $0.dateProvider = { startOf2026 }
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 2020)
        #expect(result.confidence == 70)
        #expect(result.yearScores == [2020: 70])
    }

    @Test("Configured minimum excludes older provider results")
    func minimumFiltersProviderYear() async {
        var applicationConfiguration = AppConfiguration()
        applicationConfiguration.yearRetrieval.logic.minValidYear = 1950
        var configuration = APIOrchestratorConfiguration(configuration: applicationConfiguration)
        configuration.dateProvider = { startOf2026 }
        let orchestrator = APIOrchestrator(
            services: APIOrchestratorServices(
                musicBrainz: MockAPIService(
                    yearResult: YearResult(year: 1949, confidence: 100, yearScores: [1949: 100])
                ),
                discogs: MockAPIService(
                    yearResult: YearResult(year: 1950, confidence: 70, yearScores: [1950: 70])
                ),
                appleMusic: MockAPIService()
            ),
            configuration: configuration
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1950)
        #expect(result.confidence == 70)
        #expect(result.yearScores == [1950: 70])
    }

    @Test("Configured minimum also applies to the current library fallback")
    func minimumFiltersLibraryYear() async {
        var applicationConfiguration = AppConfiguration()
        applicationConfiguration.yearRetrieval.logic.minValidYear = 1950
        var configuration = APIOrchestratorConfiguration(configuration: applicationConfiguration)
        configuration.dateProvider = { startOf2026 }
        let orchestrator = APIOrchestrator(
            services: APIOrchestratorServices(
                musicBrainz: MockAPIService(shouldThrow: true),
                discogs: MockAPIService(shouldThrow: true),
                appleMusic: MockAPIService(shouldThrow: true)
            ),
            configuration: configuration
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: 1949,
            earliestTrackAddedYear: 2020
        )

        #expect(result.year == nil)
        #expect(result.confidence == 0)
        #expect(result.yearScores.isEmpty)
    }

    @Test("Cache hit skips matching source request")
    func cacheHitSkipsMatchingSourceRequest() async {
        let cache = MockCacheService()
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Iron Maiden",
            album: "Powerslave",
            year: 1984,
            source: "musicbrainz",
            timestamp: .now,
            ttl: 3600,
            metadata: [
                "confidence": "88",
                "rawScore": "88",
                "isDefinitive": "false",
            ]
        ))

        let callCounter = APICallCounter()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: CountingAPIService(
                callCounter: callCounter,
                yearResult: YearResult(year: 1999, confidence: 99, yearScores: [1999: 99])
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1984)
        #expect(await callCounter.count() == 0)
    }

    @Test("Successful source result is written to cache")
    func cachesSuccessfulResult() async {
        let cache = MockCacheService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(year: 1986, confidence: 77, yearScores: [1986: 77])
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        ) {
            $0.candidateResultTTL = 86400
        }

        _ = await orchestrator.getAlbumYear(
            artist: "Metallica",
            album: "Master of Puppets",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let cached = await cache.getCachedAPIResult(
            artist: "Metallica",
            album: "Master of Puppets",
            source: "musicbrainz"
        )
        #expect(cached?.year == 1986)
        #expect(cached?.ttl == 86400)
        #expect(cached?.metadata["confidence"] == "77")
    }

    @Test("Album year search strips API-only album decoration")
    func albumYearSearchStripsAPIOnlyAlbumDecoration() async {
        let recorder = APIQueryRecorder()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: RecordingYearQueryService(
                recorder: recorder,
                yearResult: YearResult(year: 2022, confidence: 80, yearScores: [2022: 80])
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        )

        _ = await orchestrator.getAlbumYear(
            artist: "Karma & Effect",
            album: "\"Survival of the Sickest\" (Bonus Track Version)",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let query = await recorder.firstQuery()
        #expect(query?.artist == "Karma and Effect")
        #expect(query?.album == "Survival of the Sickest")
    }
}

@Suite("APIOrchestrator — API retry configuration")
struct APIOrchestratorRetryTests {
    @Test("Retries transient API source failures when configured")
    func retriesTransientAPISourceFailuresWhenConfigured() async {
        let callCounter = APICallCounter()
        let musicBrainz = FlakyAPIService(
            callCounter: callCounter,
            yearResult: YearResult(
                year: 1991,
                confidence: 90,
                yearScores: [1991: 90]
            )
        )
        let discogs = MockAPIService(shouldThrow: true)
        let appleMusic = MockAPIService(shouldThrow: true)

        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        ) {
            $0.maxAPIRetries = 1
            $0.apiRetryDelaySeconds = 0
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Nirvana",
            album: "Nevermind",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1991)
        #expect(await callCounter.count() == 2)
    }
}

private actor APIConcurrencyProbe {
    private var activeCount = 0
    private var maxActiveCount = 0

    func wait(for delay: Duration) async throws {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
        defer { activeCount -= 1 }
        try await Task.sleep(for: delay)
    }

    func maxActive() -> Int {
        maxActiveCount
    }

    func active() -> Int {
        activeCount
    }
}

actor APICallCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func incrementAndCount() -> Int {
        value += 1
        return value
    }

    func count() -> Int {
        value
    }
}

private actor APIQueryRecorder {
    struct Query: Equatable {
        let artist: String
        let album: String
    }

    private var queries: [Query] = []

    func record(artist: String, album: String) {
        queries.append(Query(artist: artist, album: album))
    }

    func firstQuery() -> Query? {
        queries.first
    }
}

private struct RecordingYearQueryService: ExternalAPIService {
    let recorder: APIQueryRecorder
    let yearResult: YearResult

    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await recorder.record(artist: artist, album: album)
        return yearResult
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

struct CountingAPIService: ExternalAPIService {
    let callCounter: APICallCounter
    let yearResult: YearResult

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await callCounter.increment()
        return yearResult
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

struct FlakyAPIService: ExternalAPIService {
    let callCounter: APICallCounter
    let yearResult: YearResult

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        let attempt = await callCounter.incrementAndCount()
        if attempt == 1 {
            throw MusicBrainzError.serviceUnavailable
        }
        return yearResult
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

private struct RecordingAPIService: ExternalAPIService {
    let probe: APIConcurrencyProbe
    let yearResult: YearResult
    let delay: Duration

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await probe.wait(for: delay)
        return yearResult
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        try await probe.wait(for: delay)
        return (nil, nil)
    }

    func getArtistRegion(artist _: String) async throws -> String? {
        try await probe.wait(for: delay)
        return nil
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
