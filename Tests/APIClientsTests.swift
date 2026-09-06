import Core
import CryptoKit
import Foundation
import Security
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("AppDependencies API clients", .serialized)
@MainActor
struct APIClientsTests {
    @Test("Keychain Discogs failures are reported before fallback client creation")
    func keychainDiscogsFailuresAreReportedBeforeFallbackClientCreation() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        let expectedError = KeychainError.authenticationFailed(errSecUserCanceled)
        var capturedError: (any Error)?
        var capturedIssue: DiscogsCredentialIssue?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { _, _, _ in
                throw expectedError
            },
            keychainErrorHandler: { error in
                capturedError = error
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        let keychainError = try #require(capturedError as? KeychainError)
        #expect(keychainError == expectedError)
        #expect(capturedIssue == .keychain(expectedError))
    }

    @Test("Successful Keychain Discogs load clears the credential issue")
    func successfulKeychainDiscogsLoadClearsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        var capturedIssue: DiscogsCredentialIssue? = .keychain(.invalidTokenData)
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, rateLimiter, baseURL in
                DiscogsClient(
                    token: "saved-token",
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        #expect(capturedIssue == nil)
    }

    @Test("Missing Keychain Discogs token reports a credential issue and disables Discogs")
    func missingKeychainDiscogsTokenReportsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        var capturedIssue: DiscogsCredentialIssue?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, rateLimiter, baseURL in
                DiscogsClient(
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        let orchestrator = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        #expect(capturedIssue == .missingToken)
        #expect(orchestrator.disabledSources.contains(.discogs))
    }

    @Test("Configured Discogs token bypasses Keychain and clears the credential issue")
    func configuredDiscogsTokenBypassesKeychainAndClearsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        configuration.yearRetrieval.apiAuth.discogsBaseHost = "sandbox.discogs.com"
        var capturedIssue: DiscogsCredentialIssue? = .keychain(.invalidTokenData)
        var capturedBaseURL: URL?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { _, _, _ in
                throw KeychainError.authenticationFailed(errSecAuthFailed)
            },
            configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
                capturedBaseURL = baseURL
                return DiscogsClient(
                    token: token,
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        #expect(capturedIssue == nil)
        #expect(capturedBaseURL?.host == "sandbox.discogs.com")
    }

    @Test("Configured Discogs API host is passed to Keychain client factory")
    func configuredDiscogsAPIHostIsPassedToKeychainFactory() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        configuration.yearRetrieval.apiAuth.discogsBaseHost = "sandbox.discogs.com"
        var capturedBaseURL: URL?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, rateLimiter, baseURL in
                capturedBaseURL = baseURL
                return DiscogsClient(
                    token: "saved-token",
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        let baseURL = try #require(capturedBaseURL)
        #expect(baseURL.scheme == "https")
        #expect(baseURL.host == "sandbox.discogs.com")
    }

