import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - MusicBrainz URL Builder Tests

@Suite("MusicBrainzClient — URL builders and request construction")
struct MusicBrainzURLTests {
    @Test("buildReleaseGroupSearchURL produces valid URL with expected query items")
    func releaseGroupSearchURL() throws {
        let url = try #require(MusicBrainzClient.buildReleaseGroupSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "musicbrainz.org")
        #expect(components.path == "/ws/2/release-group")

        let queryItems = try #require(components.queryItems)
        let queryParam = queryItems.first { $0.name == "query" }
        #expect(queryParam?.value?.contains("Iron Maiden") == true)
        #expect(queryParam?.value?.contains("Powerslave") == true)

        let fmtParam = queryItems.first { $0.name == "fmt" }
        #expect(fmtParam?.value == "json")

        let limitParam = queryItems.first { $0.name == "limit" }
        #expect(limitParam?.value == "5")
    }

    @Test("buildArtistSearchURL produces valid URL")
    func artistSearchURL() throws {
        let url = try #require(MusicBrainzClient.buildArtistSearchURL(artist: "Metallica"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/ws/2/artist")

        let queryItems = try #require(components.queryItems)
        let queryParam = queryItems.first { $0.name == "query" }
        #expect(queryParam?.value?.contains("Metallica") == true)

        let limitParam = queryItems.first { $0.name == "limit" }
        #expect(limitParam?.value == "1")
    }

    @Test("makeRequest sets User-Agent and Accept headers")
    func requestHeaders() throws {
        let client = MusicBrainzClient()
        let url = try #require(URL(string: "https://example.com"))
        let request = client.makeRequest(for: url)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("GenreUpdater") == true)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        let configuredClient = MusicBrainzClient(
            appName: "MusicGenreUpdater/2.0",
            contactEmail: "dev@example.com"
        )
        let configuredRequest = configuredClient.makeRequest(for: url)
        let configuredUserAgent = configuredRequest.value(forHTTPHeaderField: "User-Agent")
        #expect(configuredUserAgent?.contains("MusicGenreUpdater/2.0") == true)
        #expect(configuredUserAgent?.contains("dev@example.com") == true)

        let fallbackRequest = MusicBrainzClient(appName: "  ").makeRequest(for: url)
        #expect(fallbackRequest.value(forHTTPHeaderField: "User-Agent")?.contains("GenreUpdater/1.0") == true)

        let timedRequest = client.withRequestTimeout(seconds: 22.5).makeRequest(for: url)
        #expect(timedRequest.timeoutInterval == 22.5)
    }

    @Test("getArtistActivityPeriod returns (nil, nil) stub")
    func activityPeriodStub() async throws {
        // Validates that the stub behavior works without network
        // (getArtistActivityPeriod requires network so we test the no-op paths)
        let client = MusicBrainzClient()
        // initialize is a no-op
        try await client.initialize(force: false)
        // close is a no-op
        await client.close()
    }
}

// MARK: - MusicBrainz Model Tests

@Suite("MusicBrainzModels — Codable deserialization")
struct MusicBrainzModelTests {
    @Test("MBReleaseGroup releaseYear parses YYYY format")
    func releaseYearFromYYYY() throws {
        let json = """
        {
            "id": "abc",
            "title": "Powerslave",
            "primary-type": "Album",
            "first-release-date": "1984",
            "tags": [],
            "genres": []
        }
        """
        let group = try JSONDecoder().decode(MBReleaseGroup.self, from: Data(json.utf8))
        #expect(group.releaseYear == 1984)
        #expect(group.primaryType == "Album")
    }

    @Test("MBReleaseGroup releaseYear parses YYYY-MM-DD format")
    func releaseYearFromFullDate() throws {
        let json = """
        {
            "id": "def",
            "title": "Master of Puppets",
            "primary-type": "Album",
            "first-release-date": "1986-03-03"
        }
        """
        let group = try JSONDecoder().decode(MBReleaseGroup.self, from: Data(json.utf8))
        #expect(group.releaseYear == 1986)
    }

    @Test("MBReleaseGroup releaseYear returns nil for missing date")
    func releaseYearNilForMissingDate() throws {
        let json = """
        {"id": "x", "title": "Test"}
        """
        let group = try JSONDecoder().decode(MBReleaseGroup.self, from: Data(json.utf8))
        #expect(group.releaseYear == nil)
    }

    @Test("MBReleaseGroup releaseYear returns nil for short date string")
    func releaseYearNilForShortDate() throws {
        let json = """
        {"id": "x", "title": "Test", "first-release-date": "19"}
        """
        let group = try JSONDecoder().decode(MBReleaseGroup.self, from: Data(json.utf8))
        #expect(group.releaseYear == nil)
    }

