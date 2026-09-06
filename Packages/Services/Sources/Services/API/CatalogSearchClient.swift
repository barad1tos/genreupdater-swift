// Phase 4: API + Cache

import Core
import Foundation
import MusicKit
import OSLog

enum CatalogSearchError: Error, Equatable {
    case authorizationRequired
}

extension CatalogSearchError: LocalizedError {
    var errorDescription: String? {
        "Apple Music authorization is required for catalog search"
    }
}

// MARK: - CatalogSearchClient

/// Apple Music catalog search client for album year and genre data.
///
/// Uses MusicKit's `MusicCatalogSearchRequest` for native catalog access and
/// paced admission for HTTP requests to the iTunes Search API.
/// Requires MusicKit entitlement in the app target. Authorization and request
/// failures are reported to callers so they cannot be cached as catalog misses.
///
/// - Note: Artist activity period and start year are not exposed by MusicKit,
///   so those methods always return `nil`.
public struct CatalogSearchClient: ExternalAPIService, Sendable {
    public static let defaultITunesHost = "itunes.apple.com"
    public static let defaultITunesScheme = "https"

    private let session: URLSession
    private let rawRequestCache: RawAPIRequestCache?
    private let rateLimiter: TokenBucketRateLimiter
    private let countryCode: String
    private let entity: String
    private let limit: Int
    private let iTunesConfiguration: ITunesSearchConfiguration
    private let lookupFallbackEnabled: Bool
    private let dateProvider: @Sendable () -> Date
    private let authorizeMusic: @Sendable () async -> MusicAuthorization.Status
    private let findReleaseDate: @Sendable (String) async throws -> Date?
    private var analytics: (any AnalyticsService)?
    private var requestPolicy = ProviderRequestPolicy()
    private let log = AppLogger.api

    static let defaultPolicy: TokenBucketRateLimiter.Policy = {
        guard let refillMilliseconds = APIRateLimits.refillMilliseconds(
            requests: APIRateLimits.defaultITunesPerSecond,
            perSeconds: 1
        ) else {
            preconditionFailure("Default iTunes rate limit must be valid")
        }
        return .init(maxTokens: 1, refillInterval: .milliseconds(refillMilliseconds))
    }()

    public init(
        session: URLSession = .shared,
        countryCode: String = "US",
        entity: String = "album",
        limit: Int = 200,
        iTunesConfiguration: ITunesSearchConfiguration = ITunesSearchConfiguration(),
        lookupFallbackEnabled: Bool = true,
        rawRequestCache: RawAPIRequestCache? = nil
    ) {
        self.init(
            session: session,
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            iTunesConfiguration: iTunesConfiguration,
            lookupFallbackEnabled: lookupFallbackEnabled,
            rawRequestCache: rawRequestCache,
            rateLimiter: nil,
            dateProvider: { Date() },
            authorizeMusic: { await MusicAuthorization.request() },
            findReleaseDate: Self.findReleaseDate
        )
    }

    /// Creates a catalog client whose iTunes requests use an explicit pacing policy.
    public static func paced(
        settings: ITunesSearchConfig,
        rateLimiter: TokenBucketRateLimiter,
        session: URLSession = .shared,
        rawRequestCache: RawAPIRequestCache? = nil
    ) -> Self {
        paced(
            settings: settings,
            rateLimiter: rateLimiter,
            session: session,
            rawRequestCache: rawRequestCache,
            analytics: nil
        )
    }

    /// Creates a paced catalog client that records iTunes transport requests.
    public static func paced(
        settings: ITunesSearchConfig,
        rateLimiter: TokenBucketRateLimiter,
        session: URLSession = .shared,
        rawRequestCache: RawAPIRequestCache? = nil,
        analytics: (any AnalyticsService)?
    ) -> Self {
        Self(
            session: session,
            countryCode: settings.normalizedCountryCode,
            entity: settings.entity,
            limit: settings.clampedLimit,
            lookupFallbackEnabled: settings.lookupFallbackEnabled,
            rawRequestCache: rawRequestCache
        )
        .paced(rateLimiter)
        .withAnalytics(analytics)
    }