    @Test("Configured reissue evidence reaches the composed Discogs client")
    func composesDiscogsReissueEvidence() async {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.preferredAPI = .discogs
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        configuration.yearRetrieval.reissueDetection.reissueKeywords = ["anniversary"]
        CapturedAuthURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            let data = Data(
                """
                {"results":[{"id":7,"title":"Test Artist - Test Album (Anniversary)","year":2020,
                "type":"release","format":["Album"]}]}
                """
                .utf8
            )
            return (response, data)
        }
        defer { CapturedAuthURLProtocol.requestHandler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let factoryOverrides = APIClientFactoryOverrides(
            configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
                DiscogsClient(
                    token: token,
                    contactEmail: contactEmail,
                    session: session,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            musicBrainz: DashboardStateAPIService(),
            appleMusic: DashboardStateAPIService()
        )

        let orchestrator = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )
        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.first?.isReissue == true)
    }

    @Test("Configured Discogs search limits reach the composed client")
    func wiresDiscogsSearch() async throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.preferredAPI = .discogs
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        configuration.yearRetrieval.discogsSearch.resultLimit = 17
        configuration.yearRetrieval.discogsSearch.detailLookupLimit = 1
        configuration.yearRetrieval.requestTimeoutSeconds = 22.5
        let requestProbe = DiscogsRequestProbe()
        CapturedAuthURLProtocol.requestHandler = { request in
            #expect(request.timeoutInterval == 22.5)
            return try makeDiscogsLimitResponse(for: request, probe: requestProbe)
        }
        defer { CapturedAuthURLProtocol.requestHandler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let factoryOverrides = APIClientFactoryOverrides(
            configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
                DiscogsClient(
                    token: token,
                    contactEmail: contactEmail,
                    session: session,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            musicBrainz: DashboardStateAPIService(),
            appleMusic: DashboardStateAPIService()
        )

        let orchestrator = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )
        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let requests = requestProbe.requests
        let searchURL = try #require(requests.first?.url)

        #expect(requestQueryValue("per_page", in: searchURL) == "17")
        #expect(requests.compactMap(\.url).filter(isDiscogsRelease).count == 1)
        #expect(candidates.map(\.year) == [2020])
    }

    @Test("MusicBrainz factory receives the current cleaning snapshot without an instance override")
    func wiresMusicBrainzRules() {
        var configuration = AppConfiguration()
        configuration.cleaning.editionMarkers = ["archive-only"]
        configuration.cleaning.albumSuffixes = ["bonus-only"]
        var capturedCleaning: CleaningConfig?
        let service = DashboardStateAPIService()
        let factoryOverrides = APIClientFactoryOverrides(
            musicBrainzFactory: { _, _, _, cleaning, _ in
                capturedCleaning = cleaning
                return service
            },
            appleMusic: service
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        #expect(capturedCleaning == configuration.cleaning)
    }

    @Test("Captured Discogs access is not reloaded during execution")
    func freezesDiscogsAccess() async {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        let headerProbe = AuthHeaderProbe()
        CapturedAuthURLProtocol.requestHandler = { request in
            try makeDiscogsResponse(for: request, probe: headerProbe)
        }
        defer { CapturedAuthURLProtocol.requestHandler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        var keychainReadCount = 0
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, limiter, url in
                keychainReadCount += 1
                return DiscogsClient(
                    token: "submitted-token",
                    contactEmail: contactEmail,
                    session: session,
                    rateLimiter: limiter,
                    baseURL: url
                )
            },
            musicBrainz: DashboardStateAPIService(),
            appleMusic: DashboardStateAPIService()
        )
        let captured = AppDependencies.captureDiscogsAccess(
            configuration: configuration,
            factoryOverrides: factoryOverrides
        )

        let orchestrator = AppDependencies.makeCapturedAPI(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            discogsAccess: captured,
            factoryOverrides: factoryOverrides
        )

        #expect(captured.isEnabled)
        #expect(keychainReadCount == 1)
        #expect(!orchestrator.disabledSources.contains(.discogs))
        let lookup = await orchestrator.getAlbumYearLookup(
            artist: "Submitted Artist",
            album: "Submitted Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(lookup.result.year == 2001)
        #expect(keychainReadCount == 1)
        #expect(!headerProbe.headers.isEmpty)
        #expect(headerProbe.headers.allSatisfy { $0 == "Discogs token=submitted-token" })
    }

    @Test("Captured missing Discogs access stays disabled")
    func freezesMissingDiscogsAccess() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        var keychainReadCount = 0
        let captured = AppDependencies.captureDiscogsAccess(
            configuration: configuration,
            factoryOverrides: APIClientFactoryOverrides(keychainDiscogsClientFactory: { contactEmail, limiter, url in
                keychainReadCount += 1
                return DiscogsClient(contactEmail: contactEmail, rateLimiter: limiter, baseURL: url)
            })
        )

        let orchestrator = AppDependencies.makeCapturedAPI(
            configuration: configuration,
            cache: nil,
            reachability: nil,
            discogsAccess: captured
        )

        #expect(!captured.isEnabled)
        #expect(keychainReadCount == 1)
        #expect(orchestrator.disabledSources.contains(.discogs))
    }

    @Test("Raw API misses expire on the short transport TTL")
    func rawMissExpires() async throws {
        let fixture = try await makeCacheJourney()
        defer {
            CapturedAuthURLProtocol.requestHandler = nil
            fixture.session.invalidateAndCancel()
        }

        let first = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let immediate = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(first.isEmpty)
        #expect(immediate.isEmpty)
        #expect(fixture.probe.requestCount == 1)

        try await Task.sleep(for: .milliseconds(1100))
        let refreshed = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(refreshed.map(\.year) == [2024])
        #expect(fixture.probe.requestCount == 2)
    }

    @Test("Disabling confirmed-miss caching retries every eligible lookup")
    func offRetriesImmediately() async throws {
        let fixture = try await makeCacheJourney(negativeTTL: 0)
        defer {
            CapturedAuthURLProtocol.requestHandler = nil
            fixture.session.invalidateAndCancel()
        }

        let first = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let retried = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(first.isEmpty)
        #expect(retried.map(\.year) == [2024])
        #expect(fixture.probe.requestCount == 2)
    }

    @Test("An upgrade ignores a raw response written before policy timestamps")
    func refreshesLegacyRaw() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("api-cache.db")
        var requestComponents = URLComponents()
        requestComponents.scheme = CatalogSearchClient.defaultITunesScheme
        requestComponents.host = CatalogSearchClient.defaultITunesHost
        requestComponents.path = ITunesSearchConfiguration().searchPath
        requestComponents.queryItems = [
            URLQueryItem(name: "term", value: "Test Artist Test Album"),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        let requestURL = try #require(requestComponents.url)

        do {
            let legacyCache = try GRDBCacheService(databasePath: databaseURL.path, defaultGenericTTL: 31_536_000)
            try await legacyCache.initialize()
            await legacyCache.set(
                key: legacyRawKey(api: "itunes", url: requestURL),
                value: LegacyRawEntry(payload: RawRequestProbe.emptyPayload),
                ttl: 31_536_000
            )
            try await legacyCache.syncToDisk()
        }

        let relaunchedCache = try GRDBCacheService(databasePath: databaseURL.path, defaultGenericTTL: 10)
        try await relaunchedCache.initialize()
        let probe = RawRequestProbe(startingAt: 1)
        let fixture = try await makeCacheJourney(cache: relaunchedCache, probe: probe)
        defer {
            CapturedAuthURLProtocol.requestHandler = nil
            fixture.session.invalidateAndCancel()
        }

        let candidates = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.year) == [2024])
        #expect(probe.requestCount == 2)
    }

    @Test("Off bypasses a durable miss written under a longer policy")
    func offRetriesMiss() async throws {
        try await verifyMissRetry(negativeTTL: 0, aging: .zero)
    }

    @Test("A shorter policy bypasses an older durable miss")
    func retriesAgedMiss() async throws {
        try await verifyMissRetry(negativeTTL: 0.05, aging: .milliseconds(120))
    }
}

