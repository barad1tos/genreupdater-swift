import Foundation

/// One configuration value rejected by boundary validation.
public struct ConfigurationValidationIssue: Sendable, Equatable {
    /// Canonical Swift configuration path.
    public let fieldPath: String
    /// Stable textual representation of the rejected value.
    public let receivedValue: String
    /// Requirement the value violates.
    public let requirement: String
}

/// Complete deterministic set of configuration violations.
public struct ConfigurationValidationError: Error, LocalizedError, Sendable, Equatable {
    /// Violations sorted by canonical field path.
    public let issues: [ConfigurationValidationIssue]

    init(issues: [ConfigurationValidationIssue]) {
        precondition(!issues.isEmpty)
        self.issues = issues.sorted { $0.fieldPath < $1.fieldPath }
    }

    public var errorDescription: String? {
        let details = issues.map { issue in
            "\(issue.fieldPath): received \(issue.receivedValue); \(issue.requirement)"
        }
        return (["Invalid configuration:"] + details).joined(separator: "\n")
    }
}

extension AppConfiguration {
    /// Validates every semantic invariant required by live configuration and runtime construction.
    ///
    /// - Throws: `ConfigurationValidationError` containing all violations, sorted by canonical path.
    public func validate() throws {
        var validation = ValidationCollector()
        validateNumericValues(using: &validation)
        validateMappings(using: &validation)
        try validation.finish()
    }

    private func validateNumericValues(using validation: inout ValidationCollector) {
        validateRuntime(using: &validation)
        validateAppleScript(using: &validation)
        validateWorkflow(using: &validation)
        validateYearRetrieval(using: &validation)
    }

    private func validateMappings(using validation: inout ValidationCollector) {
        validateMappingConflicts(
            artistRenamer.mappings,
            path: "artistRenamer.mappings",
            using: &validation
        )
        validateMappingConflicts(
            cleaning.genreMappings,
            path: "cleaning.genreMappings",
            using: &validation
        )
    }

    private func validateMappingConflicts(
        _ mappings: [String: String],
        path: String,
        using validation: inout ValidationCollector
    ) {
        let entries = mappings.compactMap { source, target -> MappingEntry? in
            let normalizedSource = normalizeForMatching(source)
            let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSource.isEmpty, !trimmedTarget.isEmpty else { return nil }
            return MappingEntry(
                source: source,
                target: trimmedTarget,
                normalizedSource: normalizedSource
            )
        }
        let conflicts = Dictionary(grouping: entries, by: \.normalizedSource)
            .filter { Set($0.value.map(\.target)).count > 1 }
            .sorted { $0.key < $1.key }
        guard !conflicts.isEmpty else { return }

        let receivedValue = conflicts.map { normalizedSource, entries in
            let mappings = entries
                .sorted { ($0.source, $0.target) < ($1.source, $1.target) }
                .map { "\(String(reflecting: $0.source)) -> \(String(reflecting: $0.target))" }
                .joined(separator: ", ")
            return "\(String(reflecting: normalizedSource)): [\(mappings)]"
        }.joined(separator: "; ")
        validation.record(
            path: path,
            value: receivedValue,
            requirement: "must map one normalized source to one target"
        )
    }

    private func validateRuntime(using validation: inout ValidationCollector) {
        validation.requireAtLeast(runtime.cacheTTLSeconds, minimum: 0, path: "runtime.cacheTTLSeconds")
        validation.requireAtLeast(
            runtime.incrementalIntervalMinutes,
            minimum: 1,
            path: "runtime.incrementalIntervalMinutes"
        )
        validation.requireAtLeast(runtime.maxRetries, minimum: 0, path: "runtime.maxRetries")
        validation.requireAtLeast(runtime.retryDelaySeconds, minimum: 0, path: "runtime.retryDelaySeconds")
        validation.requireMillisecondCapacity(
            runtime.retryDelaySeconds,
            path: "runtime.retryDelaySeconds"
        )
        validation.requireAtLeast(
            librarySync.conflictRetries,
            minimum: 0,
            path: "librarySync.conflictRetries"
        )
        validation.requireAtLeast(
            librarySync.conflictDelaySeconds,
            minimum: 0,
            path: "librarySync.conflictDelaySeconds"
        )
        validation.requireAtLeast(
            librarySync.syncRecordLimit,
            minimum: 1,
            path: "librarySync.syncRecordLimit"
        )
        validation.requireMillisecondCapacity(
            librarySync.conflictDelaySeconds,
            path: "librarySync.conflictDelaySeconds"
        )
        validation.requireAtLeast(runtime.maxGenericEntries, minimum: 1, path: "runtime.maxGenericEntries")
        validation.requireAtLeast(experimental.maxBatchSize, minimum: 1, path: "experimental.maxBatchSize")
        validation.requireAtLeast(
            databaseVerification.autoVerifyDays,
            minimum: 0,
            path: "databaseVerification.autoVerifyDays"
        )
        validation.requireAtLeast(
            databaseVerification.batchSize,
            minimum: 1,
            path: "databaseVerification.batchSize"
        )
        validation.requireAtLeast(
            pendingVerification.autoVerifyDays,
            minimum: 0,
            path: "pendingVerification.autoVerifyDays"
        )
    }