    init(
        session: URLSession = .shared,
        countryCode: String = "US",
        entity: String = "album",
        limit: Int = 200,
        iTunesConfiguration: ITunesSearchConfiguration = ITunesSearchConfiguration(),
        lookupFallbackEnabled: Bool = true,
        rawRequestCache: RawAPIRequestCache? = nil,
        rateLimiter: TokenBucketRateLimiter? = nil,
        dateProvider: @escaping @Sendable () -> Date,
        authorizeMusic: @escaping @Sendable () async -> MusicAuthorization.Status = {
            await MusicAuthorization.request()
        },
        findReleaseDate: @escaping @Sendable (String) async throws -> Date? = Self.findReleaseDate
    ) {
        self.session = session
        self.rawRequestCache = rawRequestCache
        self.rateLimiter = rateLimiter ?? Self.defaultLimiter()
        self.countryCode = countryCode
        self.entity = entity
        self.limit = min(max(limit, 1), 200)
        self.iTunesConfiguration = iTunesConfiguration
        self.lookupFallbackEnabled = lookupFallbackEnabled
        self.dateProvider = dateProvider
        self.authorizeMusic = authorizeMusic
        self.findReleaseDate = findReleaseDate
        self.analytics = nil
    }

    // MARK: - ExternalAPIService

    /// Search the Apple Music catalog for album year and genre data.
    ///
    /// Performs a `MusicCatalogSearchRequest` combining artist and album name.
    /// Returns a `YearResult` with confidence 70 when a matching album is found,
    /// or an empty result when no match exists. Authorization and request
    /// failures are thrown so callers do not cache them as confirmed misses.
    ///
    /// - Parameters:
    ///   - artist: The artist name to search for.
    ///   - album: The album name to search for.
    ///   - currentLibraryYear: The year currently set in the user's library (unused).
    ///   - earliestTrackAddedYear: The earliest year a track was added (unused).
    /// - Returns: A `YearResult` with the album's release year and confidence.
    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        let authorizationStatus = await authorizeMusic()
        guard authorizationStatus == .authorized else {
            log.info("MusicKit not authorized; Apple Music catalog search failed")
            throw CatalogSearchError.authorizationRequired
        }

        guard let releaseDate = try await requestPolicy.performClientRequest(operation: .appleMusicCatalogSearch, {
            try await findReleaseDate("\(artist) \(album)")
        }) else {
            log.debug(
                "No Apple Music results for \(artist, privacy: .private) - \(album, privacy: .private)"
            )
            return YearResult()
        }

        let year = Calendar.current.component(.year, from: releaseDate)