@MainActor
private func verifyMissRetry(
    negativeTTL: TimeInterval,
    aging: Duration
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("api-cache.db")
    let probe = RawRequestProbe()

    do {
        let initialCache = try GRDBCacheService(databasePath: databaseURL.path, defaultGenericTTL: 31_536_000)
        try await initialCache.initialize()
        let initial = try await makeCacheJourney(
            cache: initialCache,
            negativeTTL: 31_536_000,
            probe: probe
        )
        _ = await initial.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        initial.session.invalidateAndCancel()
        try await initialCache.syncToDisk()
    }

    try await Task.sleep(for: aging)

    let relaunchedCache = try GRDBCacheService(databasePath: databaseURL.path, defaultGenericTTL: 10)
    try await relaunchedCache.initialize()
    let relaunched = try await makeCacheJourney(
        cache: relaunchedCache,
        negativeTTL: negativeTTL,
        probe: probe
    )
    defer {
        CapturedAuthURLProtocol.requestHandler = nil
        relaunched.session.invalidateAndCancel()
    }

    let candidates = await relaunched.orchestrator.getReleaseCandidates(
        artist: "Test Artist",
        album: "Test Album",
        currentLibraryYear: nil,
        earliestTrackAddedYear: nil
    )

    #expect(candidates.map(\.year) == [2024])
    #expect(probe.requestCount == 2)
}

