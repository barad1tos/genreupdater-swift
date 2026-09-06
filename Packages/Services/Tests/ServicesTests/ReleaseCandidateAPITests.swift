import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator - release candidate collection")
struct ReleaseCandidateAPITests {
    @Test("Common legacy initializer labels remain available")
    func commonLegacyInitializerLabelsRemainAvailable() async {
        let orchestrator = APIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: MockCacheService(),
            disabledSources: [.musicBrainz, .discogs, .itunes]
        )

        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.isEmpty)
    }

    @Test("collects release candidates in configured source order")
    func collectsReleaseCandidatesInSourceOrder() async {
        let musicBrainz = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 1998,
                source: .musicBrainz
            ),
        ])
        let discogs = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 1999,
                source: .discogs
            ),
        ])
        let appleMusic = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 2001,
                source: .itunes
            ),
        ])

        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        ) {
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(
                preferredAPI: .discogs,
                scriptPriorities: [:]
            )
        }

        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.source) == [.discogs, .musicBrainz, .itunes])
        #expect(candidates.map(\.year) == [1999, 1998, 2001])
    }

    @Test("Release candidate cache skips repeated source requests")
    func releaseCandidateCacheSkipsRepeatedSourceRequests() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let expectedCandidate = ReleaseCandidate(
            artist: "In Flames",
            album: "Battles",
            year: 2016,
            source: .musicBrainz
        )
        let musicBrainz = CountingReleaseCandidateService(
            callCounter: callCounter,
            releaseCandidates: [expectedCandidate]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: " in flames ",
            album: " battles ",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult == [expectedCandidate])
        #expect(secondResult == [expectedCandidate])
        #expect(await callCounter.count() == 1)
    }

    @Test("Discogs candidate cache changes when reissue rules change")
    func discogsRuleCache() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let cachedCandidate = ReleaseCandidate(
            artist: "Björk",
            album: "Homogenic Anniversary",
            year: 1997,
            source: .discogs,
            isReissue: true
        )
        let currentCandidate = ReleaseCandidate(
            artist: "Björk",
            album: "Homogenic Anniversary",
            year: 1997,
            source: .discogs,
            isReissue: false
        )
        let firstOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: CountingReleaseCandidateService(
                callCounter: callCounter,
                releaseCandidates: [cachedCandidate]
            ),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) { $0.discogsReissueKeywords = ["anniversary"] }
        let secondOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: CountingReleaseCandidateService(
                callCounter: callCounter,
                releaseCandidates: [currentCandidate]
            ),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) { $0.discogsReissueKeywords = [] }

        let firstResult = await firstOrchestrator.getReleaseCandidates(
            artist: "Björk",
            album: "Homogenic Anniversary",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await secondOrchestrator.getReleaseCandidates(
            artist: "Björk",
            album: "Homogenic Anniversary",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult == [cachedCandidate])
        #expect(secondResult == [currentCandidate])
        #expect(await callCounter.count() == 2)
    }

    @Test("Discogs candidate cache changes with each acquisition setting")
    func discogsAcquisitionCache() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let candidates = [1997, 2007, 2017].map {
            ReleaseCandidate(
                artist: "Björk",
                album: "Homogenic",
                year: $0,
                source: .discogs
            )
        }
        let firstOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: CountingReleaseCandidateService(
                callCounter: callCounter,
                releaseCandidates: [candidates[0]]
            ),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) {
            $0.discogsSearchConfiguration.resultLimit = 10
            $0.discogsSearchConfiguration.detailLookupLimit = 1
        }
        let resultLimitOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: CountingReleaseCandidateService(
                callCounter: callCounter,
                releaseCandidates: [candidates[1]]
            ),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) {
            $0.discogsSearchConfiguration.resultLimit = 20
            $0.discogsSearchConfiguration.detailLookupLimit = 1
        }
        let detailLimitOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: CountingReleaseCandidateService(
                callCounter: callCounter,
                releaseCandidates: [candidates[2]]
            ),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) {
            $0.discogsSearchConfiguration.resultLimit = 20
            $0.discogsSearchConfiguration.detailLookupLimit = 2
        }

        let first = await releaseCandidates(from: firstOrchestrator)
        let resultLimit = await releaseCandidates(from: resultLimitOrchestrator)
        let detailLimit = await releaseCandidates(from: detailLimitOrchestrator)

        #expect(first == [candidates[0]])
        #expect(resultLimit == [candidates[1]])
        #expect(detailLimit == [candidates[2]])
        #expect(await callCounter.count() == 3)
    }

    @Test("Discogs candidate cache normalizes equivalent reissue rules")
    func discogsEquivalentRuleCache() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let expectedCandidate = ReleaseCandidate(
            artist: "Björk",
            album: "Homogenic Anniversary",
            year: 1997,
            source: .discogs,
            isReissue: true
        )
        let firstOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: CountingReleaseCandidateService(
                callCounter: callCounter,
                releaseCandidates: [expectedCandidate]
            ),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) { $0.discogsReissueKeywords = [" anniversary ", "", "ANNIVERSARY"] }
        let secondOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: CountingReleaseCandidateService(
                callCounter: callCounter,
                releaseCandidates: []
            ),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) { $0.discogsReissueKeywords = ["anniversary"] }

        let firstResult = await firstOrchestrator.getReleaseCandidates(
            artist: "Björk",
            album: "Homogenic Anniversary",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await secondOrchestrator.getReleaseCandidates(
            artist: "Björk",
            album: "Homogenic Anniversary",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult == [expectedCandidate])
        #expect(secondResult == [expectedCandidate])
        #expect(await callCounter.count() == 1)
    }

    @Test("iTunes cache and classification follow the UTC scoring year")
    func iTunesCacheUsesUTCYear() async throws {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let candidate = ReleaseCandidate(
            artist: "Parity Artist",
            album: "Parity Album",
            year: 2025,
            source: .itunes,
            releaseType: .album,
            status: .official,
            country: "us",
            isReissue: true
        )
        let appleMusic = CountingReleaseCandidateService(
            callCounter: callCounter,
            releaseCandidates: [candidate]
        )
        let beforeUTCNewYear = try utcDate(year: 2026, month: 12, day: 31, hour: 22)
        let afterUTCNewYear = try utcDate(year: 2027, month: 1, day: 1, hour: 1)
        let firstOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: appleMusic,
            cache: cache,
            disabledSources: [.musicBrainz, .discogs]
        ) { $0.dateProvider = { beforeUTCNewYear } }
        let secondOrchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: appleMusic,
            cache: cache,
            disabledSources: [.musicBrainz, .discogs]
        ) { $0.dateProvider = { afterUTCNewYear } }

        let firstCandidates = await firstOrchestrator.getReleaseCandidates(
            artist: candidate.artist,
            album: candidate.album,
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondCandidates = await secondOrchestrator.getReleaseCandidates(
            artist: candidate.artist,
            album: candidate.album,
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let scorer = YearScorer()
        let firstScore = try scorer.scoreRelease(
            #require(firstCandidates.first),
            queryArtist: candidate.artist,
            queryAlbum: candidate.album
        ).totalScore
        let secondScore = try scorer.scoreRelease(
            #require(secondCandidates.first),
            queryArtist: candidate.artist,
            queryAlbum: candidate.album
        ).totalScore

        #expect(firstCandidates.first?.isReissue == true)
        #expect(secondCandidates.first?.isReissue == false)
        #expect(firstScore == 50)
        #expect(secondScore == 80)
        #expect(await callCounter.count() == 1)
    }

    @Test("Release candidate cache ignores legacy v2 entries")
    func ignoresLegacyV2Cache() async {
        let cache = MockCacheService()
        await cache.setRawJSON(
            key: legacyV2CacheKey,
            json: legacyV2CacheJSON,
            ttl: 86400
        )
        let callCounter = APICallCounter()
        let expectedCandidate = ReleaseCandidate(
            artist: "In Flames",
            album: "Battles",
            year: 2016,
            source: .musicBrainz
        )
        let musicBrainz = CountingReleaseCandidateService(
            callCounter: callCounter,
            releaseCandidates: [expectedCandidate]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let result = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result == [expectedCandidate])
        #expect(await callCounter.count() == 1)
    }

    @Test("Release candidate cache uses cleaned API search album")
    func releaseCandidateCacheUsesCleanedAPISearchAlbum() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, _, _ in
            [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: 2022,
                    source: .musicBrainz
                ),
            ]
        }
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let decoratedResult = await orchestrator.getReleaseCandidates(
            artist: "Karma & Effect",
            album: "\"Survival of the Sickest\" (Bonus Track Version)",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let cleanedResult = await orchestrator.getReleaseCandidates(
            artist: "Karma and Effect",
            album: "Survival of the Sickest",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(decoratedResult == [
            ReleaseCandidate(
                artist: "Karma and Effect",
                album: "Survival of the Sickest",
                year: 2022,
                source: .musicBrainz
            ),
        ])
        #expect(cleanedResult == decoratedResult)
        #expect(await callCounter.count() == 1)
    }

    @Test("Empty release candidate result is cached")
    func emptyReleaseCandidateResultIsCached() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(
            callCounter: callCounter,
            releaseCandidates: []
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        ) {
            $0.negativeResultTTL = 123
        }

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "Unknown Artist",
            album: "Unknown Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "Unknown Artist",
            album: "Unknown Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult.isEmpty)
        #expect(secondResult.isEmpty)
        #expect(await callCounter.count() == 1)
    }

    @Test("Release candidate cache separates query context")
    func releaseCandidateCacheSeparatesQueryContext() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, libraryYear, _ in
            [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: libraryYear ?? 0,
                    source: .musicBrainz
                ),
            ]
        }
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: 2015,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: 2016,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult.map(\.year) == [2015])
        #expect(secondResult.map(\.year) == [2016])
        #expect(await callCounter.count() == 2)
    }

    @Test("Release candidate cache separates earliest added year context")
    func releaseCandidateCacheSeparatesEarliestAddedYearContext() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, _, addedYear in
            [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: addedYear ?? 0,
                    source: .musicBrainz
                ),
            ]
        }
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: 2016,
            earliestTrackAddedYear: 2020
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: 2016,
            earliestTrackAddedYear: 2021
        )

        #expect(firstResult.map(\.year) == [2020])
        #expect(secondResult.map(\.year) == [2021])
        #expect(await callCounter.count() == 2)
    }

    @Test("Release candidate cache separates delimiter-like artist and album names")
    func releaseCandidateCacheSeparatesDelimiterLikeArtistAndAlbumNames() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, _, _ in
            let year = artist == "A" && album == "B C" ? 2001 : 2002
            return [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: year,
                    source: .musicBrainz
                ),
            ]
        }
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "A",
            album: "B:C",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "A:B",
            album: "C",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult.map(\.year) == [2001])
        #expect(secondResult.map(\.year) == [2002])
        #expect(await callCounter.count() == 2)
    }

    @Test("Failed release candidate fetch is not cached as empty")
    func failedReleaseCandidateFetchIsNotCachedAsEmpty() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let expectedCandidate = ReleaseCandidate(
            artist: "In Flames",
            album: "Battles",
            year: 2016,
            source: .musicBrainz
        )
        let musicBrainz = FlakyReleaseCandidateService(
            callCounter: callCounter,
            releaseCandidates: [expectedCandidate]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let failedResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let recoveredResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(failedResult.isEmpty)
        #expect(recoveredResult == [expectedCandidate])
        #expect(await callCounter.count() == 2)
    }
}