    private func validateAppleScript(using validation: inout ValidationCollector) {
        validation.requireAtLeast(applescript.concurrency, minimum: 1, path: "applescript.concurrency")
        validation.requireAtLeastSecond(
            applescript.timeouts.defaultTimeout,
            path: "applescript.timeouts.defaultTimeout"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.fullLibraryFetch,
            path: "applescript.timeouts.fullLibraryFetch"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.singleArtistFetch,
            path: "applescript.timeouts.singleArtistFetch"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.batchUpdate,
            path: "applescript.timeouts.batchUpdate"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.idsBatchFetch,
            path: "applescript.timeouts.idsBatchFetch"
        )
        validation.requireAtLeast(
            applescript.rateLimit.requestsPerWindow,
            minimum: 1,
            path: "applescript.rateLimit.requestsPerWindow"
        )
        validation.requireGreaterThan(
            applescript.rateLimit.windowSizeSeconds,
            minimum: 0,
            path: "applescript.rateLimit.windowSizeSeconds"
        )
        validation.requireMillisecondCapacity(
            applescript.rateLimit.windowSizeSeconds,
            path: "applescript.rateLimit.windowSizeSeconds"
        )
        validateAppleScriptRetry(using: &validation)
        validation.requireAtLeast(
            applescript.batchProcessing.idsBatchSize,
            minimum: 1,
            path: "applescript.batchProcessing.idsBatchSize"
        )
        validation.requireInRange(
            applescript.batchProcessing.bulkMetadataThreshold,
            range: BatchProcessingConfig.bulkMetadataThresholdRange,
            path: "applescript.batchProcessing.bulkMetadataThreshold"
        )
    }

    private func validateAppleScriptRetry(using validation: inout ValidationCollector) {
        validation.requireAtLeast(
            applescript.retry.maxRetries,
            minimum: 0,
            path: "applescript.retry.maxRetries"
        )
        validation.requireAtLeast(
            applescript.retry.baseDelaySeconds,
            minimum: 0,
            path: "applescript.retry.baseDelaySeconds"
        )
        validation.requireMillisecondCapacity(
            applescript.retry.baseDelaySeconds,
            path: "applescript.retry.baseDelaySeconds"
        )
        validation.requireAtLeast(
            applescript.retry.maxDelaySeconds,
            minimum: 0,
            path: "applescript.retry.maxDelaySeconds"
        )
        validation.requireMillisecondCapacity(
            applescript.retry.maxDelaySeconds,
            path: "applescript.retry.maxDelaySeconds"
        )
        validation.requireInRange(
            applescript.retry.jitterRange,
            range: 0 ... 1,
            path: "applescript.retry.jitterRange"
        )
        validation.requireAtLeast(
            applescript.retry.operationTimeoutSeconds,
            minimum: 0,
            path: "applescript.retry.operationTimeoutSeconds"
        )
        validation.requireMillisecondCapacity(
            applescript.retry.operationTimeoutSeconds,
            path: "applescript.retry.operationTimeoutSeconds"
        )
    }

    private func validateWorkflow(using validation: inout ValidationCollector) {
        validateProcessing(using: &validation)
        validateCaching(using: &validation)
        validateAnalyticsAndReporting(using: &validation)
    }