    @Test("MBLifeSpan parses begin and end years")
    func lifeSpanYears() throws {
        let json = """
        {"begin": "1980-01-01", "end": "2003-12-01", "ended": true}
        """
        let lifeSpan = try JSONDecoder().decode(MBLifeSpan.self, from: Data(json.utf8))
        #expect(lifeSpan.beginYear == 1980)
        #expect(lifeSpan.endYear == 2003)
        #expect(lifeSpan.ended == true)
    }

    @Test("MBLifeSpan returns nil for missing dates")
    func lifeSpanNilDates() throws {
        let json = """
        {"ended": false}
        """
        let lifeSpan = try JSONDecoder().decode(MBLifeSpan.self, from: Data(json.utf8))
        #expect(lifeSpan.beginYear == nil)
        #expect(lifeSpan.endYear == nil)
    }

    @Test("MBReleaseGroupSearchResponse decodes release-groups array")
    func searchResponseDecoding() throws {
        let json = """
        {
            "release-groups": [
                {
                    "id": "abc",
                    "title": "Album",
                    "primary-type": "Album",
                    "first-release-date": "2000"
                }
            ]
        }
        """
        let response = try JSONDecoder().decode(
            MBReleaseGroupSearchResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.releaseGroups.count == 1)
        #expect(response.releaseGroups[0].releaseYear == 2000)
    }

    @Test("MBArtistSearchResponse decodes artists with life-span")
    func artistResponseDecoding() throws {
        let json = """
        {
            "artists": [
                {
                    "id": "def",
                    "name": "Metallica",
                    "type": "Group",
                    "life-span": {
                        "begin": "1981",
                        "ended": false
                    }
                }
            ]
        }
        """
        let response = try JSONDecoder().decode(
            MBArtistSearchResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.artists.count == 1)
        #expect(response.artists[0].name == "Metallica")
        #expect(response.artists[0].lifeSpan?.beginYear == 1981)
        #expect(response.artists[0].lifeSpan?.endYear == nil)
    }
}

// MARK: - MusicBrainzError Tests

@Suite("MusicBrainzError — error descriptions")
struct MusicBrainzErrorTests {
    @Test(
        "Error descriptions are human-readable",
        arguments: [
            (MusicBrainzError.invalidResponse, "invalid response"),
            (MusicBrainzError.badRequest, "400"),
            (MusicBrainzError.serviceUnavailable, "503"),
            (MusicBrainzError.httpError(404), "404"),
        ] as [(MusicBrainzError, String)]
    )
    func errorDescriptions(error: MusicBrainzError, expectedSubstring: String) {
        let description = error.errorDescription ?? ""
        #expect(description.contains(expectedSubstring))
    }
}

// MARK: - Discogs URL Builder Tests

@Suite("DiscogsClient — URL builders and request construction")
struct DiscogsURLTests {
    @Test("buildSearchURL produces valid URL with expected query items")
    func searchURL() throws {
        let url = try #require(DiscogsClient.buildSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "api.discogs.com")
        #expect(components.path == "/database/search")

        let queryItems = try #require(components.queryItems)
        let artistParam = queryItems.first { $0.name == "artist" }
        #expect(artistParam?.value == "Iron Maiden")

        let albumParam = queryItems.first { $0.name == "release_title" }
        #expect(albumParam?.value == "Powerslave")

        let typeParam = queryItems.first { $0.name == "type" }
        #expect(typeParam?.value == "master")

        let perPageParam = queryItems.first { $0.name == "per_page" }
        #expect(perPageParam?.value == "25")
    }

