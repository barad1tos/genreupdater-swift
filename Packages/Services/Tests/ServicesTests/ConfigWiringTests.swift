import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Runtime config wiring")
struct ConfigWiringTests {
    @Test("API source priorities use script-specific configuration")
    func apiSourcePrioritiesUseScriptConfiguration() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.preferredAPI = .musicbrainz
        configuration.yearRetrieval.scriptAPIPriorities = [
            "cyrillic": ScriptAPIPriority(
                primary: ["itunes", "musicbrainz"],
                fallback: ["discogs"]
            ),
        ]

        let priorities = APISourcePriorityConfiguration(configuration: configuration)

        #expect(
            priorities.orderedSources(
                artist: "Паліндром",
                album: "Найліпші питання"
            ) == [.itunes, .musicBrainz, .discogs]
        )
        #expect(
            priorities.orderedSources(
                artist: "Clutch",
                album: "Pure Rock Fury"
            ) == [.musicBrainz, .discogs, .itunes]
        )
    }

    @Test("Batch processing config follows processing settings and restricted scope")
    func batchProcessingConfigFollowsProcessingSettingsAndRestrictedScope() {
        var configuration = AppConfiguration()
        configuration.processing.batchSize = 41
        configuration.processing.delayBetweenBatches = 2.5
        configuration.processing.adaptiveDelay = true

        let fullScope = BatchProcessingConfiguration(
            configuration: configuration,
            isScopeRestricted: false
        )
        let restrictedScope = BatchProcessingConfiguration(
            configuration: configuration,
            isScopeRestricted: true
        )

        #expect(fullScope.batchSize == 41)
        #expect(fullScope.delayBetweenBatchesMilliseconds == 2500)
        #expect(fullScope.adaptiveDelay)
        #expect(restrictedScope.batchSize == 41)
        #expect(restrictedScope.delayBetweenBatchesMilliseconds == 0)
        #expect(restrictedScope.adaptiveDelay == false)
    }

    @Test("Library sync retry policy follows its dedicated configuration")
    func mapsSyncRetry() throws {
        var configuration = AppConfiguration()
        configuration.librarySync.conflictRetries = 4
        configuration.librarySync.conflictDelaySeconds = 0.25

        let runtimeConfiguration = try LibrarySyncRuntimeConfiguration(configuration: configuration)

        #expect(runtimeConfiguration.mirrorRetryPolicy == MirrorRetryPolicy(
            retryLimit: 4,
            delay: .milliseconds(250)
        ))
    }

    @Test("Library sync runtime owns the processing mirror requirement")
    func mapsProcessingRequirement() {
        let expiringConfiguration = LibrarySyncRuntimeConfiguration(
            forceMetadataScanIntervalDays: 3,
            testArtists: [" Aphex Twin "]
        )
        let nonExpiringConfiguration = LibrarySyncRuntimeConfiguration(
            forceMetadataScanIntervalDays: 0,
            testArtists: []
        )

        #expect(expiringConfiguration.processingRequirement == MirrorRequirement(
            testArtists: ["Aphex Twin"],
            fieldSet: .processingV1,
            maximumMetadataAge: 259_200
        ))
        #expect(nonExpiringConfiguration.processingRequirement == MirrorRequirement(
            testArtists: [],
            fieldSet: .processingV1,
            maximumMetadataAge: nil
        ))
    }

    @Test("Zero metadata interval disables scheduled force refresh")
    func zeroMetadataIntervalDisablesScheduledRefresh() async throws {
        let refresh = try await scheduledRefresh(
            intervalDays: 0,
            elapsedSinceForceScan: 2_592_000
        )

        #expect(refresh == .fast)
    }

    @Test("Positive metadata interval changes mode at its exact boundary")
    func positiveMetadataIntervalUsesExactBoundary() async throws {
        let beforeBoundary = try await scheduledRefresh(
            intervalDays: 3,
            elapsedSinceForceScan: 259_199
        )
        let atBoundary = try await scheduledRefresh(
            intervalDays: 3,
            elapsedSinceForceScan: 259_200
        )

        #expect(beforeBoundary == .fast)
        #expect(atBoundary == .force)
    }

    @Test(
        "Library sync retry policy rejects unsafe programmatic delays",
        arguments: [-0.1, Double.nan, Double.infinity, 1e308]
    )
    func rejectsUnsafeSyncDelay(delaySeconds: Double) {
        var configuration = AppConfiguration()
        configuration.librarySync.conflictDelaySeconds = delaySeconds

        #expect(throws: MirrorRetryPolicyError.self) {
            try LibrarySyncRuntimeConfiguration(configuration: configuration)
        }
    }

    @Test("Python-era configuration keys feed runtime configuration owners")
    func pythonEraConfigurationKeysFeedRuntimeConfigurationOwners() throws {
        let jsonString = """
        {
          "test_artists": ["Паліндром"],
          "batch_processing": {
            "ids_batch_size": 22,
            "batch_size": 44
          },
          "applescript_timeouts": {
            "full_library_fetch": 321,
            "ids_batch_fetch": 45
          },
          "year_retrieval": {
            "preferred_api": "discogs",
            "script_api_priorities": {
              "cyrillic": {
                "primary": ["itunes"],
                "fallback": ["discogs"]
              }
            },
            "processing": {
              "batch_size": 13,
              "delay_between_batches": 1.25,
              "adaptive_delay": true,
              "min_confidence_to_cache": 77,
              "skip_prerelease": false,
              "prerelease_handling": "mark_only",
              "prerelease_recheck_days": 10
            }
          }
        }
        """
        let configuration = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: Data(jsonString.utf8)
        )

        let updateRuntime = UpdateRuntimeConfiguration(configuration: configuration)
        #expect(updateRuntime.testArtists == ["Паліндром"])
        #expect(updateRuntime.minimumConfidenceToCache == 77)
        #expect(updateRuntime.skipPrerelease == false)
        #expect(updateRuntime.prereleaseHandling == .markOnly)
        #expect(updateRuntime.prereleaseRecheckDays == 10)
        #expect(updateRuntime.idsBatchSize == 22)

        let syncRuntime = try LibrarySyncRuntimeConfiguration(configuration: configuration)
        #expect(syncRuntime.testArtists == ["Паліндром"])

        let sourcePriority = APISourcePriorityConfiguration(configuration: configuration)
        #expect(sourcePriority.orderedSources(artist: "Паліндром", album: "Найліпші питання") == [
            .itunes,
            .discogs,
            .musicBrainz,
        ])

        let batchProcessing = BatchProcessingConfiguration(configuration: configuration)
        #expect(batchProcessing.batchSize == 13)
        #expect(batchProcessing.delayBetweenBatchesMilliseconds == 0)
        #expect(batchProcessing.adaptiveDelay == false)
    }

    @Test("Update runtime ID batches stay within the script boundary")
    func updateRuntimeIDBatchBoundary() {
        #expect(UpdateRuntimeConfiguration(idsBatchSize: 5000).idsBatchSize == 1000)
    }

    @Test("API orchestrator config maps year-retrieval and runtime settings")
    func apiOrchestratorConfigMapsYearRetrievalAndRuntimeSettings() {
        var configuration = AppConfiguration()
        configuration.caching.negativeResultTTL = 12345
        configuration.yearRetrieval.rateLimits.concurrentAlbums = 4
        configuration.yearRetrieval.rateLimits.concurrentProviderCalls = 7
        configuration.runtime.maxRetries = 4
        configuration.runtime.retryDelaySeconds = 2.5
        configuration.processing.cacheTTLDays = 3
        configuration.yearRetrieval.preferredAPI = .discogs
        configuration.yearRetrieval.reissueDetection.reissueKeywords = ["anniversary"]
        configuration.yearRetrieval.discogsSearch.resultLimit = 17
        configuration.yearRetrieval.discogsSearch.detailLookupLimit = 3

        let orchestrator = APIOrchestratorConfiguration(configuration: configuration)

        #expect(orchestrator.negativeResultTTL == 12345)
        #expect(orchestrator.candidateResultTTL == TimeInterval(3 * 24 * 60 * 60))
        #expect(orchestrator.maxConcurrentSourceCalls == 7)
        #expect(orchestrator.maxAPIRetries == 4)
        #expect(orchestrator.apiRetryDelaySeconds == 2.5)
        #expect(orchestrator.discogsReissueKeywords == ["anniversary"])
        #expect(orchestrator.discogsSearchConfiguration.resultLimit == 17)
        #expect(orchestrator.discogsSearchConfiguration.detailLookupLimit == 3)
        #expect(
            orchestrator.sourcePriorityConfiguration
                .orderedSources(artist: "Clutch", album: "Pure Rock Fury").first == .discogs
        )
        // Only the runtime service references stay unset; the composition root injects them.
        #expect(orchestrator.cache == nil)
        #expect(orchestrator.disabledSources.isEmpty)
    }

    @Test("Update runtime receives the configured cache trust threshold")
    func updateRuntimeReceivesCacheTrustThreshold() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.cacheTrustThreshold = 94

        let runtime = UpdateRuntimeConfiguration(configuration: configuration)

        #expect(runtime.cacheTrustThreshold == 94)
    }

    private func scheduledRefresh(
        intervalDays: Int,
        elapsedSinceForceScan: TimeInterval
    ) async throws -> MetadataRefreshPolicy {
        let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let track = Track(
            id: "T1",
            name: "Song",
            artist: "Artist",
            album: "Album"
        )
        let observer = SyncMockScriptClient(observedAt: { currentDate })
        let store = SyncMockTrackStore()
        let snapshotService = SyncMockLibrarySnapshotService()
        await observer.setLibrary(ids: [track.id], tracks: [track.id: track])
        await store.setStored([track], certificateDate: currentDate)
        await snapshotService.setMetadata(LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: currentDate,
            libraryModificationDate: currentDate,
            lastForceScanDate: currentDate.addingTimeInterval(-elapsedSinceForceScan)
        ))
        let service = LibrarySyncService(
            trackStore: store,
            librarySnapshotService: snapshotService,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                forceMetadataScanIntervalDays: intervalDays
            ),
            currentDate: { currentDate },
            observer: observer
        )

        _ = try await service.detectObservation()
        let request = try #require(await observer.recordedObservationRequests().first)
        return request.refresh
    }
}