    private func validateProcessing(using validation: inout ValidationCollector) {
        validation.requireAtLeast(genreUpdate.batchSize, minimum: 1, path: "genreUpdate.batchSize")
        validation.requireAtLeast(genreUpdate.concurrentLimit, minimum: 1, path: "genreUpdate.concurrentLimit")
        validation.requireAtLeast(processing.batchSize, minimum: 1, path: "processing.batchSize")
        validation.requireAtLeast(
            processing.delayBetweenBatches,
            minimum: 0,
            path: "processing.delayBetweenBatches"
        )
        validation.requireMillisecondCapacity(
            processing.delayBetweenBatches,
            path: "processing.delayBetweenBatches"
        )
        validation.requireAtLeast(processing.cacheTTLDays, minimum: 0, path: "processing.cacheTTLDays")
        validation.requireAtLeast(
            processing.pendingVerificationIntervalDays,
            minimum: 0,
            path: "processing.pendingVerificationIntervalDays"
        )
        validation.requireAtLeast(
            processing.futureYearThreshold,
            minimum: 0,
            path: "processing.futureYearThreshold"
        )
        validation.requireAtLeast(
            processing.prereleaseRecheckDays,
            minimum: 0,
            path: "processing.prereleaseRecheckDays"
        )
        validation.requireInRange(
            processing.releaseYearRestoreThreshold,
            range: 0 ... 100,
            path: "processing.releaseYearRestoreThreshold"
        )
        validation.requireInRange(
            processing.minConfidenceToCache,
            range: 0 ... 100,
            path: "processing.minConfidenceToCache"
        )
        validation.requireAtLeast(
            processing.suspiciousAlbumMinLen,
            minimum: 0,
            path: "processing.suspiciousAlbumMinLen"
        )
        validation.requireAtLeast(
            processing.suspiciousManyYears,
            minimum: 1,
            path: "processing.suspiciousManyYears"
        )
    }

    private func validateCaching(using validation: inout ValidationCollector) {
        validation.requireAtLeast(caching.defaultTTLSeconds, minimum: 0, path: "caching.defaultTTLSeconds")
        validation.requireAtLeast(
            caching.albumCacheSyncInterval,
            minimum: 0,
            path: "caching.albumCacheSyncInterval"
        )
        validation.requireAtLeast(
            caching.cleanupErrorRetryDelay,
            minimum: 0,
            path: "caching.cleanupErrorRetryDelay"
        )
        validation.requireAtLeast(
            caching.cleanupIntervalSeconds,
            minimum: 0,
            path: "caching.cleanupIntervalSeconds"
        )
        validation.requireAtLeast(caching.negativeResultTTL, minimum: 0, path: "caching.negativeResultTTL")
        validation.requireIntegerCapacity(
            caching.negativeResultTTL,
            divisor: 86400,
            path: "caching.negativeResultTTL"
        )
        validation.requireAtLeast(
            caching.librarySnapshot.maxAgeHours,
            minimum: 1,
            path: "caching.librarySnapshot.maxAgeHours"
        )
        validation.requireInRange(
            caching.librarySnapshot.compressLevel,
            range: 1 ... 9,
            path: "caching.librarySnapshot.compressLevel"
        )
    }

    private func validateAnalyticsAndReporting(using validation: inout ValidationCollector) {
        validation.requireAtLeast(
            analytics.durationThresholds.shortMax,
            minimum: 0,
            path: "analytics.durationThresholds.shortMax"
        )
        validation.requireAtLeast(
            analytics.durationThresholds.mediumMax,
            minimum: 0,
            path: "analytics.durationThresholds.mediumMax"
        )
        validation.requireAtLeast(
            analytics.durationThresholds.longMax,
            minimum: 0,
            path: "analytics.durationThresholds.longMax"
        )
        validation.requireAtLeast(analytics.maxEvents, minimum: 0, path: "analytics.maxEvents")
        validation.requireAtLeast(analytics.recentEventLimit, minimum: 1, path: "analytics.recentEventLimit")
        validation.requireAtLeast(analytics.retentionDays, minimum: 1, path: "analytics.retentionDays")
        validation.requireAtLeast(
            reporting.minAttemptsForReport,
            minimum: 1,
            path: "reporting.minAttemptsForReport"
        )
        validation.requireIntegerCapacity(
            reporting.minAttemptsForReport,
            path: "reporting.minAttemptsForReport"
        )
        validation.requireAtLeast(reporting.runHistoryLimit, minimum: 1, path: "reporting.runHistoryLimit")
        validation.requireAtLeast(logging.maxRuns, minimum: 0, path: "logging.maxRuns")
    }

    private func validateYearRetrieval(using validation: inout ValidationCollector) {
        validateYearRateLimits(using: &validation)
        validateYearLogic(using: &validation)
        validateYearFallback(using: &validation)
        validateProviderSearch(using: &validation)
    }

