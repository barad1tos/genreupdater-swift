// Phase 4: API + Cache
//
// MusicKit requires an entitlement and running app context for catalog searches.
// Unit tests here verify only non-MusicKit logic. Catalog search coverage lives
// in the app-hosted IntegrationTests target.

import Foundation
import MusicKit
import Testing
@testable import Core
@testable import Services

private enum ITunesPath {
    static let search = path("search")
    static let lookup = path("lookup")

    private static let separator = "/"

    private static func path(_ endpoint: String) -> String {
        separator + endpoint
    }
}

private actor RequestHold {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - CatalogSearchClientTests

@Suite("CatalogSearchClient — Apple Music catalog search via MusicKit", .serialized)
struct CatalogSearchClientTests {
    @Test("Client conforms to ExternalAPIService")
    func conformsToProtocol() {
        requireExternalAPIService(CatalogSearchClient())
    }

    @Test("Public initializer keeps its original function type")
    func preservesInitializerType() {
        let initializer: (
            URLSession,
            String,
            String,
            Int,
            ITunesSearchConfiguration,
            Bool,
            RawAPIRequestCache?
        ) -> CatalogSearchClient = CatalogSearchClient.init

        _ = initializer
    }

    @Test("Public paced factory keeps its original function type")
    func preservesPacedFactoryType() {
        let factory: (
            ITunesSearchConfig,
            TokenBucketRateLimiter,
            URLSession,
            RawAPIRequestCache?
        ) -> CatalogSearchClient = CatalogSearchClient.paced

        _ = factory
    }

    @Test("Album year lookup reports unavailable MusicKit authorization as a failure")
    func requiresAuthorization() async {
        let client = CatalogSearchClient(
            dateProvider: { Date() },
            authorizeMusic: { .denied },
            findReleaseDate: { _ in
                Issue.record("Catalog search must not run without authorization")
                return nil
            }
        )

        await #expect(throws: CatalogSearchError.self) {
            _ = try await client.getAlbumYear(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
    }

    @Test("Album year lookup propagates catalog request failures")
    func propagatesRequestFailure() async {
        let client = CatalogSearchClient(
            dateProvider: { Date() },
            authorizeMusic: { .authorized },
            findReleaseDate: { _ in throw URLError(.timedOut) }
        )

        await #expect(throws: URLError.self) {
            _ = try await client.getAlbumYear(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
    }

    @Test("Request timeout rejects values outside the configured capacity")
    func rejectsUnrepresentableRequestTimeout() {
        let policy = ProviderRequestPolicy(timeoutSeconds: 1e308)

        #expect(policy.timeoutSeconds == YearRetrievalConfig.defaultRequestTimeoutSeconds)
    }

    @Test("Request timeout preserves representable values beyond the UI range")
    func preservesRepresentableRequestTimeout() {
        let policy = ProviderRequestPolicy(timeoutSeconds: 300)

        #expect(policy.timeoutSeconds == 300)
    }

    @Test("Cancelled lookup does not start a catalog request")
    func cancelledLookupDoesNotStartRequest() async {
        let requestStarted = EventCounter()
        let startGate = RequestHold()
        let client = CatalogSearchClient(
            dateProvider: { Date() },
            authorizeMusic: { .authorized },
            findReleaseDate: { _ in
                requestStarted.record()
                return nil
            }
        )

        let lookup = Task {
            await startGate.wait()
            return try await client.getAlbumYear(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        lookup.cancel()
        await startGate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await lookup.value
        }
        #expect(await !requestStarted.wait(for: 1, timeout: .milliseconds(50)))
    }

    @Test("Album year lookup returns at its deadline when MusicKit ignores cancellation")
    func timesOutNonCooperativeMusicKitRequest() async {
        let requestStarted = EventCounter()
        let requestFinished = EventCounter()
        let requestHold = RequestHold()
        let client = CatalogSearchClient(
            dateProvider: { Date() },
            authorizeMusic: { .authorized },
            findReleaseDate: { _ in
                requestStarted.record()
                await requestHold.wait()
                requestFinished.record()
                return nil
            }
        ).withRequestTimeout(seconds: 0.01)

        let lookup = Task {
            try await client.getAlbumYear(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        #expect(await requestStarted.wait(for: 1))

        do {
            _ = try await taskValue(lookup, timeout: .milliseconds(200))
            Issue.record("Expected MusicKit request timeout")
        } catch let error as ProviderRequestTimeout {
            #expect(error.operation == .appleMusicCatalogSearch)
            #expect(error.timeoutSeconds == 0.01)
        } catch {
            Issue.record("Expected ProviderRequestTimeout, got \(error)")
        }

        await requestHold.release()
        #expect(await requestFinished.wait(for: 1))
    }

    @Test("Album year lookup keeps an empty catalog response as a confirmed miss")
    func returnsConfirmedMiss() async throws {
        let client = CatalogSearchClient(
            dateProvider: { Date() },
            authorizeMusic: { .authorized },
            findReleaseDate: { _ in nil }
        )

        let result = try await client.getAlbumYear(
            artist: "Test Artist",
            album: "Missing Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
    }

    @Test("iTunes configuration uses expected wire paths")
    func configurationUsesExpectedPaths() {
        let configuration = ITunesSearchConfiguration()

        #expect(ITunesSearchConfiguration.endpointPath("search") == ITunesPath.search)
        #expect(ITunesSearchConfiguration.endpointPath("lookup") == ITunesPath.lookup)
        #expect(configuration.searchPath == ITunesPath.search)
        #expect(configuration.lookupPath == ITunesPath.lookup)
    }

    @Test("getArtistActivityPeriod returns nil pair — MusicKit does not expose this")
    func artistActivityPeriodReturnsNil() async throws {
        let client = CatalogSearchClient()
        let (start, end) = try await client.getArtistActivityPeriod(
            normalizedArtist: "Test Artist"
        )
        #expect(start == nil)
        #expect(end == nil)
    }

    @Test("getArtistStartYear returns earliest matching iTunes album release year")
    func artistStartYearUsesEarliestMatchingITunesAlbum() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        ITunesMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.host == "itunes.apple.com")
            #expect(components.path == ITunesPath.search)

            let queryItems = try #require(components.queryItems)
            #expect(queryItems.first { $0.name == "term" }?.value == "Test Artist")
            #expect(queryItems.first { $0.name == "country" }?.value == "US")
            #expect(queryItems.first { $0.name == "entity" }?.value == "album")
            #expect(queryItems.first { $0.name == "limit" }?.value == "200")

            let json = """
            {
                "resultCount": 3,
                "results": [
                    {
                        "artistName": "Test Artist",
                        "collectionName": "Later Album",
                        "releaseDate": "2001-05-01T07:00:00Z"
                    },
                    {
                        "artistName": "Test Artist",
                        "collectionName": "Debut Album",
                        "releaseDate": "1998-01-01T08:00:00Z"
                    },
                    {
                        "artistName": "Other Artist",
                        "collectionName": "Older Album",
                        "releaseDate": "1980-01-01T08:00:00Z"
                    }
                ]
            }
            """

            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }

        let client = CatalogSearchClient(session: session, countryCode: "US")
        let year = try await client.getArtistStartYear(normalizedArtist: "Test Artist")
        #expect(year == 1998)
    }

    @Test("getReleaseCandidates returns matching iTunes album candidates")
    func releaseCandidatesUseITunesSearchResults() async throws { // swiftlint:disable:this function_body_length
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        ITunesMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.path == ITunesPath.search)
            #expect(components.queryItems?.first { $0.name == "term" }?.value == "Test Artist Test Album")
            #expect(components.queryItems?.first { $0.name == "country" }?.value == "UA")
            #expect(components.queryItems?.first { $0.name == "entity" }?.value == "album")
            #expect(components.queryItems?.first { $0.name == "limit" }?.value == "25")

            let json = """
            {
              "resultCount": 3,
              "results": [
                {
                  "artistName": "Test Artist",
                  "collectionName": "Test Album",
                  "releaseDate": "1998-01-01T08:00:00Z",
                  "country": "USA"
                },
                {
                  "artistName": "Other Artist",
                  "collectionName": "Test Album",
                  "releaseDate": "1980-01-01T08:00:00Z"
                },
                {
                  "artistName": "Test Artist",
                  "collectionName": "Different Album",
                  "releaseDate": "1999-01-01T08:00:00Z"
                }
              ]
            }
            """

            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }

        let client = CatalogSearchClient(
            session: session,
            countryCode: "UA",
            entity: "album",
            limit: 25,
            lookupFallbackEnabled: true
        )

        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.year == 1998)
        #expect(candidate.source == .itunes)
        #expect(candidate.artist == "Test Artist")
        #expect(candidate.album == "Test Album")
    }

    @Test("Recent iTunes candidate preserves Python scoring output")
    func recentReleaseParity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let scoringDate = Date()
        let currentYear = try utcYear(at: scoringDate)
        ITunesMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let json = """
            {
              "resultCount": 1,
              "results": [{
                "artistName": "Parity Artist",
                "collectionName": "Parity Album",
                "collectionType": "Album",
                "releaseDate": "\(currentYear)-01-01T00:00:00Z",
                "country": "US"
              }]
            }
            """
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }

        let client = CatalogSearchClient(
            session: session,
            lookupFallbackEnabled: false,
            dateProvider: { scoringDate }
        )
        let candidates = try await client.getReleaseCandidates(
            artist: "Parity Artist",
            album: "Parity Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let candidate = try #require(candidates.first)
        let scorer = YearScorer()
        let scored = scorer.scoreRelease(
            candidate,
            queryArtist: "Parity Artist",
            queryAlbum: "Parity Album"
        )
        let result = scorer.resolveScores([scored])

        #expect(candidate.isReissue)
        #expect(scored.totalScore == 50)
        #expect(result.year == currentYear)
        #expect(result.isDefinitive)
        #expect(result.confidence == 50)
        #expect(result.yearScores == [currentYear: 50])
    }

    @Test("iTunes request begins only after rate-limit admission")
    func requestsWaitForAdmission() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestStarted = EventCounter()
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }
        ITunesMockURLProtocol.requestHandler = { request in
            requestStarted.record()
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Self.matchingITunesPayload)
        }
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(60))
        _ = await limiter.acquire()
        var settings = ITunesSearchConfig()
        settings.lookupFallbackEnabled = false
        let client = CatalogSearchClient.paced(
            settings: settings,
            rateLimiter: limiter,
            session: session
        ).withRequestTimeout(seconds: 1)

        let lookup = Task {
            try await client.getReleaseCandidates(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        let startedBeforeAdmission = await requestStarted.wait(for: 1, timeout: .milliseconds(50))
        #expect(!startedBeforeAdmission)

        await limiter.release()
        let candidates = try await taskValue(lookup, timeout: .seconds(1))

        #expect(candidates.map(\.year) == [1998])
        let startedAfterAdmission = await requestStarted.wait(for: 1)
        #expect(startedAfterAdmission)
    }

    @Test("Cancelled iTunes admission never reaches the network")
    func cancelledAdmissionStopsRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestStarted = EventCounter()
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }
        ITunesMockURLProtocol.requestHandler = { request in
            requestStarted.record()
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Self.matchingITunesPayload)
        }
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(60))
        _ = await limiter.acquire()
        var settings = ITunesSearchConfig()
        settings.lookupFallbackEnabled = false
        let client = CatalogSearchClient.paced(
            settings: settings,
            rateLimiter: limiter,
            session: session
        )
        let lookup = Task {
            try await client.getReleaseCandidates(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }

        #expect(await limiter.waitForQueue(1, timeout: .seconds(1)))
        lookup.cancel()
        do {
            _ = try await taskValue(lookup, timeout: .milliseconds(100))
            Issue.record("Expected prompt CancellationError")
        } catch is CancellationError {
            // Expected terminal result.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await limiter.waitForQueue(0, timeout: .milliseconds(100)))

        await limiter.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await !(requestStarted.wait(for: 1, timeout: .milliseconds(20))))
    }

    @Test("iTunes cache hits do not consume request admission")
    func cacheHitsBypassAdmission() async throws {
        let cache = MockCacheService()
        let rawCache = RawAPIRequestCache(cache: cache, ttl: 3600)
        let url = try #require(CatalogSearchClient.buildITunesSearchURL(
            term: "Test Artist Test Album",
            countryCode: "US",
            entity: "album",
            limit: 200
        ))
        _ = try await rawCache.data(api: "itunes", url: url) {
            Self.matchingITunesPayload
        }
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(60))
        _ = await limiter.acquire()
        var settings = ITunesSearchConfig()
        settings.lookupFallbackEnabled = false
        let client = CatalogSearchClient.paced(
            settings: settings,
            rateLimiter: limiter,
            rawRequestCache: rawCache
        )

        let lookup = Task {
            try await client.getReleaseCandidates(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        let candidates = try await taskValue(lookup, timeout: .milliseconds(200))

        #expect(candidates.map(\.year) == [1998])
        #expect(await limiter.getStats().totalRequests == 1)
    }

    @Test("getReleaseCandidates throws for unsuccessful iTunes HTTP status")
    func releaseCandidatesThrowForUnsuccessfulITunesStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        ITunesMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(#"{"resultCount": 0, "results": []}"#.utf8))
        }

        let client = CatalogSearchClient(session: session)
        do {
            _ = try await client.getReleaseCandidates(
                artist: "Test Artist",
                album: "Test Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
            Issue.record("Expected iTunes HTTP failure")
        } catch {
            #expect(error.localizedDescription == "iTunes request returned HTTP 500")
        }
    }

    @Test("iTunes requests carry the configured request timeout")
    func releaseCandidatesUseConfiguredRequestTimeout() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        ITunesMockURLProtocol.requestHandler = { request in
            #expect(request.timeoutInterval == 22.5)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(#"{"resultCount":0,"results":[]}"#.utf8))
        }

        let client = CatalogSearchClient(session: session, lookupFallbackEnabled: false)
            .withRequestTimeout(seconds: 22.5)
        _ = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
    }

    @Test("getReleaseCandidates uses iTunes lookup fallback when search is empty")
    func releaseCandidatesUseLookupFallback() async throws { // swiftlint:disable:this function_body_length
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ITunesMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestNumber = 0
        defer {
            ITunesMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        ITunesMockURLProtocol.requestHandler = { request in
            requestNumber += 1
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let path = components.path
            let queryItems = components.queryItems ?? []

            let json: String
            if requestNumber == 1 {
                #expect(path == ITunesPath.search)
                #expect(queryItems.first { $0.name == "entity" }?.value == "album")
                json = #"{"resultCount": 0, "results": []}"#
            } else if requestNumber == 2 {
                #expect(path == ITunesPath.search)
                #expect(queryItems.first { $0.name == "entity" }?.value == "musicArtist")
                json = """
                {
                  "resultCount": 1,
                  "results": [
                    { "artistName": "Test Artist", "artistId": 12345 }
                  ]
                }
                """
            } else {
                #expect(path == ITunesPath.lookup)
                #expect(queryItems.first { $0.name == "id" }?.value == "12345")
                json = """
                {
                  "resultCount": 2,
                  "results": [
                    { "wrapperType": "artist", "artistName": "Test Artist", "artistId": 12345 },
                    {
                      "wrapperType": "collection",
                      "artistName": "Test Artist",
                      "collectionName": "Test Album",
                      "releaseDate": "1998-01-01T08:00:00Z"
                    }
                  ]
                }
                """
            }

            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }

        let client = CatalogSearchClient(session: session)
        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.year) == [1998])
        #expect(requestNumber == 3)
    }

    private func requireExternalAPIService(_ service: any ExternalAPIService) {
        _ = service
    }

    private static let matchingITunesPayload = Data(
        """
        {
          "resultCount": 1,
          "results": [{
            "artistName": "Test Artist",
            "collectionName": "Test Album",
            "releaseDate": "1998-01-01T08:00:00Z",
            "country": "US"
          }]
        }
        """.utf8
    )
}

private func utcYear(at date: Date) throws -> Int {
    try #require(Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date).year)
}

private final class ITunesMockURLProtocol: URLProtocol {
    // Safety: tests install this handler before creating the ephemeral URLSession and clear it after use.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "itunes.apple.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // These mock responses are delivered synchronously, so there is no pending work to cancel.
    }
}