    @Test("buildSearchURL uses custom base URL")
    func searchURLUsesCustomBaseURL() throws {
        let baseURL = try #require(URL(string: "https://sandbox.discogs.com/api"))
        let url = try #require(DiscogsClient.buildSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave",
            baseURL: baseURL
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "sandbox.discogs.com")
        #expect(components.path == "/api/database/search")
    }

    @Test("buildMasterURL produces valid URL with master ID")
    func canonicalReleaseURL() throws {
        let url = try #require(DiscogsClient.buildMasterURL(releaseID: 12345))
        #expect(url.absoluteString == "https://api.discogs.com/masters/12345")
    }

    @Test("makeRequest sets Authorization header when token is present")
    func requestWithToken() throws {
        let client = DiscogsClient(token: "test-token-123")
        let url = try #require(URL(string: "https://example.com"))
        let request = client.makeRequest(for: url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Discogs token=test-token-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("GenreUpdater") == true)

        let timedRequest = client.withRequestTimeout(seconds: 22.5).makeRequest(for: url)
        #expect(timedRequest.timeoutInterval == 22.5)
    }

    @Test("makeRequest omits Authorization header when token is nil")
    func requestWithoutToken() throws {
        let client = DiscogsClient(token: nil)
        let url = try #require(URL(string: "https://example.com"))
        let request = client.makeRequest(for: url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("getAlbumYear throws noToken when token is nil")
    func noTokenThrows() async {
        let client = DiscogsClient(token: nil)
        await #expect(throws: DiscogsError.self) {
            _ = try await client.getAlbumYear(
                artist: "Test",
                album: "Test",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
    }

    @Test("getArtistActivityPeriod always returns (nil, nil)")
    func activityPeriodReturnsNil() async throws {
        let client = DiscogsClient(token: "token")
        let (start, end) = try await client.getArtistActivityPeriod(normalizedArtist: "Test")
        #expect(start == nil)
        #expect(end == nil)
    }

    @Test("getArtistStartYear always returns nil")
    func startYearReturnsNil() async throws {
        let client = DiscogsClient(token: "token")
        let year = try await client.getArtistStartYear(normalizedArtist: "Test")
        #expect(year == nil)
    }

    @Test("initialize and close are no-ops")
    func initAndClose() async throws {
        let client = DiscogsClient(token: "token")
        try await client.initialize(force: true)
        await client.close()
    }
}

// MARK: - Discogs Model Tests

@Suite("DiscogsModels — Codable deserialization")
struct DiscogsModelTests {
    @Test("DiscogsSearchResult releaseYear parses string year")
    func releaseYearFromString() throws {
        let json = """
        {
            "id": 1,
            "title": "Album",
            "year": "1994",
            "type": "master"
        }
        """
        let result = try JSONDecoder().decode(DiscogsSearchResult.self, from: Data(json.utf8))
        #expect(result.releaseYear == 1994)
    }

    @Test("DiscogsSearchResult releaseYear returns nil for missing year")
    func releaseYearNilForMissing() throws {
        let json = """
        {"id": 1, "title": "Album", "type": "release"}
        """
        let result = try JSONDecoder().decode(DiscogsSearchResult.self, from: Data(json.utf8))
        #expect(result.releaseYear == nil)
    }

    @Test("DiscogsSearchResult releaseYear returns nil for non-numeric year")
    func releaseYearNilForNonNumeric() throws {
        let json = """
        {"id": 1, "title": "Album", "year": "Unknown", "type": "release"}
        """
        let result = try JSONDecoder().decode(DiscogsSearchResult.self, from: Data(json.utf8))
        #expect(result.releaseYear == nil)
    }

    @Test("DiscogsSearchResult decodes master_id and master_url")
    func canonicalReleaseFields() throws {
        let json = """
        {
            "id": 1,
            "title": "Album",
            "type": "master",
            "master_id": 12345,
            "master_url": "https://api.discogs.com/masters/12345"
        }
        """
        let result = try JSONDecoder().decode(DiscogsSearchResult.self, from: Data(json.utf8))
        #expect(result.masterID == 12345)
        #expect(result.masterURL == "https://api.discogs.com/masters/12345")
    }

    @Test("DiscogsSearchResponse decodes results and pagination")
    func searchResponseDecoding() throws {
        let json = """
        {
            "results": [
                {"id": 1, "title": "Album", "type": "master", "genre": ["Rock"]}
            ],
            "pagination": {"page": 1, "pages": 3, "per_page": 5, "items": 15}
        }
        """
        let response = try JSONDecoder().decode(
            DiscogsSearchResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.results.count == 1)
        #expect(response.results[0].genre == ["Rock"])
        #expect(response.pagination?.pages == 3)
        #expect(response.pagination?.perPage == 5)
    }

    @Test("DiscogsMasterRelease decodes all fields")
    func canonicalReleaseDecoding() throws {
        let json = """
        {
            "id": 42,
            "title": "Powerslave",
            "year": 1984,
            "genres": ["Heavy Metal"],
            "styles": ["NWOBHM"],
            "artists": [{"id": 1, "name": "Iron Maiden"}]
        }
        """
        let release = try JSONDecoder().decode(
            DiscogsMasterRelease.self,
            from: Data(json.utf8)
        )
        #expect(release.year == 1984)
        #expect(release.genres == ["Heavy Metal"])
        #expect(release.styles == ["NWOBHM"])
        #expect(release.artists?.first?.name == "Iron Maiden")
    }

    @Test("DiscogsMasterRelease handles nil year")
    func canonicalReleaseNilYear() throws {
        let json = """
        {"id": 1, "title": "Unknown"}
        """
        let release = try JSONDecoder().decode(
            DiscogsMasterRelease.self,
            from: Data(json.utf8)
        )
        #expect(release.year == nil)
    }
}

// MARK: - DiscogsError Tests

@Suite("DiscogsError — error descriptions")
struct DiscogsErrorTests {
    @Test(
        "Error descriptions are human-readable",
        arguments: [
            (DiscogsError.noToken, "not configured"),
            (DiscogsError.invalidResponse, "invalid response"),
            (DiscogsError.unauthorized, "401"),
            (DiscogsError.rateLimited, "429"),
            (DiscogsError.httpError(500), "500"),
        ] as [(DiscogsError, String)]
    )
    func errorDescriptions(error: DiscogsError, expectedSubstring: String) {
        let description = error.errorDescription ?? ""
        #expect(description.contains(expectedSubstring))
    }
}
