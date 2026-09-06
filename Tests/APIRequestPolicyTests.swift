import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("API request policy composition")
@MainActor
struct APIRequestPolicyTests {
    @Test("Configured provider rates compose one-token paced clients")
    func wiresProviderPacing() async throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        configuration.yearRetrieval.rateLimits.discogsRequestsPerMinute = 300
        configuration.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = 10
        configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond = 20
        configuration.yearRetrieval.requestTimeoutSeconds = 22.5
        let service = DashboardStateAPIService()
        var capturedDiscogs: TokenBucketRateLimiter?
        var capturedMusicBrainz: TokenBucketRateLimiter?
        var capturedITunes: TokenBucketRateLimiter?
        var capturedMusicBrainzTimeout: TimeInterval?
        var capturedITunesTimeout: TimeInterval?
        let factories = APIClientFactoryOverrides(
            configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
                capturedDiscogs = rateLimiter
                return DiscogsClient(
                    token: token,
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            musicBrainzFactory: { _, _, rateLimiter, _, transport in
                capturedMusicBrainz = rateLimiter
                capturedMusicBrainzTimeout = transport.requestTimeoutSeconds
                return service
            },
            catalogFactory: { _, rateLimiter, transport in
                capturedITunes = rateLimiter
                capturedITunesTimeout = transport.requestTimeoutSeconds
                return service
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factories
        )

        let discogs = try #require(capturedDiscogs)
        let musicBrainz = try #require(capturedMusicBrainz)
        let itunes = try #require(capturedITunes)
        #expect(discogs.policy == .init(maxTokens: 1, refillInterval: .milliseconds(200)))
        #expect(musicBrainz.policy == .init(maxTokens: 1, refillInterval: .milliseconds(100)))
        #expect(itunes.policy == .init(maxTokens: 1, refillInterval: .milliseconds(50)))
        #expect(await discogs.getStats().currentTokens == 1)
        #expect(await musicBrainz.getStats().currentTokens == 1)
        #expect(await itunes.getStats().currentTokens == 1)
        #expect(capturedMusicBrainzTimeout == 22.5)
        #expect(capturedITunesTimeout == 22.5)
    }

    @Test("Legacy zero MusicBrainz rate keeps its former effective pacing")
    func wiresLegacyRate() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = 0
        let service = DashboardStateAPIService()
        var capturedLimiter: TokenBucketRateLimiter?
        let factories = APIClientFactoryOverrides(
            musicBrainzFactory: { _, _, rateLimiter, _, _ in
                capturedLimiter = rateLimiter
                return service
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factories
        )

        let limiter = try #require(capturedLimiter)
        #expect(limiter.policy == .init(maxTokens: 1, refillInterval: .seconds(1)))
    }

    @Test("Displayed provider policy matches effective runtime values")
    func displaysEffectivePolicy() {
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        #expect(APICacheTab.musicBrainzRateText(0) == "1\(decimalSeparator)0 (legacy setting: 0)")
        #expect(APICacheTab.musicBrainzRateText(2.5) == "2\(decimalSeparator)5")
        #expect(APICacheTab.requestTimeoutText(22.5) == "22\(decimalSeparator)5s")
        #expect(APICacheTab.requestTimeoutText(45) == "45s")
    }
}