        log.debug(
            "Apple Music: \(artist, privacy: .private) - \(album, privacy: .private) -> year=\(year, privacy: .public)"
        )

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: 70,
            yearScores: [year: 70]
        )
    }

    /// Return iTunes Search API album candidates for parity year scoring.
    public func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        let scoringYear = utcYear(at: dateProvider())
        guard let searchURL = Self.buildITunesSearchURL(
            term: "\(artist) \(album)",
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            configuration: iTunesConfiguration
        ) else {
            return []
        }

        let searchResults = try await fetchITunesResults(from: searchURL)
        let directCandidates = Self.candidates(
            from: searchResults,
            artist: artist,
            album: album,
            scoringYear: scoringYear
        )
        if !directCandidates.isEmpty || !lookupFallbackEnabled {
            return directCandidates
        }

        guard let artistID = try await findArtistID(artist: artist) else {
            return []
        }
        let lookupResults = try await lookupArtistAlbums(artistID: artistID)
        return Self.candidates(
            from: lookupResults,
            artist: artist,
            album: album,
            scoringYear: scoringYear
        )
    }

    /// MusicKit does not expose structured artist activity periods.
    ///
    /// Always returns `(nil, nil)`.
    public func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    /// MusicKit does not expose artist career start year.
    ///
    /// Uses the public iTunes Search API as a parity fallback with the Python
    /// implementation, taking the earliest matching album release year.
    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        guard let url = Self.buildArtistAlbumsSearchURL(
            artist: normalizedArtist,
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            configuration: iTunesConfiguration
        ) else {
            log.warning("Failed to build iTunes artist albums URL for \(normalizedArtist, privacy: .private)")
            return nil
        }

        let results = try await fetchITunesResults(from: url)
        let artist = normalizeForMatching(normalizedArtist)
        let years = results.compactMap { result in
            Self.releaseYear(from: result, normalizedArtist: artist)
        }

        return years.min()
    }

    /// No initialization required — MusicKit manages its own state.
    public func initialize(force _: Bool) async throws {
        // No-op: MusicKit handles initialization internally
    }

    /// No cleanup required — MusicKit manages its own connections.
    public func close() async {
        // No-op: no persistent connections to close
    }

    /// Returns a copy whose individual MusicKit and iTunes requests use the supplied timeout.
    public func withRequestTimeout(seconds: TimeInterval) -> Self {
        var copy = self
        copy.requestPolicy = ProviderRequestPolicy(timeoutSeconds: seconds)
        return copy
    }

    // MARK: - Private

    private static func findReleaseDate(for term: String) async throws -> Date? {
        var request = MusicCatalogSearchRequest(term: term, types: [Album.self])
        request.limit = 5
        return try await request.response().albums.first?.releaseDate
    }

    private static func defaultLimiter() -> TokenBucketRateLimiter {
        TokenBucketRateLimiter(
            maxTokens: defaultPolicy.maxTokens,
            refillInterval: defaultPolicy.refillInterval
        )
    }

    private func paced(_ rateLimiter: TokenBucketRateLimiter) -> Self {
        var copy = Self(
            session: session,
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            iTunesConfiguration: iTunesConfiguration,
            lookupFallbackEnabled: lookupFallbackEnabled,
            rawRequestCache: rawRequestCache,
            rateLimiter: rateLimiter,
            dateProvider: dateProvider,
            authorizeMusic: authorizeMusic,
            findReleaseDate: findReleaseDate
        )
        copy.requestPolicy = requestPolicy
        return copy
    }

    static func buildArtistAlbumsSearchURL(
        artist: String,
        countryCode: String,
        entity: String = "album",
        limit: Int = 200,
        configuration: ITunesSearchConfiguration = ITunesSearchConfiguration()
    ) -> URL? {
        let searchEntity = entity.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedLimit = min(max(limit, 1), 200)
        var components = URLComponents()
        components.scheme = configuration.scheme
        components.host = configuration.host
        components.path = configuration.searchPath
        components.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "entity", value: searchEntity.isEmpty ? "album" : searchEntity),
            URLQueryItem(name: "limit", value: String(clampedLimit)),
        ]
        return components.url
    }

    static func buildITunesSearchURL(
        term: String,
        countryCode: String,
        entity: String,
        limit: Int,
        configuration: ITunesSearchConfiguration = ITunesSearchConfiguration()
    ) -> URL? {
        buildArtistAlbumsSearchURL(
            artist: term,
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            configuration: configuration
        )
    }

    private func fetchITunesResults(from url: URL) async throws -> [ITunesAlbumResult] {
        let data = try await fetchITunesData(from: url)
        return try JSONDecoder().decode(
            ITunesArtistAlbumsResponse.self,
            from: data
        ).results
    }

    private func fetchITunesData(from url: URL) async throws -> Data {
        guard let rawRequestCache else {
            return try await performITunesFetch(from: url)
        }
        return try await rawRequestCache.data(api: "itunes", url: url) {
            try await performITunesFetch(from: url)
        }
    }

    private func performITunesFetch(from url: URL) async throws -> Data {
        guard let analytics else {
            return try await performITunesFetchBody(from: url)
        }
        return try await analytics.measure(.iTunesReleaseSearch) {
            try await performITunesFetchBody(from: url)
        }
    }

    private func performITunesFetchBody(from url: URL) async throws -> Data {
        _ = try await rateLimiter.acquireCancellable()
        let request = requestPolicy.request(for: url)
        let (data, response) = try await requestPolicy.performClientRequest(
            operation: ProviderRequestOperation(.iTunesReleaseSearch)
        ) {
            try await session.data(for: request)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            log.warning("iTunes request returned a non-HTTP response")
            throw ITunesSearchError.nonHTTPResponse
        }

        guard httpResponse.statusCode == 200 else {
            log.warning("iTunes request returned HTTP \(httpResponse.statusCode, privacy: .public)")
            throw ITunesSearchError.unsuccessfulStatusCode(httpResponse.statusCode)
        }

        return data
    }

    private func withAnalytics(_ analytics: (any AnalyticsService)?) -> Self {
        var copy = self
        copy.analytics = analytics
        return copy
    }

    private func findArtistID(artist: String) async throws -> Int? {
        guard let url = Self.buildITunesSearchURL(
            term: artist,
            countryCode: countryCode,
            entity: "musicArtist",
            limit: 5,
            configuration: iTunesConfiguration
        ) else {
            return nil
        }

        let results = try await fetchITunesResults(from: url)
        let normalizedArtist = normalizeForMatching(artist)
        return results.first {
            normalizeForMatching($0.artistName ?? "") == normalizedArtist
        }?.artistID
    }

    private func lookupArtistAlbums(artistID: Int) async throws -> [ITunesAlbumResult] {
        var components = URLComponents()
        components.scheme = iTunesConfiguration.scheme
        components.host = iTunesConfiguration.host
        components.path = iTunesConfiguration.lookupPath
        components.queryItems = [
            URLQueryItem(name: "id", value: String(artistID)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { return [] }
        return try await fetchITunesResults(from: url)
    }

    private static func candidates(
        from results: [ITunesAlbumResult],
        artist: String,
        album: String,
        scoringYear: Int
    ) -> [ReleaseCandidate] {
        let normalizedArtist = normalizeForMatching(artist)
        let normalizedAlbum = normalizeForMatching(album)

        return results.compactMap { result in
            let resultArtist = normalizeForMatching(result.artistName ?? "")
            let resultAlbum = normalizeForMatching(result.collectionName ?? "")
            // An empty query artist is the album-only alternative search
            // (Various Artists parity) — album equality carries the match.
            let artistMatches = normalizedArtist.isEmpty || resultArtist == normalizedArtist
            guard artistMatches,
                  resultAlbum == normalizedAlbum,
                  let year = year(from: result)
            else {
                return nil
            }

            return ReleaseCandidate(
                artist: result.artistName ?? artist,
                album: result.collectionName ?? album,
                year: year,
                source: .itunes,
                releaseType: .album,
                status: .official,
                country: result.country?.lowercased(),
                isReissue: year >= scoringYear - 1
            )
        }
    }

    private func utcYear(at date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.year, from: date)
    }

    private static func releaseYear(
        from result: ITunesAlbumResult,
        normalizedArtist: String
    ) -> Int? {
        let resultArtist = normalizeForMatching(result.artistName ?? "")
        guard !resultArtist.isEmpty,
              resultArtist.contains(normalizedArtist) || normalizedArtist.contains(resultArtist)
        else {
            return nil
        }

        return year(from: result)
    }

    private static func year(from result: ITunesAlbumResult) -> Int? {
        guard let releaseDate = result.releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              releaseDate.count >= 4 else { return nil }
        let yearPrefix = releaseDate.prefix(4)
        guard yearPrefix.allSatisfy(\.isNumber) else { return nil }
        return Int(yearPrefix)
    }
}

