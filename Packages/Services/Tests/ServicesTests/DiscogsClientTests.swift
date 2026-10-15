// DiscogsClientTests.swift — Unit tests for Discogs API client
// Phase 4: API + Cache

import Foundation
import Security
import Testing
@testable import Core
@testable import Services

// MARK: - DiscogsClientTests

@Suite("DiscogsClient — Discogs API JSON parsing and URL building")
struct DiscogsClientTests {
    @Test("Saving a credential advances its revision")
    func saveAdvancesRevision() throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        let initial = DiscogsClient.credentialRevision(defaults: defaults)
        let keychain = InMemoryKeychainOperations()

        _ = try DiscogsClient.saveToken(
            "saved-token",
            keychain: KeychainHelper(operationHooks: keychain.hooks),
            defaults: defaults
        )

        #expect(DiscogsClient.credentialRevision(defaults: defaults) != initial)
    }

    @Test("Rejected credential save preserves its revision")
    func failedSaveIsStable() throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        let initial = DiscogsClient.credentialRevision(defaults: defaults)
        let status = errSecUserCanceled
        let hooks = KeychainOperationHooks(
            addItem: { _ in status },
            copyMatching: { _, _ in errSecItemNotFound },
            deleteItem: { _ in errSecItemNotFound }
        )

        #expect(throws: KeychainError.authenticationFailed(status)) {
            try DiscogsClient.saveToken(
                "saved-token",
                keychain: KeychainHelper(operationHooks: hooks),
                defaults: defaults
            )
        }
        #expect(DiscogsClient.credentialRevision(defaults: defaults) == initial)
    }

    @Test("Deleting a saved credential advances its revision")
    func deleteAdvancesRevision() throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "saved-token",
            service: DiscogsClient.keychainService,
            account: DiscogsClient.keychainAccount,
            isAccessControlled: true
        )
        let initial = DiscogsClient.credentialRevision(defaults: defaults)

        try DiscogsClient.deleteSavedToken(
            keychain: KeychainHelper(operationHooks: keychain.hooks),
            defaults: defaults
        )
        let advanced = DiscogsClient.credentialRevision(defaults: defaults)

        #expect(advanced != initial)
        #expect(DiscogsClient.credentialRevision(defaults: defaults) == advanced)
    }

    @Test("Rejected credential deletion preserves its revision")
    func failedDeleteIsStable() throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        let initial = DiscogsClient.credentialRevision(defaults: defaults)
        let status = errSecUserCanceled
        let hooks = KeychainOperationHooks(
            addItem: { _ in errSecSuccess },
            copyMatching: { _, _ in errSecItemNotFound },
            deleteItem: { _ in status }
        )

        #expect(throws: KeychainError.authenticationFailed(status)) {
            try DiscogsClient.deleteSavedToken(
                keychain: KeychainHelper(operationHooks: hooks),
                defaults: defaults
            )
        }
        #expect(DiscogsClient.credentialRevision(defaults: defaults) == initial)
    }

    @Test("Partial credential deletion advances its revision", arguments: [
        [errSecSuccess, errSecUserCanceled],
        [errSecUserCanceled, errSecSuccess],
    ])
    func partialDeleteInvalidates(statuses: [OSStatus]) throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        let initial = DiscogsClient.credentialRevision(defaults: defaults)
        var remainingStatuses = statuses
        let hooks = KeychainOperationHooks(
            addItem: { _ in errSecSuccess },
            copyMatching: { _, _ in errSecItemNotFound },
            deleteItem: { _ in remainingStatuses.removeFirst() }
        )

        #expect(throws: KeychainError.authenticationFailed(errSecUserCanceled)) {
            try DiscogsClient.deleteSavedToken(
                keychain: KeychainHelper(operationHooks: hooks),
                defaults: defaults
            )
        }
        #expect(DiscogsClient.credentialRevision(defaults: defaults) != initial)
    }

    // MARK: - JSON Parsing

    @Test("Parse search response with master release")
    func parseSearchResponse() throws {
        let json = """
        {
            "results": [
                {
                    "id": 1234,
                    "title": "Iron Maiden - Powerslave",
                    "year": "1984",
                    "type": "master",
                    "master_id": 5678,
                    "master_url": "https://api.discogs.com/masters/5678",
                    "genre": ["Rock"],
                    "style": ["Heavy Metal", "NWOBHM"]
                }
            ],
            "pagination": {
                "page": 1,
                "pages": 1,
                "per_page": 50,
                "items": 1
            }
        }
        """

        let response = try JSONDecoder().decode(
            DiscogsSearchResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.results.count == 1)

        let result = response.results[0]
        #expect(result.releaseYear == 1984)
        #expect(result.masterID == 5678)
        #expect(result.style?.contains("Heavy Metal") == true)
    }

    @Test("Parse master release response")
    func parseMasterRelease() throws { // swiftlint:disable:this inclusive_language
        let json = """
        {
            "id": 5678,
            "title": "Powerslave",
            "year": 1984,
            "genres": ["Rock"],
            "styles": ["Heavy Metal", "NWOBHM"],
            "artists": [
                {"id": 1, "name": "Iron Maiden"}
            ]
        }
        """

        let masterRelease = try JSONDecoder().decode( // swiftlint:disable:this inclusive_language
            DiscogsMasterRelease.self,
            from: Data(json.utf8)
        )

        #expect(masterRelease.year == 1984)
        #expect(masterRelease.genres?.contains("Rock") == true)
        #expect(masterRelease.artists?.first?.name == "Iron Maiden")
    }

    @Test("Parse release detail numeric year")
    func parseReleaseDetailNumericYear() throws {
        let json = """
        {
            "id": 42,
            "title": "Powerslave",
            "year": 1984,
            "released": null
        }
        """

        let releaseDetail = try JSONDecoder().decode(
            DiscogsReleaseDetail.self,
            from: Data(json.utf8)
        )

        #expect(releaseDetail.releaseYear == 1984)
    }

    @Test("Parse release detail year from released date")
    func parseReleaseDetailReleasedDateYear() throws {
        let json = """
        {
            "id": 42,
            "title": "Powerslave",
            "year": 0,
            "released": "Released 1984-09-03"
        }
        """

        let releaseDetail = try JSONDecoder().decode(
            DiscogsReleaseDetail.self,
            from: Data(json.utf8)
        )

        #expect(releaseDetail.releaseYear == 1984)
    }

    @Test("Search result handles missing year")
    func searchResultMissingYear() {
        let result = DiscogsSearchResult(
            id: 1,
            title: "Test",
            year: nil,
            type: "master",
            masterID: nil,
            masterURL: nil,
            genre: nil,
            style: nil
        )
        #expect(result.releaseYear == nil)
    }

    // MARK: - URL Building

    @Test("buildSearchURL encodes query correctly")
    func buildSearchURL() throws {
        let url = DiscogsClient.buildSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave"
        )

        #expect(url != nil)

        let urlString = try #require(url?.absoluteString)
        #expect(urlString.contains("database/search"))
        #expect(urlString.contains("type=master"))
        // URLComponents percent-encodes spaces
        #expect(urlString.contains("Iron%20Maiden") || urlString.contains("Iron+Maiden"))
    }

    @Test("buildMasterURL uses correct ID")
    func buildMasterURL() throws { // swiftlint:disable:this inclusive_language
        let url = DiscogsClient.buildMasterURL(releaseID: 5678) // swiftlint:disable:this inclusive_language

        #expect(url != nil)

        let urlString = try #require(url?.absoluteString)
        #expect(urlString.contains("masters/5678"))
    }

    // MARK: - Auth Header

    @Test("Client sets Authorization header when token provided")
    func authorizationHeader() throws {
        let client = DiscogsClient(token: "test-token-123")
        let testURL = try #require(URL(string: "https://api.discogs.com/database/search"))
        let request = client.makeRequest(for: testURL)

        let authorization = request.value(forHTTPHeaderField: "Authorization")
        #expect(authorization == "Discogs token=test-token-123")

        let accept = request.value(forHTTPHeaderField: "Accept")
        #expect(accept == "application/json")

        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        #expect(userAgent != nil)
        #expect(userAgent?.contains("GenreUpdater") == true)
    }
}