private func releaseCandidates(from orchestrator: APIOrchestrator) async -> [ReleaseCandidate] {
    await orchestrator.getReleaseCandidates(
        artist: "Björk",
        album: "Homogenic",
        currentLibraryYear: nil,
        earliestTrackAddedYear: nil
    )
}

typealias ReleaseCandidateResolver = @Sendable (
    _ artist: String,
    _ album: String,
    _ currentLibraryYear: Int?,
    _ earliestTrackAddedYear: Int?
) -> [ReleaseCandidate]

struct CountingReleaseCandidateService: ExternalAPIService {
    let callCounter: APICallCounter
    let releaseCandidates: ReleaseCandidateResolver

    init(callCounter: APICallCounter, releaseCandidates: [ReleaseCandidate]) {
        self.callCounter = callCounter
        self.releaseCandidates = { _, _, _, _ in releaseCandidates }
    }

    init(callCounter: APICallCounter, releaseCandidates: @escaping ReleaseCandidateResolver) {
        self.callCounter = callCounter
        self.releaseCandidates = releaseCandidates
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> [ReleaseCandidate] {
        await callCounter.increment()
        return releaseCandidates(artist, album, currentLibraryYear, earliestTrackAddedYear)
    }

    func initialize(force _: Bool) async throws {
        // Test double has no external resources to initialize.
    }

    func close() async {
        // Test double has no external resources to release.
    }
}

private struct FlakyReleaseCandidateService: ExternalAPIService {
    let callCounter: APICallCounter
    let releaseCandidates: [ReleaseCandidate]

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        let callNumber = await callCounter.incrementAndCount()
        if callNumber == 1 {
            throw ReleaseCandidateTestError.transientFailure
        }
        return releaseCandidates
    }

    func initialize(force _: Bool) async throws {
        // Test double has no external resources to initialize.
    }

    func close() async {
        // Test double has no external resources to release.
    }
}

private enum ReleaseCandidateTestError: Error {
    case transientFailure
}

private func utcDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return try #require(calendar.date(from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour
    )))
}

private let legacyV2CacheKey =
    "release_candidates:2:v2|11:musicbrainz|9:in flames|7:battles|16:library_year=nil|23:earliest_added_year=nil"

private let legacyV2CacheJSON = """
[
  {
    "artist": "In Flames",
    "album": "Battles",
    "year": 1900,
    "source": "musicbrainz",
    "releaseType": "album",
    "status": "official",
    "country": null,
    "isReissue": false,
    "mbReleaseGroupID": null,
    "mbReleaseGroupFirstYear": null,
    "genre": null
  }
]
"""
