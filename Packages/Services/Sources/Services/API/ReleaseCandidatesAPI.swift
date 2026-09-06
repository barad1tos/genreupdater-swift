// ReleaseCandidatesAPI.swift — Raw release candidate collection

import Core
import Foundation
import OSLog

extension APIOrchestrator {
    /// Fetch raw release candidates from configured API sources in priority order.
    ///
    /// Candidate fetching mirrors album-year source ordering but does not write
    /// source results into `YearResult` cache. `YearDeterminator` owns scoring
    /// and fallback decisions for these values.
    public func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async -> [ReleaseCandidate] {
        let scoringYear = utcYear(at: dateProvider())
        let standard = await fetchReleaseCandidatesOnce(
            artist: artist,
            album: album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            scoringYear: scoringYear
        )
        guard standard.isEmpty else { return standard }

        // Python _try_alternative_search parity: ONLY an empty standard
        // aggregate earns one retry with the rewritten query — never a
        // first-query rewrite.
        let strategy = detectSearchStrategy(
            artist: artist,
            album: album,
            soundtrackPatterns: soundtrackPatterns,
            variousArtistsNames: variousArtistsNames
        )
        guard strategy.strategy != .normal else { return standard }

        let altArtist = strategy.modifiedArtist ?? ""
        let altAlbum = strategy.modifiedAlbum ?? album
        AppLogger.api.info("""
        Alternative search (\(strategy.strategy.rawValue, privacy: .public)) for \
        \(artist, privacy: .private) - \(album, privacy: .private)
        """)
        return await fetchReleaseCandidatesOnce(
            artist: altArtist,
            album: altAlbum,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            scoringYear: scoringYear
        )
    }

    private func fetchReleaseCandidatesOnce(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?,
        scoringYear: Int
    ) async -> [ReleaseCandidate] {
        let log = AppLogger.api
        if let reachability, await !reachability.isConnected {
            log.info("Skipping API candidate calls: network offline")
            return []
        }

        let serviceBySource: [APISource: any ExternalAPIService] = [
            .musicBrainz: musicBrainz,
            .discogs: discogs,
            .itunes: appleMusic,
        ]
        let searchQuery = makeAPISearchQuery(artist: artist, album: album)
        let orderedSources = sourcePriorityConfiguration.orderedSources(
            artist: searchQuery.artist,
            album: searchQuery.album
        )
        let activeSources = orderedSources.filter { !disabledSources.contains($0) }
        let sources = activeSources.compactMap { source -> (source: APISource, service: any ExternalAPIService)? in
            guard let service = serviceBySource[source] else { return nil }
            return (source, service)
        }
        let query = ReleaseCandidateQuery(
            artist: searchQuery.artist,
            album: searchQuery.album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear
        )
        let sourceRank = Dictionary(uniqueKeysWithValues: activeSources.enumerated().map { ($0.element, $0.offset) })
        let apiRetryConfiguration = apiRetryConfiguration
        let providerAdmission = providerAdmission
        let cacheContext = candidateCacheContext(scoringYear: scoringYear)

        let fetched = await withTaskGroup(
            of: (source: APISource, candidates: [ReleaseCandidate]).self,
            returning: [(source: APISource, candidates: [ReleaseCandidate])].self
        ) { group in
            for sourceEntry in sources {
                group.addTask {
                    let candidates = await cachedOrFetchedReleaseCandidates(
                        sourceEntry: sourceEntry,
                        query: query,
                        cacheContext: cacheContext,
                        apiRetryConfiguration: apiRetryConfiguration,
                        providerAdmission: providerAdmission
                    )
                    return (sourceEntry.source, candidates)
                }
            }

            var collected: [(source: APISource, candidates: [ReleaseCandidate])] = []
            while let result = await group.next() {
                collected.append(result)
            }
            return collected
        }

        return fetched
            .sorted { (sourceRank[$0.source] ?? Int.max) < (sourceRank[$1.source] ?? Int.max) }
            .flatMap(\.candidates)
    }

    private func candidateCacheContext(scoringYear: Int) -> ReleaseCandidateCacheContext {
        ReleaseCandidateCacheContext(
            cache: cache,
            positiveResultTTL: candidateResultTTL,
            negativeResultTTL: negativeResultTTL,
            discogsReissueKeywords: discogsReissueKeywords,
            discogsSearchConfiguration: discogsSearchConfiguration,
            iTunesScoringYear: scoringYear
        )
    }
}