    private func validateYearRateLimits(using validation: inout ValidationCollector) {
        validation.requireAtLeast(
            yearRetrieval.rateLimits.discogsRequestsPerMinute,
            minimum: 1,
            path: "yearRetrieval.rateLimits.discogsRequestsPerMinute"
        )
        validation.requireRateIntervalCapacity(
            requests: Double(yearRetrieval.rateLimits.discogsRequestsPerMinute),
            windowSeconds: 60,
            path: "yearRetrieval.rateLimits.discogsRequestsPerMinute"
        )
        validation.requireAtLeast(
            yearRetrieval.rateLimits.musicbrainzRequestsPerSecond,
            minimum: 0,
            path: "yearRetrieval.rateLimits.musicbrainzRequestsPerSecond"
        )
        validation.requireRateIntervalCapacity(
            requests: yearRetrieval.rateLimits.musicbrainzRequestsPerSecond,
            windowSeconds: 1,
            path: "yearRetrieval.rateLimits.musicbrainzRequestsPerSecond"
        )
        validation.requireGreaterThan(
            yearRetrieval.rateLimits.itunesRequestsPerSecond,
            minimum: 0,
            path: "yearRetrieval.rateLimits.itunesRequestsPerSecond"
        )
        validation.requireRateIntervalCapacity(
            requests: yearRetrieval.rateLimits.itunesRequestsPerSecond,
            windowSeconds: 1,
            path: "yearRetrieval.rateLimits.itunesRequestsPerSecond"
        )
        validation.requireAtLeast(
            yearRetrieval.requestTimeoutSeconds,
            minimum: 1,
            path: "yearRetrieval.requestTimeoutSeconds"
        )
        validation.requireMillisecondCapacity(
            yearRetrieval.requestTimeoutSeconds,
            path: "yearRetrieval.requestTimeoutSeconds"
        )
        validation.requireAtLeast(
            yearRetrieval.rateLimits.concurrentAlbums,
            minimum: 1,
            path: "yearRetrieval.rateLimits.concurrentAlbums"
        )
        validation.requireAtLeast(
            yearRetrieval.rateLimits.concurrentProviderCalls,
            minimum: 1,
            path: "yearRetrieval.rateLimits.concurrentProviderCalls"
        )
    }

    private func validateYearLogic(using validation: inout ValidationCollector) {
        validation.requireAtLeast(
            yearRetrieval.logic.minValidYear,
            minimum: 1000,
            path: "yearRetrieval.logic.minValidYear"
        )
        validation.requireAtLeast(
            yearRetrieval.logic.absurdYearThreshold,
            minimum: 1000,
            path: "yearRetrieval.logic.absurdYearThreshold"
        )
        validation.requireAtLeast(
            yearRetrieval.logic.suspicionThresholdYears,
            minimum: 0,
            path: "yearRetrieval.logic.suspicionThresholdYears"
        )
        validation.requireInRange(
            yearRetrieval.logic.definitiveScoreThreshold,
            range: 0 ... 100,
            path: "yearRetrieval.logic.definitiveScoreThreshold"
        )
        validation.requireAtLeast(
            yearRetrieval.logic.definitiveScoreDiff,
            minimum: 0,
            path: "yearRetrieval.logic.definitiveScoreDiff"
        )
        validation.requireInRange(
            yearRetrieval.logic.minConfidenceForNewYear,
            range: 0 ... 100,
            path: "yearRetrieval.logic.minConfidenceForNewYear"
        )
        validation.requireInRange(
            yearRetrieval.logic.cacheTrustThreshold,
            range: 0 ... 100,
            path: "yearRetrieval.logic.cacheTrustThreshold"
        )
        validation.requireInRange(
            yearRetrieval.logic.consensusYearConfidence,
            range: 0 ... 100,
            path: "yearRetrieval.logic.consensusYearConfidence"
        )
        validation.requireInRange(
            yearRetrieval.logic.dominantYearMinConfidence,
            range: 0 ... 1,
            path: "yearRetrieval.logic.dominantYearMinConfidence"
        )
    }

    private func validateYearFallback(using validation: inout ValidationCollector) {
        validation.requireAtLeast(
            yearRetrieval.fallback.yearDifferenceThreshold,
            minimum: 0,
            path: "yearRetrieval.fallback.yearDifferenceThreshold"
        )
        validation.requireInRange(
            yearRetrieval.fallback.trustAPIScoreThreshold,
            range: 0 ... 100,
            path: "yearRetrieval.fallback.trustAPIScoreThreshold"
        )
        validation.requireAtLeast(
            yearRetrieval.fallback.maxVerificationAttempts,
            minimum: 0,
            path: "yearRetrieval.fallback.maxVerificationAttempts"
        )
        validation.requireAtLeast(
            yearRetrieval.fallback.rerecordingAgeYears,
            minimum: 0,
            path: "yearRetrieval.fallback.rerecordingAgeYears"
        )
    }