public struct ITunesSearchConfiguration: Sendable {
    public let scheme: String
    public let host: String
    public let searchPath: String
    public let lookupPath: String

    public init(
        scheme: String = CatalogSearchClient.defaultITunesScheme,
        host: String = CatalogSearchClient.defaultITunesHost,
        searchPath: String = Self.endpointPath("search"),
        lookupPath: String = Self.endpointPath("lookup")
    ) {
        self.scheme = Self.resolved(scheme, fallback: CatalogSearchClient.defaultITunesScheme)
        self.host = Self.resolved(host, fallback: CatalogSearchClient.defaultITunesHost)
        self.searchPath = Self.resolvedEndpointPath(searchPath, fallback: Self.endpointPath("search"))
        self.lookupPath = Self.resolvedEndpointPath(lookupPath, fallback: Self.endpointPath("lookup"))
    }

    public static func endpointPath(_ endpoint: String) -> String {
        "/" + endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolved(_ value: String, fallback: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? fallback : trimmedValue
    }

    private static func resolvedEndpointPath(_ path: String, fallback: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return fallback }
        if trimmedPath.hasPrefix("/") {
            return trimmedPath
        }
        return "/" + trimmedPath
    }
}

private struct ITunesArtistAlbumsResponse: Decodable {
    let results: [ITunesAlbumResult]
}

private struct ITunesAlbumResult: Decodable {
    let artistName: String?
    let collectionName: String?
    let releaseDate: String?
    let artistID: Int?
    let country: String?

    private enum CodingKeys: String, CodingKey {
        case artistName
        case collectionName
        case releaseDate
        case artistID = "artistId"
        case country
    }
}

private enum ITunesSearchError: LocalizedError {
    case nonHTTPResponse
    case unsuccessfulStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "iTunes request returned a non-HTTP response"
        case let .unsuccessfulStatusCode(statusCode):
            "iTunes request returned HTTP \(statusCode)"
        }
    }
}
