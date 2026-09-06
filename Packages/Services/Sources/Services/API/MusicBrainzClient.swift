// MusicBrainzClient.swift — JSON API client for MusicBrainz metadata
// Phase 4: API + Cache

import Core
import Foundation
import OSLog

// MARK: - MusicBrainzClient

/// MusicBrainz API client for album year and artist activity data.
///
/// Uses JSON format (`&fmt=json`) instead of default XML.
/// Rate limited at 1 request/second per MusicBrainz policy.
/// Requires a descriptive User-Agent header per API terms of service.
///
/// Endpoints used:
/// - `/ws/2/release-group?query=...` — album year, genres/tags
/// - `/ws/2/artist?query=...` — artist activity period (life-span)
public struct MusicBrainzClient: ExternalAPIService, Sendable {
    /// Default public MusicBrainz API endpoint.
    public static let defaultBaseURL = APIAuthConfig.defaultMusicBrainzBaseURL

    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: TokenBucketRateLimiter
    private let baseURL: URL
    private let editionMarkers: [String]
    private let albumSuffixes: [String]
    private let rawRequestCache: RawAPIRequestCache?
    private let analytics: (any AnalyticsService)?
    private var requestPolicy = ProviderRequestPolicy()
    private let log = AppLogger.api

    static let defaultPolicy: TokenBucketRateLimiter.Policy = {
        guard let refillMilliseconds = APIRateLimits.refillMilliseconds(
            requests: APIRateLimits.defaultMusicBrainzPerSecond,
            perSeconds: 1
        ) else {
            preconditionFailure("Default MusicBrainz rate limit must be valid")
        }
        return .init(maxTokens: 1, refillInterval: .milliseconds(refillMilliseconds))
    }()

    #if DEBUG
    private var testHooks: TestHooks?
    #endif

    /// Returns a copy whose individual MusicBrainz requests use the supplied timeout.
    public func withRequestTimeout(seconds: TimeInterval) -> Self {
        var copy = self
        copy.requestPolicy = ProviderRequestPolicy(timeoutSeconds: seconds)
        return copy
    }

    private struct ReleaseGroupFetch {
        let groups: [MBReleaseGroup]
        let failure: (any Error)?
    }

    private struct ArtistNameFetch {
        let name: String?
        let failure: (any Error)?
    }