@MainActor
private func makeCacheJourney(
    cache: GRDBCacheService? = nil,
    negativeTTL: TimeInterval = 1,
    probe: RawRequestProbe = RawRequestProbe()
) async throws -> (
    orchestrator: APIOrchestrator,
    probe: RawRequestProbe,
    session: URLSession
) {
    var configuration = AppConfiguration()
    configuration.yearRetrieval.preferredAPI = .itunes
    configuration.caching.defaultTTLSeconds = 10
    configuration.caching.negativeResultTTL = negativeTTL
    configuration.processing.cacheTTLDays = 36500
    configuration.runtime.maxRetries = 0
    let cache = try cache ?? GRDBCacheService.createInMemory(defaultGenericTTL: 10)
    try await cache.initialize()
    let rawCache = try #require(AppDependencies.makeRawCache(
        configuration: configuration,
        cache: cache
    ))
    CapturedAuthURLProtocol.requestHandler = { request in
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, probe.nextPayload())
    }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    let catalog = CatalogSearchClient(
        session: session,
        lookupFallbackEnabled: false,
        rawRequestCache: rawCache
    )
    var orchestratorConfiguration = APIOrchestratorConfiguration(configuration: configuration)
    orchestratorConfiguration.cache = cache
    orchestratorConfiguration.disabledSources = [.musicBrainz, .discogs]
    let unavailable = DashboardStateAPIService()
    let orchestrator = APIOrchestrator(
        musicBrainz: unavailable,
        discogs: unavailable,
        appleMusic: catalog,
        configuration: orchestratorConfiguration
    )
    return (orchestrator, probe, session)
}

private func makeDiscogsResponse(
    for request: URLRequest,
    probe: AuthHeaderProbe
) throws -> (URLResponse, Data) {
    probe.append(request.value(forHTTPHeaderField: "Authorization"))
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
    let data = Data(
        #"{"results":[{"id":1,"title":"Submitted Artist - Submitted Album","year":"2001","type":"master"}]}"#
            .utf8
    )
    return (response, data)
}

private final class AuthHeaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []

    var headers: [String?] {
        lock.withLock { values }
    }

    func append(_ value: String?) {
        lock.withLock { values.append(value) }
    }
}

private final class DiscogsRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { values }
    }

    func append(_ request: URLRequest) {
        lock.withLock { values.append(request) }
    }
}

private final class RawRequestProbe: @unchecked Sendable {
    static let emptyPayload = Data(#"{"resultCount":0,"results":[]}"#.utf8)

    private let lock = NSLock()
    private var count: Int

    init(startingAt count: Int = 0) {
        self.count = count
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func nextPayload() -> Data {
        lock.withLock {
            count += 1
            guard count > 1 else {
                return Self.emptyPayload
            }
            return Data(
                """
                {
                  "resultCount": 1,
                  "results": [{
                    "artistName": "Test Artist",
                    "collectionName": "Test Album",
                    "releaseDate": "2024-01-01T00:00:00Z"
                  }]
                }
                """
                .utf8
            )
        }
    }
}

private struct LegacyRawEntry: Codable, Sendable {
    let payload: Data?
}

private func legacyRawKey(api: String, url: URL) -> String {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let sortedQuery = (components?.queryItems ?? [])
        .map { "\($0.name)=\($0.value ?? "")" }
        .sorted()
        .joined(separator: "&")
    let port = components?.port.map { ":\($0)" } ?? ""
    let base = "\(components?.scheme ?? "")://\(components?.host ?? "")\(port)\(components?.path ?? "")"
    let canonical = "\(api)|\(base)?\(sortedQuery)"
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "raw_request:\(api):" + digest.map { String(format: "%02x", $0) }.joined()
}

private func requestQueryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private func makeDiscogsLimitResponse(
    for request: URLRequest,
    probe: DiscogsRequestProbe
) throws -> (HTTPURLResponse, Data) {
    probe.append(request)
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
    let payload = if isDiscogsSearch(url) {
        """
        {"results":[
          {"id":7,"title":"Test Artist - Test Album","year":null,"type":"release"},
          {"id":8,"title":"Test Artist - Test Album","year":null,"type":"release"}
        ]}
        """
    } else {
        #"{"id":7,"title":"Test Album","year":2020}"#
    }
    return (response, Data(payload.utf8))
}

private func isDiscogsSearch(_ url: URL) -> Bool {
    url.lastPathComponent == "search"
        && url.deletingLastPathComponent().lastPathComponent == "database"
}

private func isDiscogsRelease(_ url: URL) -> Bool {
    url.deletingLastPathComponent().lastPathComponent == "releases"
}

private final class CapturedAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (URLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
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
        // Responses are delivered synchronously, so there is no pending work to cancel.
    }
}
