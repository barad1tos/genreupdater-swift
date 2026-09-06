import Core
import Foundation
import OSLog

private enum ArtistRegionCache {
    static let positiveTTL: TimeInterval = 31_536_000
    static let negativeTTL: TimeInterval = 86400
    /// Regions are non-empty names; the empty string marks a confirmed miss.
    static let notFoundSentinel = ""
}

extension APIOrchestrator {
    /// The artist's region name for release-country scoring (Python
    /// orchestrator parity: fetched once per album lookup, cached per
    /// artist). Memoized like the start year — a year positive, a day
    /// negative — because Python leaned on its eternal raw request cache
    /// for the same effect.
    public func getArtistRegion(
        normalizedArtist: String
    ) async -> String? {
        let cacheKey = "artist_region:\(normalizedArtist)"
        if let cachedRegion: String = await cache?.get(key: cacheKey) {
            return cachedRegion == ArtistRegionCache.notFoundSentinel ? nil : cachedRegion
        }

        do {
            let region = try await providerAdmission.execute {
                try await self.musicBrainz.getArtistRegion(artist: normalizedArtist)
            }
            await cache?.set(
                key: cacheKey,
                value: region ?? ArtistRegionCache.notFoundSentinel,
                ttl: region == nil ? ArtistRegionCache.negativeTTL : ArtistRegionCache.positiveTTL
            )
            return region
        } catch {
            // A transient failure is NOT an absence: cache nothing so the
            // next album retries as soon as MusicBrainz recovers.
            AppLogger.api.warning(
                "Artist region lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