    private static let luceneTermSyntax = Set<Character>(#"+-&|!(){}[]^"~*?:\/"#)
    private static let luceneOperators: Set<String> = ["AND", "OR", "NOT"]

    #if DEBUG
    struct TestHooks: Sendable {
        let beforeSearchTransition: (@Sendable () async -> Void)?

        init(beforeSearchTransition: (@Sendable () async -> Void)? = nil) {
            self.beforeSearchTransition = beforeSearchTransition
        }
    }
    #endif

    /// Creates a MusicBrainz API client.
    ///
    /// - Parameters:
    ///   - contactEmail: Contact email included in User-Agent header per MusicBrainz policy.
    ///   - session: URL session for network requests. Defaults to `.shared`.
    ///   - rateLimiter: Rate limiter for throttling. Defaults to 1 req/sec.
    ///   - baseURL: Base MusicBrainz API URL.
    ///   - cleaningConfiguration: User-controlled album edition and suffix rules used to validate broad matches.
    ///   - rawRequestCache: Optional cache for raw API responses.
    ///   - analytics: Optional recorder for transport requests that bypass the raw cache.
    public init(
        appName: String = "GenreUpdater/1.0",
        contactEmail: String = "",
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil,
        baseURL: URL = Self.defaultBaseURL,
        cleaningConfiguration: CleaningConfig = CleaningConfig(),
        rawRequestCache: RawAPIRequestCache? = nil,
        analytics: (any AnalyticsService)? = nil
    ) {
        let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAppName = trimmedAppName.isEmpty ? "GenreUpdater/1.0" : trimmedAppName
        if contactEmail.isEmpty {
            self.userAgent = "\(effectiveAppName) (https://github.com/barad1tos/project-genreupdater-swift)"
        } else {
            self.userAgent = "\(effectiveAppName) (\(contactEmail); https://github.com/barad1tos/project-genreupdater-swift)"
        }
        self.session = session
        self.baseURL = baseURL
        self.editionMarkers = cleaningConfiguration.editionMarkers
        self.albumSuffixes = cleaningConfiguration.albumSuffixes
        self.rawRequestCache = rawRequestCache
        self.analytics = analytics
        self.rateLimiter = rateLimiter ?? Self.defaultLimiter()
    }

    private static func defaultLimiter() -> TokenBucketRateLimiter {
        TokenBucketRateLimiter(
            maxTokens: defaultPolicy.maxTokens,
            refillInterval: defaultPolicy.refillInterval
        )
    }

    #if DEBUG
    func withTestHooks(_ hooks: TestHooks) -> Self {
        var client = self
        client.testHooks = hooks
        return client
    }
    #endif

    // MARK: - ExternalAPIService

    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        let releaseGroups = try await searchReleaseGroups(artist: artist, album: album, limit: 5)

        guard let bestMatch = releaseGroups.first,
              let year = bestMatch.releaseYear
        else {
            log.debug("No release group results for \(artist, privacy: .private) - \(album, privacy: .private)")
            return YearResult()
        }

        let confidence = bestMatch.primaryType == "Album" ? 80 : 60

        log.debug(
            "MusicBrainz: \(artist, privacy: .private) - \(album, privacy: .private) -> \(year, privacy: .public) (confidence: \(confidence, privacy: .public))"
        )

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: confidence,
            yearScores: [year: confidence]
        )
    }

    public func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        let releaseGroups = try await searchReleaseGroups(artist: artist, album: album, limit: 10)
        var candidates: [ReleaseCandidate] = []

        for (index, group) in releaseGroups.enumerated() {
            let releases = index < 3 ? try await fetchReleaseDetailsIfAvailable(for: group.id) : []
            candidates.append(contentsOf: Self.releaseCandidates(
                from: group,
                releases: releases,
                queryArtist: artist
            ))
        }

        return candidates
    }

    public func getArtistActivityPeriod(
        normalizedArtist: String
    ) async throws -> (start: Int?, end: Int?) {
        guard let artist = try await fetchFirstArtist(named: normalizedArtist) else {
            log.debug("No artist results for \(normalizedArtist, privacy: .private)")
            return (nil, nil)
        }

        return (artist.lifeSpan?.beginYear, artist.lifeSpan?.endYear)
    }

    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        let (start, _) = try await getArtistActivityPeriod(
            normalizedArtist: normalizedArtist
        )
        return start
    }

    public func initialize(force _: Bool) async throws {
        // No initialization needed — stateless HTTP client
    }

    public func close() async {
        // No cleanup needed — URLSession lifecycle managed externally
    }

    // MARK: - URL Builders

    /// Builds a release group search URL for the given artist and album.
    ///
    /// Query format: `artist:"<artist>" AND releasegroup:"<album>"` with `&fmt=json`.
    static func buildReleaseGroupSearchURL(
        artist: String,
        album: String,
        limit: Int = 5,
        baseURL: URL = Self.defaultBaseURL
    ) -> URL? {
        // An empty artist is the album-only alternative search (Python
        // parity: Various Artists and flagged soundtracks drop the artist).
        let escapedAlbum = escapeLucenePhrase(album)
        let query = artist.isEmpty
            ? "releasegroup:\"\(escapedAlbum)\""
            : "artist:\"\(escapeLucenePhrase(artist))\" AND releasegroup:\"\(escapedAlbum)\""
        return releaseGroupSearchURL(query: query, limit: limit, baseURL: baseURL)
    }

    private static func releaseGroupSearchURL(
        query: String,
        limit: Int,
        baseURL: URL
    ) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("release-group"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return components?.url
    }

    static func buildReleaseSearchURL(
        releaseGroupID: String,
        limit: Int = 100,
        baseURL: URL = Self.defaultBaseURL
    ) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("release"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "release-group", value: releaseGroupID),
            URLQueryItem(name: "inc", value: "media+artist-credits"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return components?.url
    }

    /// Escapes a value for use inside a Lucene quoted phrase.
    ///
    /// A quoted phrase treats every metacharacter literally except `\` and `"`.
    /// Backslash goes first or it would double-escape the quotes added after it.
    ///
    /// Without this, an artist name carrying a quote rewrites the query: a
    /// library entry named `Radiohead" OR artist:"Metallica` returns Metallica,
    /// and with `limit=1` the caller silently adopts the wrong artist's region.
    static func escapeLucenePhrase(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Builds an artist search URL for the given artist name.
    ///
    /// Query format: `artist:"<artist>"` with `&fmt=json`.
    static func buildArtistSearchURL(
        artist: String,
        baseURL: URL = Self.defaultBaseURL
    ) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("artist"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "query",
                value: "artist:\"\(escapeLucenePhrase(artist))\""
            ),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return components?.url
    }

    // MARK: - Request Building

    /// Creates a URLRequest with required MusicBrainz headers.
    ///
    /// Sets `User-Agent` (required by MusicBrainz API policy) and
    /// `Accept: application/json` for JSON responses.
    func makeRequest(for url: URL) -> URLRequest {
        var request = requestPolicy.request(for: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Private

    private func searchReleaseGroups(
        artist: String,
        album: String,
        limit: Int
    ) async throws -> [MBReleaseGroup] {
        let precise = try await fetchGroupOutcome(artist: artist, album: album, limit: limit)
        try await checkSearchCancellation()
        guard precise.groups.isEmpty else { return precise.groups }

        var firstFailure = precise.failure

        if Self.shouldRetryWithCanonicalArtist(for: artist) {
            let canonical = try await fetchArtistOutcome(for: artist)
            try await checkSearchCancellation()
            firstFailure = firstFailure ?? canonical.failure

            if let canonicalArtist = canonical.name {
                let normalizedArtist = normalizeForMatching(artist)
                let normalizedCanonicalArtist = normalizeForMatching(canonicalArtist)
                if !normalizedCanonicalArtist.isEmpty,
                   normalizedCanonicalArtist != normalizedArtist {
                    log.debug(
                        "MusicBrainz canonical fallback for \(artist, privacy: .private) -> \(normalizedCanonicalArtist, privacy: .private)"
                    )
                    try await checkSearchCancellation()
                    let canonicalGroups = try await fetchGroupOutcome(
                        artist: normalizedCanonicalArtist,
                        album: album,
                        limit: limit
                    )
                    try await checkSearchCancellation()
                    if !canonicalGroups.groups.isEmpty {
                        return canonicalGroups.groups
                    }
                    firstFailure = firstFailure ?? canonicalGroups.failure
                }
            }
        }

        try await checkSearchCancellation()
        let fallback = try await fallbackReleaseGroups(artist: artist, album: album, limit: limit)
        if !fallback.groups.isEmpty {
            return fallback.groups
        }
        if let failure = firstFailure ?? fallback.failure {
            throw failure
        }
        return []
    }

    private func fetchGroupOutcome(
        artist: String,
        album: String,
        limit: Int
    ) async throws -> ReleaseGroupFetch {
        do {
            let groups = try await fetchReleaseGroups(artist: artist, album: album, limit: limit)
            return ReleaseGroupFetch(groups: groups, failure: nil)
        } catch {
            try Self.rethrowCancellation(error)
            return ReleaseGroupFetch(groups: [], failure: error)
        }
    }

    private func fetchArtistOutcome(for artist: String) async throws -> ArtistNameFetch {
        do {
            return try await ArtistNameFetch(name: canonicalArtistName(for: artist), failure: nil)
        } catch {
            try Self.rethrowCancellation(error)
            return ArtistNameFetch(name: nil, failure: error)
        }
    }

    private func fetchReleaseGroups(
        artist: String,
        album: String,
        limit: Int
    ) async throws -> [MBReleaseGroup] {
        guard let url = Self.buildReleaseGroupSearchURL(
            artist: artist,
            album: album,
            limit: limit,
            baseURL: baseURL
        ) else {
            log.warning("Failed to build release group search URL for \(artist, privacy: .private)")
            return []
        }

        let data = try await fetchWithRateLimit(url: url, operation: .musicBrainzReleaseSearch)
        return try JSONDecoder().decode(
            MBReleaseGroupSearchResponse.self,
            from: data
        ).releaseGroups
    }

    private func fallbackReleaseGroups(
        artist: String,
        album: String,
        limit: Int
    ) async throws -> ReleaseGroupFetch {
        guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ReleaseGroupFetch(groups: [], failure: nil)
        }

        let genericQuery = "\(Self.escapeLuceneTerm(artist)) \(Self.escapeLuceneTerm(album))"
        let generic = try await fetchGroupOutcome(query: genericQuery, limit: limit)
        try await checkSearchCancellation()
        let matchingGenericGroups = matchingReleaseGroups(generic.groups, artist: artist, album: album)
        guard matchingGenericGroups.isEmpty else {
            return ReleaseGroupFetch(groups: matchingGenericGroups, failure: nil)
        }

        try await checkSearchCancellation()
        let albumOnly = try await fetchGroupOutcome(query: Self.escapeLuceneTerm(album), limit: limit)
        try await checkSearchCancellation()
        let matchingAlbumGroups = matchingReleaseGroups(albumOnly.groups, artist: artist, album: album)
        return ReleaseGroupFetch(
            groups: matchingAlbumGroups,
            failure: generic.failure ?? albumOnly.failure
        )
    }

    private func fetchGroupOutcome(query: String, limit: Int) async throws -> ReleaseGroupFetch {
        do {
            let groups = try await fetchReleaseGroups(query: query, limit: limit)
            return ReleaseGroupFetch(groups: groups, failure: nil)
        } catch {
            try Self.rethrowCancellation(error)
            return ReleaseGroupFetch(groups: [], failure: error)
        }
    }

    private func fetchReleaseGroups(query: String, limit: Int) async throws -> [MBReleaseGroup] {
        guard let url = Self.releaseGroupSearchURL(
            query: query,
            limit: limit,
            baseURL: baseURL
        ) else {
            log.warning("Failed to build release group fallback URL")
            return []
        }

        let data = try await fetchWithRateLimit(url: url, operation: .musicBrainzReleaseSearch)
        return try JSONDecoder().decode(
            MBReleaseGroupSearchResponse.self,
            from: data
        ).releaseGroups
    }

    private func matchingReleaseGroups(
        _ releaseGroups: [MBReleaseGroup],
        artist: String,
        album: String
    ) -> [MBReleaseGroup] {
        let normalizedArtist = Self.normalizedCreditName(artist)
        let normalizedAlbum = normalizedAlbumTitle(album)
        guard !normalizedArtist.isEmpty, !normalizedAlbum.isEmpty else { return [] }
        return releaseGroups.filter {
            Self.groupMatchesArtist($0, normalizedArtist: normalizedArtist)
                && albumTitleMatches($0.title, normalizedAlbum: normalizedAlbum)
        }
    }

    private func albumTitleMatches(_ title: String, normalizedAlbum: String) -> Bool {
        let normalizedTitle = normalizedAlbumTitle(title)
        guard !normalizedTitle.isEmpty else { return false }
        return normalizedTitle == normalizedAlbum
    }

    private func normalizedAlbumTitle(_ title: String) -> String {
        let withoutEditions = removeParenthesesWithKeywords(title, keywords: editionMarkers)
        let withoutSuffixes = stripAlbumSuffixes(withoutEditions, suffixes: albumSuffixes)
        return normalizeForMatching(withoutSuffixes)
    }

    private static func groupMatchesArtist(
        _ releaseGroup: MBReleaseGroup,
        normalizedArtist: String
    ) -> Bool {
        releaseGroup.artistCredits?.contains {
            creditMatchesArtist($0, normalizedArtist: normalizedArtist)
        } == true
    }

    private static func creditMatchesArtist(
        _ credit: MBArtistCredit,
        normalizedArtist: String
    ) -> Bool {
        guard let artist = credit.artist else { return false }
        if normalizedCreditName(artist.name) == normalizedArtist {
            return true
        }
        return artist.aliases?.contains {
            normalizedCreditName($0.name) == normalizedArtist
        } == true
    }

    static func rethrowCancellation(_ error: any Error) throws {
        if error is ProviderRequestTimeout {
            throw error
        }
        let bridgedError = error as NSError
        let cancellationDomain = (CancellationError() as NSError).domain
        if Task.isCancelled ||
            error is CancellationError ||
            (error as? URLError)?.code == .cancelled ||
            bridgedError.domain == cancellationDomain {
            throw CancellationError()
        }
    }

    private func checkSearchCancellation() async throws {
        #if DEBUG
        await testHooks?.beforeSearchTransition?()
        #endif
        try Task.checkCancellation()
    }

    private static func normalizedCreditName(_ name: String?) -> String {
        guard let name else { return "" }
        let foldedName = name
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
        return foldedName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func escapeLuceneTerm(_ term: String) -> String {
        var escaped = ""
        var tokenStart = term.startIndex
        var index = term.startIndex

        while index < term.endIndex {
            guard term[index].isWhitespace else {
                index = term.index(after: index)
                continue
            }

            if tokenStart < index {
                escaped += escapeLuceneToken(String(term[tokenStart ..< index]))
            }
            escaped.append(term[index])
            index = term.index(after: index)
            tokenStart = index
        }

        if tokenStart < term.endIndex {
            escaped += escapeLuceneToken(String(term[tokenStart...]))
        }
        return escaped
    }

    private static func escapeLuceneToken(_ token: String) -> String {
        var escaped = luceneOperators.contains(token) ? "\\" : ""
        for character in token {
            if character == "\\" || luceneTermSyntax.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private func fetchReleases(for releaseGroupID: String) async throws -> [MBRelease] {
        guard let url = Self.buildReleaseSearchURL(
            releaseGroupID: releaseGroupID,
            baseURL: baseURL
        ) else {
            log.warning("Failed to build release search URL for release group \(releaseGroupID, privacy: .public)")
            return []
        }

        let data = try await fetchWithRateLimit(url: url, operation: .musicBrainzReleaseSearch)
        return try JSONDecoder().decode(
            MBReleaseSearchResponse.self,
            from: data
        ).releases
    }

    private func fetchReleaseDetailsIfAvailable(for releaseGroupID: String) async throws -> [MBRelease] {
        do {
            return try await fetchReleases(for: releaseGroupID)
        } catch {
            try Self.rethrowCancellation(error)
            log.debug(
                "MusicBrainz release detail lookup failed for release group \(releaseGroupID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func canonicalArtistName(for artist: String) async throws -> String? {
        try await fetchFirstArtist(named: artist)?.name
    }

    /// Python get_artist_region parity: the first non-empty of
    /// area → begin-area → end-area NAME (a region name, not a code —
    /// the scorer's comparison wart is the ported contract). nil means
    /// the search SUCCEEDED without a region; transport failures THROW
    /// so the memoization layer never caches an outage as an absence.
    public func getArtistRegion(artist: String) async throws -> String? {
        guard let mbArtist = try await fetchFirstArtist(named: artist) else { return nil }
        return Self.artistRegion(from: mbArtist)
    }

    static func artistRegion(from artist: MBArtist) -> String? {
        for area in [artist.area, artist.beginArea, artist.endArea] {
            if let name = area?.name, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func fetchFirstArtist(named artist: String) async throws -> MBArtist? {
        guard let url = Self.buildArtistSearchURL(artist: artist, baseURL: baseURL) else {
            log.warning("Failed to build artist search URL for \(artist, privacy: .private)")
            return nil
        }

        let data = try await fetchWithRateLimit(url: url, operation: .musicBrainzArtistSearch)
        let response = try JSONDecoder().decode(
            MBArtistSearchResponse.self,
            from: data
        )
        return response.artists.first
    }

    private static func shouldRetryWithCanonicalArtist(for artist: String) -> Bool {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return false }

        let script = dominantScript(of: trimmedArtist)
        return script != .latin && script != .unknown
    }

    private static func releaseType(from primaryType: String?) -> ReleaseType {
        switch primaryType?.lowercased() {
        case "single": .single
        case "ep": .ep
        case "compilation": .compilation
        case "live": .live
        default: .album
        }
    }

    private static func releaseCandidates(
        from group: MBReleaseGroup,
        releases: [MBRelease],
        queryArtist: String
    ) -> [ReleaseCandidate] {
        var candidates = groupOnlyCandidate(from: group, queryArtist: queryArtist).map { [$0] } ?? []
        let detailedCandidates = releases.compactMap { release -> ReleaseCandidate? in
            guard let year = group.releaseYear ?? release.releaseYear else { return nil }
            let candidate = ReleaseCandidate(
                artist: queryArtist,
                album: albumTitle(releaseTitle: release.title, groupTitle: group.title),
                year: year,
                source: .musicBrainz,
                releaseType: releaseType(from: group.primaryType),
                status: releaseStatus(from: release.status),
                country: normalizedCountry(release.country),
                isReissue: false,
                mbReleaseGroupID: group.id,
                mbReleaseGroupFirstYear: group.releaseYear
            )
            return candidates.contains(candidate) ? nil : candidate
        }

        candidates.append(contentsOf: detailedCandidates)
        return candidates
    }

    private static func groupOnlyCandidate(
        from group: MBReleaseGroup,
        queryArtist: String
    ) -> ReleaseCandidate? {
        guard let year = group.releaseYear else { return nil }
        return ReleaseCandidate(
            artist: queryArtist,
            album: group.title,
            year: year,
            source: .musicBrainz,
            releaseType: releaseType(from: group.primaryType),
            status: .official,
            isReissue: false,
            mbReleaseGroupID: group.id,
            mbReleaseGroupFirstYear: year
        )
    }

    private static func albumTitle(releaseTitle: String?, groupTitle: String) -> String {
        guard let title = releaseTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return groupTitle
        }
        return title
    }

    private static func normalizedCountry(_ country: String?) -> String? {
        guard let country = country?.trimmingCharacters(in: .whitespacesAndNewlines),
              !country.isEmpty else {
            return nil
        }
        return country.lowercased()
    }

    private static func releaseStatus(from status: String?) -> ReleaseStatus {
        guard let normalizedStatus = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalizedStatus.isEmpty else {
            return .official
        }

        if normalizedStatus == "official" {
            return .official
        }
        if normalizedStatus == "bootleg" {
            return .bootleg
        }
        if normalizedStatus == "pseudo-release" {
            return .pseudoRelease
        }
        if normalizedStatus.contains("promotion") || normalizedStatus.contains("promo") {
            return .promotional
        }
        return .other
    }

    /// Acquires a rate limit token, then performs the HTTP request.
    ///
    /// Handles HTTP status codes: 200 (success), 400 (bad request),
    /// 503 (service unavailable), and all other codes as generic HTTP errors.
    private func fetchWithRateLimit(url: URL, operation: AnalyticsOperation) async throws -> Data {
        guard let rawRequestCache else {
            return try await measuredFetch(url: url, operation: operation)
        }
        return try await rawRequestCache.data(api: "musicbrainz", url: url) {
            try await measuredFetch(url: url, operation: operation)
        }
    }

    private func measuredFetch(url: URL, operation: AnalyticsOperation) async throws -> Data {
        guard let analytics else {
            return try await performRateLimitedFetch(url: url, operation: operation)
        }
        return try await analytics.measure(operation) {
            try await performRateLimitedFetch(url: url, operation: operation)
        }
    }

    private func performRateLimitedFetch(url: URL, operation: AnalyticsOperation) async throws -> Data {
        let waitTime = try await rateLimiter.acquireCancellable()
        if waitTime > .zero {
            log.debug("Rate limited, waited \(waitTime, privacy: .public)")
        }

        let request = makeRequest(for: url)
        let (data, response) = try await requestPolicy.performClientRequest(
            operation: ProviderRequestOperation(operation)
        ) {
            try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MusicBrainzError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 400:
            throw MusicBrainzError.badRequest
        case 503:
            throw MusicBrainzError.serviceUnavailable
        default:
            throw MusicBrainzError.httpError(httpResponse.statusCode)
        }
    }
}
