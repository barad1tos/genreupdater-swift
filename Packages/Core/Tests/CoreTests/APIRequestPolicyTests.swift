import Foundation
import Testing
@testable import Core

@Suite("API request policy")
struct APIRequestPolicyTests {
    @Test("Persisted policy preserves missing-key defaults and explicit tuning")
    func decodingAndRoundTrip() throws {
        let defaults = AppConfiguration().yearRetrieval
        #expect(defaults.rateLimits.musicbrainzRequestsPerSecond == 1)
        #expect(defaults.rateLimits.itunesRequestsPerSecond == 10)
        #expect(defaults.rateLimits.concurrentAlbums == 2)
        #expect(defaults.rateLimits.concurrentProviderCalls == 6)
        #expect(defaults.requestTimeoutSeconds == 45)

        let legacy = try JSONDecoder().decode(
            APIRateLimits.self,
            from: Data(#"{"discogsRequestsPerMinute":42,"concurrentAPICalls":4}"#.utf8)
        )
        #expect(legacy.discogsRequestsPerMinute == 42)
        #expect(legacy.itunesRequestsPerSecond == 10)
        #expect(legacy.concurrentAlbums == 4)
        #expect(legacy.concurrentProviderCalls == 4)
        let migrated = try JSONDecoder().decode(
            APIRateLimits.self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(migrated.concurrentAlbums == 4)
        #expect(migrated.concurrentProviderCalls == 4)

        let explicit = try JSONDecoder().decode(
            APIRateLimits.self,
            from: Data(
                #"{"concurrentAPICalls":4,"concurrentAlbums":3,"concurrentProviderCalls":9}"#.utf8
            )
        )
        #expect(explicit.concurrentAlbums == 3)
        #expect(explicit.concurrentProviderCalls == 9)

        let malformedFallback = try JSONDecoder().decode(
            APIRateLimits.self,
            from: Data(
                #"{"concurrentAPICalls":"invalid","concurrentAlbums":3,"concurrentProviderCalls":9}"#.utf8
            )
        )
        #expect(malformedFallback.concurrentAlbums == 3)
        #expect(malformedFallback.concurrentProviderCalls == 9)

        var tuned = YearRetrievalConfig()
        tuned.rateLimits.itunesRequestsPerSecond = 7.5
        tuned.rateLimits.concurrentAlbums = 3
        tuned.rateLimits.concurrentProviderCalls = 9
        tuned.requestTimeoutSeconds = 22.5
        let roundTripped = try JSONDecoder().decode(
            YearRetrievalConfig.self,
            from: JSONEncoder().encode(tuned)
        )
        #expect(roundTripped.rateLimits.itunesRequestsPerSecond == 7.5)
        #expect(roundTripped.rateLimits.concurrentAlbums == 3)
        #expect(roundTripped.rateLimits.concurrentProviderCalls == 9)
        #expect(roundTripped.requestTimeoutSeconds == 22.5)
    }

    @Test("Request timeout migrates from the legacy provider key")
    func migratesLegacyRequestTimeout() throws {
        let historical = try JSONDecoder().decode(YearRetrievalConfig.self, from: Data("{}".utf8))
        #expect(historical.requestTimeoutSeconds == 45)
        let legacyTimeout = try JSONDecoder().decode(
            YearRetrievalConfig.self,
            from: Data(#"{"providerTimeoutSeconds":22.5}"#.utf8)
        )
        #expect(legacyTimeout.requestTimeoutSeconds == 22.5)
        let migratedTimeoutData = try JSONEncoder().encode(legacyTimeout)
        let migratedTimeoutJSON = try #require(JSONSerialization
            .jsonObject(with: migratedTimeoutData) as? [String: Any])
        #expect(migratedTimeoutJSON["requestTimeoutSeconds"] as? Double == 22.5)
        #expect(migratedTimeoutJSON["providerTimeoutSeconds"] == nil)
    }

    @Test("Request quotas produce conservative one-token intervals")
    func pacingIntervals() {
        #expect(APIRateLimits.refillMilliseconds(requests: 55, perSeconds: 60) == 1091)
        #expect(APIRateLimits.refillMilliseconds(requests: 1, perSeconds: 1) == 1000)
        #expect(APIRateLimits.refillMilliseconds(requests: 10, perSeconds: 1) == 100)
        #expect(APIRateLimits.refillMilliseconds(requests: 1e-308, perSeconds: 1) == nil)
    }

    @Test("Legacy zero MusicBrainz rate remains a valid persisted boundary")
    func preservesLegacyZeroRate() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genreupdater-zero-musicbrainz-rate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        let legacyJSON = Data(
            #"{"yearRetrieval":{"rateLimits":{"musicbrainzRequestsPerSecond":0}}}"#.utf8
        )
        let historical = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON)
        try legacyJSON.write(to: configURL, options: .atomic)

        let loaded = try AppConfiguration.load(from: configURL)
        try loaded.save(to: configURL)
        let reloaded = try AppConfiguration.load(from: configURL)

        #expect(historical.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond == 0)
        #expect(loaded.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond == 0)
        #expect(reloaded.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond == 0)
        #expect(APIRateLimits.musicBrainzRate(0) == 1)
        #expect(APIRateLimits.musicBrainzRate(2.5) == 2.5)
    }

    @Test("Live configuration migrates the legacy concurrency budget for both scheduling layers")
    func migratesLegacyConcurrency() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genreupdater-legacy-api-concurrency-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        let legacyJSON = Data(
            #"{"year_retrieval":{"rate_limits":{"concurrent_api_calls":4}}}"#.utf8
        )
        try legacyJSON.write(to: configURL, options: .atomic)

        let loaded = try AppConfiguration.load(from: configURL)
        try loaded.save(to: configURL)
        let reloaded = try AppConfiguration.load(from: configURL)

        #expect(loaded.yearRetrieval.rateLimits.concurrentAlbums == 4)
        #expect(loaded.yearRetrieval.rateLimits.concurrentProviderCalls == 4)
        #expect(reloaded.yearRetrieval.rateLimits.concurrentAlbums == 4)
        #expect(reloaded.yearRetrieval.rateLimits.concurrentProviderCalls == 4)
    }

    @Test("New provider policy fields reject unsafe persisted values", arguments: PolicyFault.allCases)
    private func rejectsUnsafeValues(_ fault: PolicyFault) {
        var configuration = AppConfiguration()
        fault.apply(to: &configuration)

        #expect(throws: ConfigurationValidationError.self) {
            try configuration.validate()
        }
    }
}

private enum PolicyFault: CaseIterable, Sendable {
    case zeroITunesRate
    case overflowingITunesInterval
    case zeroTimeout
    case overflowingTimeout

    func apply(to configuration: inout AppConfiguration) {
        switch self {
        case .zeroITunesRate:
            configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond = 0
        case .overflowingITunesInterval:
            configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond = 1e-308
        case .zeroTimeout:
            configuration.yearRetrieval.requestTimeoutSeconds = 0
        case .overflowingTimeout:
            configuration.yearRetrieval.requestTimeoutSeconds = 1e308
        }
    }
}