private func cachedOrFetchedReleaseCandidates(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: ReleaseCandidateQuery,
    cacheContext: ReleaseCandidateCacheContext,
    apiRetryConfiguration: APIRetryConfiguration,
    providerAdmission: ProviderAdmission
) async -> [ReleaseCandidate] {
    if let cached = await cachedReleaseCandidates(
        source: sourceEntry.source,
        query: query,
        cacheContext: cacheContext
    ) {
        return classifiedCandidates(
            cached,
            source: sourceEntry.source,
            iTunesScoringYear: cacheContext.iTunesScoringYear
        )
    }

    let outcome = await fetchProviderCandidates(
        sourceEntry: sourceEntry,
        query: query,
        apiRetryConfiguration: apiRetryConfiguration,
        providerAdmission: providerAdmission
    )

    await cacheReleaseCandidates(
        outcome.candidates,
        source: sourceEntry.source,
        query: query,
        cacheContext: cacheContext,
        shouldCacheEmptyResult: outcome.shouldCacheEmptyResult
    )
    return classifiedCandidates(
        outcome.candidates,
        source: sourceEntry.source,
        iTunesScoringYear: cacheContext.iTunesScoringYear
    )
}

private func fetchProviderCandidates(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: ReleaseCandidateQuery,
    apiRetryConfiguration: APIRetryConfiguration,
    providerAdmission: ProviderAdmission
) async -> ReleaseCandidateFetchOutcome {
    let log = AppLogger.api
    do {
        let candidates = try await providerAdmission.execute {
            try await fetchReleaseCandidatesWithRetry(
                sourceEntry: sourceEntry,
                query: query,
                apiRetryConfiguration: apiRetryConfiguration
            )
        }
        return ReleaseCandidateFetchOutcome(candidates: candidates, shouldCacheEmptyResult: true)
    } catch is CancellationError {
        log.debug("\(sourceEntry.source.rawValue, privacy: .public) candidate fetch cancelled")
        return ReleaseCandidateFetchOutcome(candidates: [], shouldCacheEmptyResult: false)
    } catch {
        log
            .error(
                "\(sourceEntry.source.rawValue, privacy: .public) candidate fetch failed: \(error.localizedDescription, privacy: .public)"
            )
        return ReleaseCandidateFetchOutcome(candidates: [], shouldCacheEmptyResult: false)
    }
}

private func fetchReleaseCandidatesWithRetry(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: ReleaseCandidateQuery,
    apiRetryConfiguration: APIRetryConfiguration
) async throws -> [ReleaseCandidate] {
    try await withRetry(
        maxAttempts: apiRetryConfiguration.maxAttempts,
        initialDelay: apiRetryConfiguration.initialDelay
    ) {
        try await sourceEntry.service.getReleaseCandidates(
            artist: query.artist,
            album: query.album,
            currentLibraryYear: query.currentLibraryYear,
            earliestTrackAddedYear: query.earliestTrackAddedYear
        )
    }
}

