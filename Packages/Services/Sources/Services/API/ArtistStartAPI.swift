import Core
import Foundation
import OSLog

private enum ArtistStartYearCache {
    static let positiveTTL: TimeInterval = 31_536_000
    static let negativeTTL: TimeInterval = 86400
    static let notFoundSentinel = -1
}

extension APIOrchestrator {
    public func getArtistActivityPeriod(
        normalizedArtist: String
    ) async -> (start: Int?, end: Int?) {
        do {
            return try await providerAdmission.execute {
                try await self.musicBrainz.getArtistActivityPeriod(normalizedArtist: normalizedArtist)
            }
        } catch {
            AppLogger.api.warning(
                "MusicBrainz artist activity lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return (nil, nil)
        }
    }

    public func getArtistStartYear(
        normalizedArtist: String
    ) async -> Int? {
        let cacheKey = "artist_start_year:\(normalizedArtist)"
        if let cachedYear: Int = await cache?.get(key: cacheKey) {
            return cachedYear == ArtistStartYearCache.notFoundSentinel ? nil : cachedYear
        }

        let musicBrainzStartYear: Int?
        var hasProviderFailure = false
        do {
            (musicBrainzStartYear, _) = try await providerAdmission.execute {
                try await self.musicBrainz.getArtistActivityPeriod(normalizedArtist: normalizedArtist)
            }
        } catch {
            hasProviderFailure = true
            musicBrainzStartYear = nil
            AppLogger.api.warning(
                "MusicBrainz artist activity lookup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        if let musicBrainzStartYear {
            await cache?.set(
                key: cacheKey,
                value: musicBrainzStartYear,
                ttl: ArtistStartYearCache.positiveTTL
            )
            return musicBrainzStartYear
        }

        do {
            let appleMusicStartYear = try await providerAdmission.execute {
                try await self.appleMusic.getArtistStartYear(normalizedArtist: normalizedArtist)
            }
            if let appleMusicStartYear {
                await cache?.set(
                    key: cacheKey,
                    value: appleMusicStartYear,
                    ttl: ArtistStartYearCache.positiveTTL
                )
                return appleMusicStartYear
            }
        } catch {
            hasProviderFailure = true
            AppLogger.api.warning(
                "Apple Music artist start lookup failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        guard !hasProviderFailure else { return nil }

        await cache?.set(
            key: cacheKey,
            value: ArtistStartYearCache.notFoundSentinel,
            ttl: ArtistStartYearCache.negativeTTL
        )
        return nil
    }
}