    private func validateProviderSearch(using validation: inout ValidationCollector) {
        validation.requireInRange(
            yearRetrieval.discogsSearch.resultLimit,
            range: DiscogsSearchConfig.resultLimitRange,
            path: "yearRetrieval.discogsSearch.resultLimit"
        )
        validation.requireInRange(
            yearRetrieval.discogsSearch.detailLookupLimit,
            range: DiscogsSearchConfig.detailLookupLimitRange,
            path: "yearRetrieval.discogsSearch.detailLookupLimit"
        )
        validation.requireInRange(
            yearRetrieval.itunesSearch.limit,
            range: 1 ... 200,
            path: "yearRetrieval.itunesSearch.limit"
        )
    }
}

private struct MappingEntry {
    let source: String
    let target: String
    let normalizedSource: String
}

private struct ValidationCollector {
    private var issues: [ConfigurationValidationIssue] = []

    mutating func requireAtLeast(_ value: Int, minimum: Int, path: String) {
        guard value < minimum else { return }
        append(path: path, value: String(value), requirement: "must be at least \(minimum)")
    }

    mutating func requireAtLeast(_ value: Double, minimum: Double, path: String) {
        guard value.isFinite else {
            append(path: path, value: String(value), requirement: "must be finite")
            return
        }
        guard value < minimum else { return }
        append(path: path, value: String(value), requirement: "must be at least \(bound(minimum))")
    }

    mutating func requireGreaterThan(_ value: Double, minimum: Double, path: String) {
        guard value.isFinite else {
            append(path: path, value: String(value), requirement: "must be finite")
            return
        }
        guard value <= minimum else { return }
        append(path: path, value: String(value), requirement: "must be greater than \(bound(minimum))")
    }

    mutating func requireRateIntervalCapacity(requests: Double, windowSeconds: Double, path: String) {
        guard requests.isFinite, requests > 0 else { return }
        guard APIRateLimits.refillMilliseconds(requests: requests, perSeconds: windowSeconds) != nil else {
            append(path: path, value: String(requests), requirement: "must fit the pacing interval capacity")
            return
        }
    }

    mutating func requireMillisecondCapacity(_ value: Double, path: String) {
        guard value.isFinite else {
            append(path: path, value: String(value), requirement: "must be finite")
            return
        }

        let milliseconds = (value * 1000).rounded()
        guard milliseconds.isFinite,
              Int(exactly: milliseconds) != nil,
              Int64(exactly: milliseconds) != nil
        else {
            append(path: path, value: String(value), requirement: "must fit the millisecond duration capacity")
            return
        }
    }

    mutating func requireIntegerCapacity(_ value: Double, divisor: Double = 1, path: String) {
        guard value.isFinite else {
            append(path: path, value: String(value), requirement: "must be finite")
            return
        }
        guard Int(exactly: (value / divisor).rounded()) == nil else { return }
        append(path: path, value: String(value), requirement: "must fit integer conversion capacity")
    }

    mutating func requireInRange(_ value: Int, range: ClosedRange<Int>, path: String) {
        guard !range.contains(value) else { return }
        append(
            path: path,
            value: String(value),
            requirement: "must be between \(range.lowerBound) and \(range.upperBound)"
        )
    }

    mutating func requireInRange(_ value: Double, range: ClosedRange<Double>, path: String) {
        guard value.isFinite else {
            append(path: path, value: String(value), requirement: "must be finite")
            return
        }
        guard !range.contains(value) else { return }
        append(
            path: path,
            value: String(value),
            requirement: "must be between \(bound(range.lowerBound)) and \(bound(range.upperBound))"
        )
    }

    mutating func requireAtLeastSecond(_ value: Duration, path: String) {
        let seconds = value.timeInterval
        guard seconds.isFinite, Int(exactly: seconds.rounded(.towardZero)) != nil else {
            append(path: path, value: String(seconds), requirement: "must fit integer seconds")
            return
        }
        guard value < .seconds(1) else { return }
        append(path: path, value: String(Int(seconds)), requirement: "must be at least 1")
    }

    func finish() throws {
        guard !issues.isEmpty else { return }
        throw ConfigurationValidationError(issues: issues)
    }

    mutating func record(path: String, value: String, requirement: String) {
        append(path: path, value: value, requirement: requirement)
    }

    private mutating func append(path: String, value: String, requirement: String) {
        guard !issues.contains(where: { $0.fieldPath == path }) else { return }
        issues.append(ConfigurationValidationIssue(
            fieldPath: path,
            receivedValue: value,
            requirement: requirement
        ))
    }

    private func bound(_ value: Double) -> String {
        guard value.isFinite, value.rounded() == value else { return String(value) }
        return String(Int(value))
    }
}