private func cachedReleaseCandidates(
    source: APISource,
    query: ReleaseCandidateQuery,
    cacheContext: ReleaseCandidateCacheContext
) async -> [ReleaseCandidate]? {
    let cacheKey = releaseCandidateCacheKey(
        source: source,
        query: query,
        discogsReissueKeywords: cacheContext.discogsReissueKeywords,
        discogsSearchConfiguration: cacheContext.discogsSearchConfiguration
    )
    let cachedEntry: CandidateCacheEntry? = await cacheContext.cache?.get(key: cacheKey)
    guard let cachedEntry else { return nil }

    if cachedEntry.candidates.isEmpty,
       !cachedEntry.isCurrentMiss(ttl: cacheContext.negativeResultTTL) {
        do {
            try await cacheContext.cache?.invalidate(key: cacheKey)
        } catch {
            AppLogger.api.warning(
                "Expired release-candidate miss could not be removed for \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
        return nil
    }

    return cachedEntry.candidates.map(\.releaseCandidate)
}

private func cacheReleaseCandidates(
    _ candidates: [ReleaseCandidate],
    source: APISource,
    query: ReleaseCandidateQuery,
    cacheContext: ReleaseCandidateCacheContext,
    shouldCacheEmptyResult: Bool
) async {
    if candidates.isEmpty, !shouldCacheEmptyResult {
        return
    }

    let cacheKey = releaseCandidateCacheKey(
        source: source,
        query: query,
        discogsReissueKeywords: cacheContext.discogsReissueKeywords,
        discogsSearchConfiguration: cacheContext.discogsSearchConfiguration
    )
    let ttl = candidates.isEmpty ? cacheContext.negativeResultTTL : cacheContext.positiveResultTTL
    await cacheContext.cache?.set(
        key: cacheKey,
        value: CandidateCacheEntry(
            candidates: cacheableCandidates(candidates, source: source).map(CachedReleaseCandidate.init)
        ),
        ttl: ttl
    )
}

private func releaseCandidateCacheKey(
    source: APISource,
    query: ReleaseCandidateQuery,
    discogsReissueKeywords: [String],
    discogsSearchConfiguration: DiscogsSearchConfig
) -> String {
    var components = [
        "v3",
        source.rawValue,
        normalizeForMatching(query.artist),
        normalizeForMatching(query.album),
        query.currentLibraryYear.map { "library_year=\($0)" } ?? "library_year=nil",
        query.earliestTrackAddedYear.map { "earliest_added_year=\($0)" } ?? "earliest_added_year=nil",
    ]
    if source == .discogs {
        components.append(reissueRuleComponent(discogsReissueKeywords))
        components.append(discogsAcquisitionComponent(discogsSearchConfiguration))
    }

    return [
        "release_candidates",
        components.map(cacheKeyComponent).joined(separator: "|"),
    ].joined(separator: ":")
}

private func classifiedCandidates(
    _ candidates: [ReleaseCandidate],
    source: APISource,
    iTunesScoringYear: Int
) -> [ReleaseCandidate] {
    let reissueCutoffYear = iTunesScoringYear - 1
    return mapITunesCandidates(candidates, source: source) { $0.year >= reissueCutoffYear }
}

private func cacheableCandidates(
    _ candidates: [ReleaseCandidate],
    source: APISource
) -> [ReleaseCandidate] {
    mapITunesCandidates(candidates, source: source) { _ in false }
}

private func mapITunesCandidates(
    _ candidates: [ReleaseCandidate],
    source: APISource,
    isReissue: (ReleaseCandidate) -> Bool
) -> [ReleaseCandidate] {
    guard source == .itunes else { return candidates }
    return candidates.map { candidate in
        ReleaseCandidate(
            artist: candidate.artist,
            album: candidate.album,
            year: candidate.year,
            source: candidate.source,
            releaseType: candidate.releaseType,
            status: candidate.status,
            country: candidate.country,
            isReissue: isReissue(candidate),
            mbReleaseGroupID: candidate.mbReleaseGroupID,
            mbReleaseGroupFirstYear: candidate.mbReleaseGroupFirstYear,
            genre: candidate.genre
        )
    }
}

private func utcYear(at date: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar.component(.year, from: date)
}

private func reissueRuleComponent(_ keywords: [String]) -> String {
    let normalizedKeywords = normalizedReissueKeywords(keywords)
    return "reissue_rules=" + normalizedKeywords.map(cacheKeyComponent).joined(separator: "|")
}

private func discogsAcquisitionComponent(_ configuration: DiscogsSearchConfig) -> String {
    "discogs_acquisition=\(DiscogsAcquisition.signature(for: configuration))"
}

private func cacheKeyComponent(_ value: String) -> String {
    "\(value.utf8.count):\(value)"
}

private struct ReleaseCandidateQuery {
    let artist: String
    let album: String
    let currentLibraryYear: Int?
    let earliestTrackAddedYear: Int?
}

private struct ReleaseCandidateCacheContext {
    let cache: (any CacheService)?
    let positiveResultTTL: TimeInterval?
    let negativeResultTTL: TimeInterval
    let discogsReissueKeywords: [String]
    let discogsSearchConfiguration: DiscogsSearchConfig
    let iTunesScoringYear: Int
}

private struct ReleaseCandidateFetchOutcome {
    let candidates: [ReleaseCandidate]
    let shouldCacheEmptyResult: Bool
}

private struct CachedReleaseCandidate: Codable {
    let artist: String
    let album: String
    let year: Int
    let source: APISource
    let releaseType: ReleaseType
    let status: ReleaseStatus
    let country: String?
    let isReissue: Bool
    let mbReleaseGroupID: String?
    let mbReleaseGroupFirstYear: Int?
    let genre: String?

    init(_ candidate: ReleaseCandidate) {
        artist = candidate.artist
        album = candidate.album
        year = candidate.year
        source = candidate.source
        releaseType = candidate.releaseType
        status = candidate.status
        country = candidate.country
        isReissue = candidate.isReissue
        mbReleaseGroupID = candidate.mbReleaseGroupID
        mbReleaseGroupFirstYear = candidate.mbReleaseGroupFirstYear
        genre = candidate.genre
    }

    var releaseCandidate: ReleaseCandidate {
        ReleaseCandidate(
            artist: artist,
            album: album,
            year: year,
            source: source,
            releaseType: releaseType,
            status: status,
            country: country,
            isReissue: isReissue,
            mbReleaseGroupID: mbReleaseGroupID,
            mbReleaseGroupFirstYear: mbReleaseGroupFirstYear,
            genre: genre
        )
    }
}

private struct CandidateCacheEntry: Codable {
    let candidates: [CachedReleaseCandidate]
    let storedAt: Date?

    init(candidates: [CachedReleaseCandidate], storedAt: Date = .now) {
        self.candidates = candidates
        self.storedAt = storedAt
    }

    init(from decoder: any Decoder) throws {
        if let legacyCandidates = try? decoder.singleValueContainer().decode([CachedReleaseCandidate].self) {
            candidates = legacyCandidates
            storedAt = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try container.decode([CachedReleaseCandidate].self, forKey: .candidates)
        storedAt = try container.decodeIfPresent(Date.self, forKey: .storedAt)
    }

    func isCurrentMiss(ttl: TimeInterval) -> Bool {
        guard ttl > 0, let storedAt else { return false }
        return Date.now.timeIntervalSince(storedAt) < ttl
    }
}
