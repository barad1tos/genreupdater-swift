import Foundation
import Testing
@testable import Core

@Suite("AppConfiguration validation")
struct ConfigurationValidationTests {
    @Test("Conflicting normalized artist mappings are rejected with both source keys")
    func rejectsArtistConflicts() throws {
        var configuration = AppConfiguration()
        configuration.artistRenamer.mappings = [
            " oldartist  ": "Second",
            "OldArtist": "First",
        ]

        do {
            _ = try decode(configuration)
            Issue.record("Expected conflicting artist mappings to be rejected")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == ["artistRenamer.mappings"])
            #expect(
                error.issues.first?.receivedValue ==
                    #""oldartist": [" oldartist  " -> "Second", "OldArtist" -> "First"]"#
            )
            #expect(error.localizedDescription.contains("must map one normalized source to one target"))
        }
    }

    @Test("Equivalent normalized artist mappings remain valid")
    func acceptsEquivalentArtistMappings() throws {
        var configuration = AppConfiguration()
        configuration.artistRenamer.mappings = [
            " oldartist  ": " New Artist ",
            "OldArtist": "New Artist",
        ]
        let decoded = try decode(configuration)
        #expect(decoded.artistRenamer.mappings.count == 2)
    }

    @Test("Blank artist mappings retain Python skip semantics")
    func acceptsBlankArtistMappings() throws {
        var configuration = AppConfiguration()
        configuration.artistRenamer.mappings = [
            " ": "Ignored",
            "OldArtist": " ",
            " oldartist ": "New Artist",
        ]

        let decoded = try decode(configuration)

        #expect(decoded.artistRenamer.mappings.count == 3)
    }

    @Test("Conflicting case-insensitive genre mappings are rejected with both rules")
    func rejectsGenreConflicts() throws {
        var configuration = AppConfiguration()
        configuration.cleaning.genreMappings = [
            " rock  ": "Pop",
            "Rock": "Metal",
        ]

        do {
            _ = try decode(configuration)
            Issue.record("Expected conflicting genre mappings to be rejected")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == ["cleaning.genreMappings"])
            #expect(
                error.issues.first?.receivedValue ==
                    #""rock": [" rock  " -> "Pop", "Rock" -> "Metal"]"#
            )
            #expect(error.localizedDescription.contains("must map one normalized source to one target"))
        }
    }

    @Test("Equivalent case-insensitive genre mappings remain valid")
    func acceptsEquivalentGenreMappings() throws {
        var configuration = AppConfiguration()
        configuration.cleaning.genreMappings = [
            " rock  ": " Metal ",
            "Rock": "Metal",
        ]

        let decoded = try decode(configuration)

        #expect(decoded.cleaning.genreMappings.count == 2)
    }

    @Test("Blank genre mappings remain repairable persisted settings")
    func acceptsBlankGenreMappings() throws {
        var configuration = AppConfiguration()
        configuration.cleaning.genreMappings = [
            " ": "Ignored",
            "Rock": " ",
        ]

        let decoded = try decode(configuration)

        #expect(decoded.cleaning.genreMappings.count == 2)
    }

    @Test("Every invalid numeric field reports its canonical path and rule")
    func rejectsInvalidValues() {
        for probe in invalidNumericProbes {
            expectRejection(probe)
        }
    }

    @Test("Closed ranges reject values below their lower bounds")
    func rejectsRangeUnderflow() {
        for probe in lowerRangeProbes {
            expectRejection(probe)
        }
    }

    @Test("Accepted boundaries preserve Python and Swift domain semantics")
    func acceptsNumericBoundaryValues() throws {
        var configuration = AppConfiguration()
        applyRuntimeBoundaries(to: &configuration)
        applyWorkflowBoundaries(to: &configuration)
        applyYearBoundaries(to: &configuration)
        setPenalties(&configuration, to: 0)

        let decoded = try decode(configuration)

        #expect(decoded.applescript.batchProcessing.idsBatchSize == 5000)
        #expect(decoded.applescript.retry.baseDelaySeconds == 10)
        #expect(decoded.applescript.retry.maxDelaySeconds == 0)
        #expect(decoded.analytics.durationThresholds.shortMax == 50)
        #expect(decoded.analytics.durationThresholds.longMax == 5)
        #expect(decoded.yearRetrieval.logic.minValidYear == 3000)
        #expect(decoded.yearRetrieval.logic.absurdYearThreshold == 1000)
        #expect(decoded.yearRetrieval.scoring.artistExactMatchBonus == -1000)
    }

    @Test("Positive scoring weights remain valid for shipped settings")
    func acceptsPositiveScoringWeights() throws {
        var configuration = AppConfiguration()
        setPenalties(&configuration, to: 1)

        let decoded = try decode(configuration)

        #expect(decoded.yearRetrieval.scoring.artistSubstringPenalty == 1)
        #expect(decoded.yearRetrieval.scoring.typeEPSinglePenalty == 1)
        #expect(decoded.yearRetrieval.scoring.yearDiffPenaltyScale == 1)
        #expect(decoded.yearRetrieval.scoring.futureYearPenalty == 1)
    }

    private func applyRuntimeBoundaries(to configuration: inout AppConfiguration) {
        configuration.runtime.cacheTTLSeconds = 0
        configuration.runtime.incrementalIntervalMinutes = 1
        configuration.runtime.maxRetries = 0
        configuration.runtime.retryDelaySeconds = 0
        configuration.runtime.maxGenericEntries = 1
        configuration.applescript.concurrency = 1
        configuration.applescript.timeouts.defaultTimeout = .seconds(1)
        configuration.applescript.timeouts.fullLibraryFetch = .seconds(1)
        configuration.applescript.timeouts.singleArtistFetch = .seconds(1)
        configuration.applescript.timeouts.batchUpdate = .seconds(1)
        configuration.applescript.timeouts.idsBatchFetch = .seconds(1)
        configuration.applescript.rateLimit.requestsPerWindow = 1
        configuration.applescript.rateLimit.windowSizeSeconds = 0.1
        configuration.applescript.retry.maxRetries = 0
        configuration.applescript.retry.baseDelaySeconds = 10
        configuration.applescript.retry.maxDelaySeconds = 0
        configuration.applescript.retry.jitterRange = 1
        configuration.applescript.retry.operationTimeoutSeconds = 0
        configuration.applescript.batchProcessing.idsBatchSize = 5000
        configuration.experimental.maxBatchSize = 1
        configuration.databaseVerification.autoVerifyDays = 0
        configuration.databaseVerification.batchSize = 1
        configuration.pendingVerification.autoVerifyDays = 0
    }

    private func applyWorkflowBoundaries(to configuration: inout AppConfiguration) {
        configuration.genreUpdate.batchSize = 1
        configuration.genreUpdate.concurrentLimit = 1
        configuration.processing.batchSize = 1
        configuration.processing.delayBetweenBatches = 0
        configuration.processing.cacheTTLDays = 0
        configuration.processing.pendingVerificationIntervalDays = 0
        configuration.processing.futureYearThreshold = 0
        configuration.processing.prereleaseRecheckDays = 0
        configuration.processing.releaseYearRestoreThreshold = 0
        configuration.processing.minConfidenceToCache = 100
        configuration.processing.suspiciousAlbumMinLen = 0
        configuration.processing.suspiciousManyYears = 1
        configuration.caching.defaultTTLSeconds = 0
        configuration.caching.albumCacheSyncInterval = 0
        configuration.caching.cleanupErrorRetryDelay = 0
        configuration.caching.cleanupIntervalSeconds = 0
        configuration.caching.negativeResultTTL = 0
        configuration.caching.librarySnapshot.maxAgeHours = 1
        configuration.caching.librarySnapshot.compressLevel = 9
        configuration.analytics.durationThresholds.shortMax = 50
        configuration.analytics.durationThresholds.mediumMax = 20
        configuration.analytics.durationThresholds.longMax = 5
        configuration.analytics.maxEvents = 0
        configuration.analytics.retentionDays = 1
        configuration.reporting.minAttemptsForReport = 1
        configuration.reporting.runHistoryLimit = 1
        configuration.logging.maxRuns = 0
    }

    private func applyYearBoundaries(to configuration: inout AppConfiguration) {
        configuration.yearRetrieval.rateLimits.discogsRequestsPerMinute = 1
        configuration.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = 0.1
        configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond = 0.1
        configuration.yearRetrieval.requestTimeoutSeconds = 1
        configuration.yearRetrieval.rateLimits.concurrentAlbums = 1
        configuration.yearRetrieval.rateLimits.concurrentProviderCalls = 1
        configuration.yearRetrieval.logic.minValidYear = 3000
        configuration.yearRetrieval.logic.absurdYearThreshold = 1000
        configuration.yearRetrieval.logic.suspicionThresholdYears = 0
        configuration.yearRetrieval.logic.definitiveScoreThreshold = 100
        configuration.yearRetrieval.logic.definitiveScoreDiff = 0
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 0
        configuration.yearRetrieval.logic.dominantYearMinConfidence = 1
        configuration.yearRetrieval.fallback.yearDifferenceThreshold = 0
        configuration.yearRetrieval.fallback.trustAPIScoreThreshold = 100
        configuration.yearRetrieval.fallback.maxVerificationAttempts = 0
        configuration.yearRetrieval.fallback.rerecordingAgeYears = 0
        configuration.yearRetrieval.discogsSearch.resultLimit = 1
        configuration.yearRetrieval.discogsSearch.detailLookupLimit = 0
        configuration.yearRetrieval.itunesSearch.limit = 1
        configuration.yearRetrieval.scoring.artistExactMatchBonus = -1000
    }

    @Test("All invalid fields are reported in canonical path order")
    func reportsAllInvalidNumericFields() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.itunesSearch.limit = 201
        configuration.runtime.maxGenericEntries = 0
        configuration.genreUpdate.batchSize = 0
        configuration.applescript.retry.jitterRange = 1.01

        do {
            _ = try decode(configuration)
            Issue.record("Expected every invalid field to be rejected")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == [
                "applescript.retry.jitterRange",
                "genreUpdate.batchSize",
                "runtime.maxGenericEntries",
                "yearRetrieval.itunesSearch.limit",
            ])
            #expect(error.localizedDescription.contains("received 1.01"))
            #expect(error.localizedDescription.contains("received 201"))
        }
    }

    @Test("Legacy values are validated after current-key precedence is resolved")
    func validatesLegacyValuesAfterPrecedenceResolution() throws {
        let invalidLegacyData = Data(#"{"incremental_interval_minutes":0}"#.utf8)

        do {
            _ = try AppConfiguration.configurationDecoder().decode(
                AppConfiguration.self,
                from: invalidLegacyData
            )
            Issue.record("Expected an invalid legacy interval to be rejected")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == ["runtime.incrementalIntervalMinutes"])
        }

        let currentWinsData = Data(
            #"{"runtime":{"incrementalIntervalMinutes":1},"incremental_interval_minutes":0}"#.utf8
        )
        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: currentWinsData
        )
        #expect(decoded.runtime.incrementalIntervalMinutes == 1)
    }

    @Test("Invalid configuration does not replace an existing file")
    func invalidConfigurationPreservesFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenreUpdaterConfigurationValidation", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("config.json")
        let validConfiguration = AppConfiguration()
        try validConfiguration.save(to: configurationURL)
        let validData = try Data(contentsOf: configurationURL)
        var invalidConfiguration = validConfiguration
        invalidConfiguration.genreUpdate.batchSize = 0

        #expect(throws: ConfigurationValidationError.self) {
            try invalidConfiguration.save(to: configurationURL)
        }
        #expect(try Data(contentsOf: configurationURL) == validData)
    }

    @Test("Conflicting artist mappings do not replace an existing file")
    func conflictsPreserveFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenreUpdaterArtistMappingValidation", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("config.json")
        try AppConfiguration().save(to: configurationURL)
        let validData = try Data(contentsOf: configurationURL)
        var conflicting = AppConfiguration()
        conflicting.artistRenamer.mappings = [
            " oldartist  ": "Second",
            "OldArtist": "First",
        ]

        #expect(throws: ConfigurationValidationError.self) {
            try conflicting.save(to: configurationURL)
        }
        #expect(try Data(contentsOf: configurationURL) == validData)
    }

    @Test("Persisted artist conflict blocks relaunch until the file is repaired")
    func relaunchRequiresRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenreUpdaterArtistMappingRelaunch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("config.json")
        var conflicting = AppConfiguration()
        conflicting.artistRenamer.mappings = [
            " oldartist  ": "Second",
            "OldArtist": "First",
        ]
        try JSONEncoder().encode(conflicting).write(to: configurationURL, options: .atomic)

        #expect(throws: ConfigurationValidationError.self) {
            _ = try AppConfiguration.load(from: configurationURL)
        }

        var repaired = AppConfiguration()
        repaired.artistRenamer.mappings = ["OldArtist": "First"]
        try JSONEncoder().encode(repaired).write(to: configurationURL, options: .atomic)

        let reloaded = try AppConfiguration.load(from: configurationURL)
        #expect(reloaded.artistRenamer.mappings == ["OldArtist": "First"])
    }

    @Test("Non-finite configuration fails before persistence encoding")
    func rejectsNonFiniteSaves() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenreUpdaterFiniteValidation", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("config.json")
        try AppConfiguration().save(to: configurationURL)
        let validData = try Data(contentsOf: configurationURL)
        var nanConfiguration = AppConfiguration()
        nanConfiguration.analytics.durationThresholds.shortMax = .nan
        var infiniteConfiguration = AppConfiguration()
        infiniteConfiguration.applescript.retry.jitterRange = .infinity

        for configuration in [nanConfiguration, infiniteConfiguration] {
            do {
                try configuration.save(to: configurationURL)
                Issue.record("Expected non-finite configuration to be rejected")
            } catch let error as ConfigurationValidationError {
                #expect(error.issues.first?.requirement == "must be finite")
            } catch {
                Issue.record("Expected validation error before encoding: \(error)")
            }
            #expect(try Data(contentsOf: configurationURL) == validData)
        }
    }

    @Test("Every AppleScript timeout fits integer seconds")
    func rejectsTimeoutOverflow() throws {
        let fields = [
            ("defaultTimeoutSeconds", "applescript.timeouts.defaultTimeout"),
            ("fullLibraryFetchSeconds", "applescript.timeouts.fullLibraryFetch"),
            ("singleArtistFetchSeconds", "applescript.timeouts.singleArtistFetch"),
            ("batchUpdateSeconds", "applescript.timeouts.batchUpdate"),
            ("idsBatchFetchSeconds", "applescript.timeouts.idsBatchFetch"),
        ]

        for (key, path) in fields {
            let data = Data(#"{"applescript":{"timeouts":{"\#(key)":\#(Int.max)}}}"#.utf8)
            do {
                _ = try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: data)
                Issue.record("Expected timeout overflow to be rejected for \(path)")
            } catch let error as ConfigurationValidationError {
                #expect(error.issues.map(\.fieldPath) == [path])
                #expect(error.issues.first?.requirement == "must fit integer seconds")
            } catch {
                Issue.record("Unexpected timeout overflow error for \(path): \(error)")
            }
        }
    }

    @Test("Fractional AppleScript timeouts preserve truncating persistence semantics")
    func acceptsFractionalTimeouts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenreUpdaterFractionalTimeouts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("config.json")
        let timeoutPaths: [WritableKeyPath<AppleScriptTimeouts, Duration>] = [
            \.defaultTimeout,
            \.fullLibraryFetch,
            \.singleArtistFetch,
            \.batchUpdate,
            \.idsBatchFetch,
        ]

        for timeoutPath in timeoutPaths {
            var configuration = AppConfiguration()
            configuration.applescript.timeouts[keyPath: timeoutPath] = .milliseconds(1500)

            try configuration.save(to: configurationURL)
            let reloaded = try AppConfiguration.load(from: configurationURL)

            #expect(reloaded.applescript.timeouts[keyPath: timeoutPath] == .seconds(1))
        }
    }

    @Test("Generic Codable snapshots remain tolerant of historical numeric values")
    func genericSnapshotDecodeRemainsTolerant() throws {
        var configuration = AppConfiguration()
        configuration.genreUpdate.batchSize = 0
        let data = try JSONEncoder().encode(configuration)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        #expect(decoded.genreUpdate.batchSize == 0)
    }

    private func decode(_ configuration: AppConfiguration) throws -> AppConfiguration {
        let data = try JSONEncoder().encode(configuration)
        return try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: data)
    }

    private func expectRejection(_ probe: InvalidNumericProbe) {
        var configuration = AppConfiguration()
        probe.mutate(&configuration)

        do {
            _ = try decode(configuration)
            Issue.record("Expected validation to reject \(probe.issue.fieldPath)")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues == [probe.issue])
        } catch {
            Issue.record("Unexpected error for \(probe.issue.fieldPath): \(error)")
        }
    }

    private func setPenalties(_ configuration: inout AppConfiguration, to value: Int) {
        configuration.yearRetrieval.scoring.artistSubstringPenalty = value
        configuration.yearRetrieval.scoring.artistCrossScriptPenalty = value
        configuration.yearRetrieval.scoring.artistMismatchPenalty = value
        configuration.yearRetrieval.scoring.albumSubstringPenalty = value
        configuration.yearRetrieval.scoring.albumUnrelatedPenalty = value
        configuration.yearRetrieval.scoring.typeEPSinglePenalty = value
        configuration.yearRetrieval.scoring.typeCompilationLivePenalty = value
        configuration.yearRetrieval.scoring.statusBootlegPenalty = value
        configuration.yearRetrieval.scoring.statusPromoPenalty = value
        configuration.yearRetrieval.scoring.reissuePenalty = value
        configuration.yearRetrieval.scoring.yearDiffPenaltyScale = value
        configuration.yearRetrieval.scoring.yearDiffMaxPenalty = value
        configuration.yearRetrieval.scoring.yearBeforeStartPenalty = value
        configuration.yearRetrieval.scoring.yearAfterEndPenalty = value
        configuration.yearRetrieval.scoring.futureYearPenalty = value
    }

    private var invalidNumericProbes: [InvalidNumericProbe] {
        [
            minimumZero("runtime.cacheTTLSeconds", "-1") { $0.runtime.cacheTTLSeconds = -1 },
            minimumOne("runtime.incrementalIntervalMinutes", "0") { $0.runtime.incrementalIntervalMinutes = 0 },
            minimumZero("runtime.maxRetries", "-1") { $0.runtime.maxRetries = -1 },
            minimumZero("runtime.retryDelaySeconds", "-1.0") { $0.runtime.retryDelaySeconds = -1 },
            millisecondCapacity("runtime.retryDelaySeconds", "1e+308") { $0.runtime.retryDelaySeconds = 1e308 },
            minimumOne("runtime.maxGenericEntries", "0") { $0.runtime.maxGenericEntries = 0 },
            minimumOne("applescript.concurrency", "0") { $0.applescript.concurrency = 0 },
            minimumOne("applescript.timeouts.defaultTimeout", "0") { $0.applescript.timeouts.defaultTimeout = .zero },
            minimumOne("applescript.timeouts.fullLibraryFetch", "0") {
                $0.applescript.timeouts.fullLibraryFetch = .zero
            },
            minimumOne("applescript.timeouts.singleArtistFetch", "0") {
                $0.applescript.timeouts.singleArtistFetch = .zero
            },
            minimumOne("applescript.timeouts.batchUpdate", "0") { $0.applescript.timeouts.batchUpdate = .zero },
            minimumOne("applescript.timeouts.idsBatchFetch", "0") {
                $0.applescript.timeouts.idsBatchFetch = .zero
            },
            minimumOne("applescript.rateLimit.requestsPerWindow", "0") {
                $0.applescript.rateLimit.requestsPerWindow = 0
            },
            greaterThanZero("applescript.rateLimit.windowSizeSeconds", "0.0") {
                $0.applescript.rateLimit.windowSizeSeconds = 0
            },
            millisecondCapacity("applescript.rateLimit.windowSizeSeconds", "1e+308") {
                $0.applescript.rateLimit.windowSizeSeconds = 1e308
            },
            minimumZero("applescript.retry.maxRetries", "-1") { $0.applescript.retry.maxRetries = -1 },
            minimumZero("applescript.retry.baseDelaySeconds", "-1.0") {
                $0.applescript.retry.baseDelaySeconds = -1
            },
            millisecondCapacity("applescript.retry.baseDelaySeconds", "1e+308") {
                $0.applescript.retry.baseDelaySeconds = 1e308
            },
            minimumZero("applescript.retry.maxDelaySeconds", "-1.0") {
                $0.applescript.retry.maxDelaySeconds = -1
            },
            millisecondCapacity("applescript.retry.maxDelaySeconds", "1e+308") {
                $0.applescript.retry.maxDelaySeconds = 1e308
            },
            zeroToOne("applescript.retry.jitterRange", "1.01") { $0.applescript.retry.jitterRange = 1.01 },
            minimumZero("applescript.retry.operationTimeoutSeconds", "-1.0") {
                $0.applescript.retry.operationTimeoutSeconds = -1
            },
            millisecondCapacity("applescript.retry.operationTimeoutSeconds", "1e+308") {
                $0.applescript.retry.operationTimeoutSeconds = 1e308
            },
            minimumOne("applescript.batchProcessing.idsBatchSize", "0") {
                $0.applescript.batchProcessing.idsBatchSize = 0
            },
            minimumOne("experimental.maxBatchSize", "0") { $0.experimental.maxBatchSize = 0 },
            minimumZero("databaseVerification.autoVerifyDays", "-1") {
                $0.databaseVerification.autoVerifyDays = -1
            },
            minimumOne("databaseVerification.batchSize", "0") { $0.databaseVerification.batchSize = 0 },
            minimumZero("pendingVerification.autoVerifyDays", "-1") {
                $0.pendingVerification.autoVerifyDays = -1
            },
            minimumOne("genreUpdate.batchSize", "0") { $0.genreUpdate.batchSize = 0 },
            minimumOne("genreUpdate.concurrentLimit", "0") { $0.genreUpdate.concurrentLimit = 0 },
            minimumOne("processing.batchSize", "0") { $0.processing.batchSize = 0 },
            minimumZero("processing.delayBetweenBatches", "-1.0") { $0.processing.delayBetweenBatches = -1 },
            millisecondCapacity("processing.delayBetweenBatches", "1e+308") {
                $0.processing.delayBetweenBatches = 1e308
            },
            minimumZero("processing.cacheTTLDays", "-1") { $0.processing.cacheTTLDays = -1 },
            minimumZero("processing.pendingVerificationIntervalDays", "-1") {
                $0.processing.pendingVerificationIntervalDays = -1
            },
            minimumZero("processing.futureYearThreshold", "-1") { $0.processing.futureYearThreshold = -1 },
            minimumZero("processing.prereleaseRecheckDays", "-1") { $0.processing.prereleaseRecheckDays = -1 },
            minimumZero("caching.defaultTTLSeconds", "-1") { $0.caching.defaultTTLSeconds = -1 },
            minimumZero("caching.albumCacheSyncInterval", "-1") { $0.caching.albumCacheSyncInterval = -1 },
            minimumZero("caching.cleanupErrorRetryDelay", "-1") { $0.caching.cleanupErrorRetryDelay = -1 },
            minimumZero("caching.cleanupIntervalSeconds", "-1") { $0.caching.cleanupIntervalSeconds = -1 },
            minimumZero("caching.negativeResultTTL", "-1.0") { $0.caching.negativeResultTTL = -1 },
            integerCapacity("caching.negativeResultTTL", "1e+308") { $0.caching.negativeResultTTL = 1e308 },
            minimumOne("caching.librarySnapshot.maxAgeHours", "0") { $0.caching.librarySnapshot.maxAgeHours = 0 },
            oneToNine("caching.librarySnapshot.compressLevel", "10") {
                $0.caching.librarySnapshot.compressLevel = 10
            },
            minimumZero("analytics.durationThresholds.shortMax", "-1.0") {
                $0.analytics.durationThresholds.shortMax = -1
            },
            minimumZero("analytics.durationThresholds.mediumMax", "-1.0") {
                $0.analytics.durationThresholds.mediumMax = -1
            },
            minimumZero("analytics.durationThresholds.longMax", "-1.0") {
                $0.analytics.durationThresholds.longMax = -1
            },
            minimumZero("analytics.maxEvents", "-1") { $0.analytics.maxEvents = -1 },
            minimumOne("analytics.retentionDays", "0") { $0.analytics.retentionDays = 0 },
            minimumOne("reporting.minAttemptsForReport", "0.0") { $0.reporting.minAttemptsForReport = 0 },
            integerCapacity("reporting.minAttemptsForReport", "1e+308") {
                $0.reporting.minAttemptsForReport = 1e308
            },
            minimumZero("logging.maxRuns", "-1") { $0.logging.maxRuns = -1 },
            minimumOne("yearRetrieval.rateLimits.discogsRequestsPerMinute", "0") {
                $0.yearRetrieval.rateLimits.discogsRequestsPerMinute = 0
            },
            minimumZero("yearRetrieval.rateLimits.musicbrainzRequestsPerSecond", "-1.0") {
                $0.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = -1
            },
            pacingCapacity("yearRetrieval.rateLimits.musicbrainzRequestsPerSecond", "1e-308") {
                $0.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = 1e-308
            },
            minimumOne("yearRetrieval.rateLimits.concurrentAlbums", "0") {
                $0.yearRetrieval.rateLimits.concurrentAlbums = 0
            },
            minimumOne("yearRetrieval.rateLimits.concurrentProviderCalls", "0") {
                $0.yearRetrieval.rateLimits.concurrentProviderCalls = 0
            },
            minimumThousand("yearRetrieval.logic.minValidYear", "999") {
                $0.yearRetrieval.logic.minValidYear = 999
            },
            minimumThousand("yearRetrieval.logic.absurdYearThreshold", "999") {
                $0.yearRetrieval.logic.absurdYearThreshold = 999
            },
            minimumZero("yearRetrieval.logic.suspicionThresholdYears", "-1") {
                $0.yearRetrieval.logic.suspicionThresholdYears = -1
            },
            zeroToHundred("yearRetrieval.logic.definitiveScoreThreshold", "101") {
                $0.yearRetrieval.logic.definitiveScoreThreshold = 101
            },
            minimumZero("yearRetrieval.logic.definitiveScoreDiff", "-1") {
                $0.yearRetrieval.logic.definitiveScoreDiff = -1
            },
            zeroToHundred("yearRetrieval.logic.minConfidenceForNewYear", "101.0") {
                $0.yearRetrieval.logic.minConfidenceForNewYear = 101
            },
            zeroToHundred("yearRetrieval.logic.cacheTrustThreshold", "101") {
                $0.yearRetrieval.logic.cacheTrustThreshold = 101
            },
            zeroToHundred("yearRetrieval.logic.consensusYearConfidence", "101") {
                $0.yearRetrieval.logic.consensusYearConfidence = 101
            },
            minimumZero("yearRetrieval.fallback.yearDifferenceThreshold", "-1") {
                $0.yearRetrieval.fallback.yearDifferenceThreshold = -1
            },
            zeroToHundred("yearRetrieval.fallback.trustAPIScoreThreshold", "101.0") {
                $0.yearRetrieval.fallback.trustAPIScoreThreshold = 101
            },
            zeroToHundred("processing.releaseYearRestoreThreshold", "101") {
                $0.processing.releaseYearRestoreThreshold = 101
            },
            zeroToHundred("processing.minConfidenceToCache", "101") { $0.processing.minConfidenceToCache = 101 },
            minimumZero("processing.suspiciousAlbumMinLen", "-1") { $0.processing.suspiciousAlbumMinLen = -1 },
            minimumOne("processing.suspiciousManyYears", "0") { $0.processing.suspiciousManyYears = 0 },
            zeroToOne("yearRetrieval.logic.dominantYearMinConfidence", "1.01") {
                $0.yearRetrieval.logic.dominantYearMinConfidence = 1.01
            },
            minimumZero("yearRetrieval.fallback.maxVerificationAttempts", "-1") {
                $0.yearRetrieval.fallback.maxVerificationAttempts = -1
            },
            minimumZero("yearRetrieval.fallback.rerecordingAgeYears", "-1") {
                $0.yearRetrieval.fallback.rerecordingAgeYears = -1
            },
            oneToHundred("yearRetrieval.discogsSearch.resultLimit", "101") {
                $0.yearRetrieval.discogsSearch.resultLimit = 101
            },
            zeroToHundred("yearRetrieval.discogsSearch.detailLookupLimit", "101") {
                $0.yearRetrieval.discogsSearch.detailLookupLimit = 101
            },
            oneToTwoHundred("yearRetrieval.itunesSearch.limit", "201") {
                $0.yearRetrieval.itunesSearch.limit = 201
            },
            minimumOne("reporting.runHistoryLimit", "0") { $0.reporting.runHistoryLimit = 0 },
        ]
    }

    private var lowerRangeProbes: [InvalidNumericProbe] {
        [
            zeroToOne("applescript.retry.jitterRange", "-0.01") { $0.applescript.retry.jitterRange = -0.01 },
            zeroToHundred("processing.releaseYearRestoreThreshold", "-1") {
                $0.processing.releaseYearRestoreThreshold = -1
            },
            zeroToHundred("processing.minConfidenceToCache", "-1") {
                $0.processing.minConfidenceToCache = -1
            },
            oneToNine("caching.librarySnapshot.compressLevel", "0") {
                $0.caching.librarySnapshot.compressLevel = 0
            },
            zeroToHundred("yearRetrieval.logic.definitiveScoreThreshold", "-1") {
                $0.yearRetrieval.logic.definitiveScoreThreshold = -1
            },
            zeroToHundred("yearRetrieval.logic.minConfidenceForNewYear", "-0.01") {
                $0.yearRetrieval.logic.minConfidenceForNewYear = -0.01
            },
            zeroToHundred("yearRetrieval.logic.cacheTrustThreshold", "-1") {
                $0.yearRetrieval.logic.cacheTrustThreshold = -1
            },
            zeroToHundred("yearRetrieval.logic.consensusYearConfidence", "-1") {
                $0.yearRetrieval.logic.consensusYearConfidence = -1
            },
            zeroToOne("yearRetrieval.logic.dominantYearMinConfidence", "-0.01") {
                $0.yearRetrieval.logic.dominantYearMinConfidence = -0.01
            },
            zeroToHundred("yearRetrieval.fallback.trustAPIScoreThreshold", "-0.01") {
                $0.yearRetrieval.fallback.trustAPIScoreThreshold = -0.01
            },
            oneToHundred("yearRetrieval.discogsSearch.resultLimit", "0") {
                $0.yearRetrieval.discogsSearch.resultLimit = 0
            },
            zeroToHundred("yearRetrieval.discogsSearch.detailLookupLimit", "-1") {
                $0.yearRetrieval.discogsSearch.detailLookupLimit = -1
            },
            oneToTwoHundred("yearRetrieval.itunesSearch.limit", "0") {
                $0.yearRetrieval.itunesSearch.limit = 0
            },
        ]
    }

    private func minimumZero(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be at least 0", mutate: mutate)
    }

    private func minimumOne(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be at least 1", mutate: mutate)
    }

    private func greaterThanZero(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be greater than 0", mutate: mutate)
    }

    private func zeroToOne(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be between 0 and 1", mutate: mutate)
    }

    private func zeroToHundred(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be between 0 and 100", mutate: mutate)
    }

    private func oneToNine(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be between 1 and 9", mutate: mutate)
    }

    private func oneToTwoHundred(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be between 1 and 200", mutate: mutate)
    }

    private func oneToHundred(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be between 1 and 100", mutate: mutate)
    }

    private func pacingCapacity(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must fit the pacing interval capacity", mutate: mutate)
    }

    private func millisecondCapacity(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must fit the millisecond duration capacity", mutate: mutate)
    }

    private func integerCapacity(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must fit integer conversion capacity", mutate: mutate)
    }

    private func minimumThousand(
        _ path: String,
        _ receivedValue: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        probe(path, receivedValue, "must be at least 1000", mutate: mutate)
    }

    private func probe(
        _ path: String,
        _ receivedValue: String,
        _ requirement: String,
        mutate: @escaping @Sendable (inout AppConfiguration) -> Void
    ) -> InvalidNumericProbe {
        InvalidNumericProbe(
            issue: ConfigurationValidationIssue(
                fieldPath: path,
                receivedValue: receivedValue,
                requirement: requirement
            ),
            mutate: mutate
        )
    }
}

private struct InvalidNumericProbe: Sendable {
    let issue: ConfigurationValidationIssue
    let mutate: @Sendable (inout AppConfiguration) -> Void
}
