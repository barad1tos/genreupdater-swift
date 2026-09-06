import Core
import Services
import SharedUI
import SwiftUI

// MARK: - API & Cache Tab

struct APICacheTab: View {
    @Environment(AppDependencies.self) var dependencies
    @AppStorage("contactEmail") private var contactEmail = ""
    @State private var tokenInput = ""
    @State var discogsHostInput = APIAuthConfig.defaultDiscogsBaseHost
    @State private var tokenStatus: TokenStatus = .unknown
    @State private var statusMessage = ""
    @State private var cacheStatistics: CacheStatistics?
    @State private var isLoadingStatistics = false
    @State private var isClearingCache = false
    @State var isSyncingLibrary = false
    @State var librarySyncStatus = ""

    var body: some View {
        Form {
            contactSection
            yearLookupSection
            ITunesSearchSection(dependencies: dependencies)
            ScriptAPIPrioritySection(dependencies: dependencies)
            discogsSection
            cacheStatisticsSection
            librarySyncSection
            FeatureGatedView(feature: .advancedCache) {
                cacheBehaviorSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            loadTokenStatus()
            loadDiscogsHostInput()
            loadCacheStatistics()
        }
    }

    private var contactSection: some View {
        Section {
            TextField("Contact Email", text: $contactEmail)
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("Contact Information")
        } footer: {
            Text("Required by MusicBrainz, recommended by Discogs.")
        }
    }

    private var yearLookupSection: some View {
        Section("Year Lookup") {
            Toggle("Enable year lookup", isOn: configBinding(dependencies, \.yearRetrieval.enabled))

            Picker("Preferred API", selection: configBinding(dependencies, \.yearRetrieval.preferredAPI)) {
                ForEach(PreferredAPI.allCases, id: \.self) { api in
                    Text(api.displayName).tag(api)
                }
            }
            .pickerStyle(.segmented)

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.rateLimits.discogsRequestsPerMinute),
                in: APIRateLimits.discogsSettingsRange
            ) {
                LabeledContent(
                    "Discogs requests per minute",
                    value: "\(dependencies.config.yearRetrieval.rateLimits.discogsRequestsPerMinute)"
                )
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond),
                in: APIRateLimits.musicBrainzSettingsRange,
                step: 0.1
            ) {
                LabeledContent(
                    "MusicBrainz requests per second",
                    value: Self.musicBrainzRateText(
                        dependencies.config.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond
                    )
                )
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.rateLimits.itunesRequestsPerSecond),
                in: APIRateLimits.itunesSettingsRange,
                step: 0.1
            ) {
                LabeledContent(
                    "iTunes requests per second",
                    value: dependencies.config.yearRetrieval.rateLimits.itunesRequestsPerSecond
                        .formatted(.number.precision(.fractionLength(1)))
                )
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.requestTimeoutSeconds),
                in: YearRetrievalConfig.timeoutSettingsRange,
                step: 1
            ) {
                LabeledContent(
                    "Request timeout",
                    value: Self.requestTimeoutText(dependencies.config.yearRetrieval.requestTimeoutSeconds)
                )
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.rateLimits.concurrentAlbums),
                in: APIRateLimits.albumConcurrencyRange
            ) {
                LabeledContent(
                    "Concurrent albums",
                    value: "\(dependencies.config.yearRetrieval.rateLimits.concurrentAlbums)"
                )
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.rateLimits.concurrentProviderCalls),
                in: APIRateLimits.providerConcurrencyRange
            ) {
                LabeledContent(
                    "Concurrent provider calls",
                    value: "\(dependencies.config.yearRetrieval.rateLimits.concurrentProviderCalls)"
                )
            }

            Stepper(value: configBinding(dependencies, \.runtime.maxRetries), in: 0 ... 10) {
                LabeledContent("API retries", value: "\(dependencies.config.runtime.maxRetries)")
            }

            Stepper(value: configBinding(dependencies, \.runtime.retryDelaySeconds), in: 0 ... 30, step: 0.5) {
                LabeledContent(
                    "API retry delay",
                    value: dependencies.config.runtime.retryDelaySeconds
                        .formatted(.number.precision(.fractionLength(1))) + "s"
                )
            }
        }
    }

    static func musicBrainzRateText(_ configuredRate: Double) -> String {
        let effectiveRate = APIRateLimits.musicBrainzRate(configuredRate)
            .formatted(.number.precision(.fractionLength(1)))
        return configuredRate == 0 ? "\(effectiveRate) (legacy setting: 0)" : effectiveRate
    }

    static func requestTimeoutText(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(0 ... 1))) + "s"
    }

    private var discogsSection: some View {
        Section {
            SecureField("Discogs Personal Access Token", text: $tokenInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: Spacing.sm) {
                Button("Save Token") { saveToken() }
                    .disabled(isTokenSaveDisabled)
                Button("Delete Token", role: .destructive) { deleteToken() }
                Button("Test Token") { testToken() }
            }

            HStack(spacing: 6) {
                Image(systemName: tokenStatus.symbolName)
                    .foregroundStyle(tokenStatus.color)
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if let credentialIssue = dependencies.discogsCredentialIssue {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Ayu.warning)
                    Text(credentialIssue.message)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.discogsSearch.resultLimit),
                in: DiscogsSearchConfig.resultLimitRange
            ) {
                LabeledContent(
                    "Search results per request",
                    value: "\(dependencies.config.yearRetrieval.discogsSearch.resultLimit)"
                )
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.discogsSearch.detailLookupLimit),
                in: DiscogsSearchConfig.detailLookupLimitRange
            ) {
                LabeledContent(
                    "Missing-year release lookups",
                    value: "\(dependencies.config.yearRetrieval.discogsSearch.detailLookupLimit)"
                )
            }

            Text(
                "Higher limits can recover more release years but use more Discogs requests and may make runs slower. "
                    + "Set detail lookups to 0 to skip release-detail recovery requests for missing years; "
                    + "canonical master lookups may still occur."
            )
            .foregroundStyle(.secondary)
            .font(.caption)

            discogsHostEditor
        } header: {
            Text("Discogs API")
        }
    }

    private var cacheStatisticsSection: some View {
        Section("Cache Statistics") {
            if let statistics = cacheStatistics {
                LabeledContent("Album year entries", value: "\(statistics.albumYearCount)")
                LabeledContent("API result entries", value: "\(statistics.apiResultCount)")
                LabeledContent("Generic cache entries", value: "\(statistics.genericCacheCount)")
                LabeledContent("Expired entries", value: "\(statistics.expiredCount)")
            } else if isLoadingStatistics {
                ProgressView("Loading statistics...")
            } else {
                Text("No cache data available")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh") { loadCacheStatistics() }
                    .disabled(isLoadingStatistics)
                Button("Clear Cache", role: .destructive) { clearCache() }
                    .disabled(isClearingCache || dependencies.cacheService == nil)
            }
        }
    }

    private var cacheBehaviorSection: some View {
        Section("Cache Behavior") {
            Stepper(value: configBinding(dependencies, \.caching.defaultTTLSeconds), in: 60 ... 86400, step: 60) {
                LabeledContent("Default TTL", value: "\(dependencies.config.caching.defaultTTLSeconds / 60)m")
            }

            Stepper(value: configBinding(dependencies, \.runtime.cacheTTLSeconds), in: 60 ... 86400, step: 60) {
                LabeledContent("Runtime cache TTL", value: "\(dependencies.config.runtime.cacheTTLSeconds / 60)m")
            }

            Stepper(value: configBinding(dependencies, \.runtime.maxGenericEntries), in: 1000 ... 100_000, step: 1000) {
                LabeledContent("Generic cache limit", value: "\(dependencies.config.runtime.maxGenericEntries)")
            }

            Stepper(value: configBinding(dependencies, \.caching.cleanupIntervalSeconds), in: 0 ... 86400, step: 60) {
                LabeledContent("Expired entry cleanup", value: cleanupIntervalDisplay)
            }

            Stepper(value: configBinding(dependencies, \.processing.cacheTTLDays), in: 1 ... 36500) {
                LabeledContent("API result cache", value: apiResultCacheTTLDisplay)
            }

            Stepper(
                value: configBinding(dependencies, \.caching.negativeResultTTL),
                in: 0 ... 7_776_000,
                step: 3600
            ) {
                LabeledContent("Confirmed miss retry", value: negativeResultTTLDisplay)
            }

            Text(
                "Longer values reduce API calls but may delay newly indexed releases. " +
                    "Off retries every eligible lookup."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Library snapshot cache", isOn: configBinding(dependencies, \.caching.librarySnapshot.enabled))

            Stepper(value: configBinding(dependencies, \.caching.librarySnapshot.maxAgeHours), in: 1 ... 168) {
                LabeledContent("Snapshot max age", value: "\(dependencies.config.caching.librarySnapshot.maxAgeHours)h")
            }
            .disabled(!isLibrarySnapshotEnabled)
        }
    }

    private var apiResultCacheTTLDisplay: String {
        let days = dependencies.config.processing.cacheTTLDays
        guard days > 0 else { return "Default" }

        if days >= 365, days.isMultiple(of: 365) {
            return "\(days / 365)y"
        }

        return "\(days)d"
    }

    private var negativeResultTTLDisplay: String {
        let seconds = dependencies.config.caching.negativeResultTTL
        guard seconds > 0 else { return "Off" }

        let days = Int(seconds / 86400)
        if days >= 1 {
            return "\(days)d"
        }

        let hours = Int(seconds / 3600)
        return "\(max(1, hours))h"
    }

    private var cleanupIntervalDisplay: String {
        let seconds = dependencies.config.caching.cleanupIntervalSeconds
        guard seconds > 0 else { return "Off" }

        let days = seconds / 86400
        if days >= 1 {
            return "\(days)d"
        }

        let hours = seconds / 3600
        if hours >= 1 {
            return "\(hours)h"
        }

        return "\(max(1, seconds / 60))m"
    }

    private var isLibrarySnapshotEnabled: Bool {
        dependencies.config.caching.librarySnapshot.enabled
    }

    private var isTokenSaveDisabled: Bool {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadTokenStatus() {
        do {
            if let existing = try DiscogsClient.retrieveSavedToken(),
               !existing.isEmpty {
                tokenStatus = .saved
                statusMessage = "Token saved (\(existing.prefix(4))...)"
            } else {
                tokenStatus = .missing
                statusMessage = "No token configured"
            }
        } catch {
            tokenStatus = .error
            statusMessage = "Failed to read Keychain: \(error.localizedDescription)"
        }
    }

    private func saveToken() {
        do {
            let saveResult = try DiscogsClient.saveToken(tokenInput)
            tokenInput = ""
            switch saveResult {
            case .protected:
                tokenStatus = .saved
                statusMessage = "Token saved with local authentication"
            case .localFallback:
                tokenStatus = .localFallback
                statusMessage = "Token saved in local Keychain fallback for this unsigned development build"
            }
            reapplyRuntimeAfterTokenChange()
        } catch {
            tokenStatus = .error
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// A token change is a user-intended credential-availability flip:
    /// re-probe through the serialized apply queue, which also refreshes
    /// the fix-plan projection so a hasDiscogsAccess change surfaces.
    private func reapplyRuntimeAfterTokenChange() {
        dependencies.enqueueRuntimeApplyAndPublish()
    }

    private func deleteToken() {
        do {
            try DiscogsClient.deleteSavedToken()
            tokenInput = ""
            tokenStatus = .missing
            statusMessage = "Token deleted"
            reapplyRuntimeAfterTokenChange()
        } catch {
            tokenStatus = .error
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func testToken() {
        do {
            if let token = try DiscogsClient.retrieveSavedToken(),
               !token.isEmpty {
                tokenStatus = .saved
                statusMessage = "Token is present (\(token.count) characters)"
            } else {
                tokenStatus = .missing
                statusMessage = "No token found — save one first"
            }
        } catch {
            tokenStatus = .error
            statusMessage = "Test failed: \(error.localizedDescription)"
        }
    }

    private func loadCacheStatistics() {
        isLoadingStatistics = true
        Task {
            cacheStatistics = await dependencies.cacheService?.getCacheStatistics()
            isLoadingStatistics = false
        }
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await dependencies.cacheService?.clear()
            cacheStatistics = nil
            isClearingCache = false
            loadCacheStatistics()
        }
    }
}

// MARK: - Script API Priority Section

struct ScriptAPIPrioritySection: View {
    let dependencies: AppDependencies

    var body: some View {
        Section("Script API Priority") {
            ForEach(scriptPriorityRows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 8) {
                        Picker("First", selection: scriptPriorityBinding(row.key, slot: .first)) {
                            scriptAPIPickerOptions
                        }
                        .frame(maxWidth: 160)

                        Picker("Second", selection: scriptPriorityBinding(row.key, slot: .second)) {
                            scriptAPIPickerOptions
                        }
                        .frame(maxWidth: 160)

                        Picker("Fallback", selection: scriptPriorityBinding(row.key, slot: .fallback)) {
                            scriptAPIPickerOptions
                        }
                        .frame(maxWidth: 160)
                    }
                    .pickerStyle(.menu)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var scriptAPIPickerOptions: some View {
        ForEach(PreferredAPI.allCases, id: \.self) { api in
            Text(api.displayName).tag(api)
        }
    }

    private var scriptPriorityRows: [ScriptPriorityRow] {
        [
            ScriptPriorityRow(key: "default", title: "Default"),
            ScriptPriorityRow(key: "cyrillic", title: "Cyrillic"),
            ScriptPriorityRow(key: "japanese", title: "Japanese"),
            ScriptPriorityRow(key: "korean", title: "Korean"),
            ScriptPriorityRow(key: "chinese", title: "Chinese"),
        ]
    }

    private func scriptPriorityBinding(_ key: String, slot: ScriptPrioritySlot) -> Binding<PreferredAPI> {
        Binding(
            get: { scriptPriorityOrder(for: key)[slot.index] },
            set: { newValue in
                updateScriptPriority(key, slot: slot, api: newValue)
            }
        )
    }

    func updateScriptPriority(_ key: String, slot: ScriptPrioritySlot, api: PreferredAPI) {
        var order = scriptPriorityOrder(for: key)
        order.removeAll { $0 == api }
        order.insert(api, at: min(slot.index, order.count))

        let newPriority = ScriptAPIPriority(
            primary: order.prefix(2).map { apiConfigurationValue(for: $0) },
            fallback: order.dropFirst(2).prefix(1).map { apiConfigurationValue(for: $0) }
        )
        mutateConfiguration(dependencies) { configuration in
            configuration.yearRetrieval.scriptAPIPriorities[key] = newPriority
        }
    }

    private func scriptPriorityOrder(for key: String) -> [PreferredAPI] {
        let priority = scriptPriority(for: key)
        let configuredOrder = (priority.primary + priority.fallback).compactMap { preferredAPI(from: $0) }
        return uniqued(configuredOrder + [.musicbrainz, .discogs, .itunes]).prefix(3).map(\.self)
    }

    private func scriptPriority(for key: String) -> ScriptAPIPriority {
        if let priority = dependencies.config.yearRetrieval.scriptAPIPriorities[key] {
            return priority
        }
        if key != "default", let defaultPriority = dependencies.config.yearRetrieval.scriptAPIPriorities["default"] {
            return defaultPriority
        }
        return ScriptAPIPriority(primary: ["musicbrainz", "discogs"], fallback: ["itunes"])
    }

    private func preferredAPI(from configurationValue: String) -> PreferredAPI? {
        switch configurationValue.lowercased().replacingOccurrences(of: "_", with: "") {
        case "musicbrainz", "mb": .musicbrainz
        case "discogs": .discogs
        case "itunes", "applemusic", "apple": .itunes
        default: nil
        }
    }

    private func apiConfigurationValue(for api: PreferredAPI) -> String {
        api.rawValue
    }

    private func uniqued(_ apis: [PreferredAPI]) -> [PreferredAPI] {
        var seen: Set<PreferredAPI> = []
        return apis.filter { api in
            seen.insert(api).inserted
        }
    }
}

enum ScriptPrioritySlot {
    case first
    case second
    case fallback

    var index: Int {
        switch self {
        case .first: 0
        case .second: 1
        case .fallback: 2
        }
    }
}

private struct ScriptPriorityRow: Identifiable {
    let key: String
    let title: String

    var id: String {
        key
    }
}
private enum TokenStatus {
    case unknown, saved, localFallback, missing, error

    var symbolName: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .saved: "checkmark.circle.fill"
        case .localFallback: "exclamationmark.triangle.fill"
        case .missing: "xmark.circle"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .secondary
        case .saved: Ayu.success
        case .localFallback: Ayu.warning
        case .missing: Ayu.warning
        case .error: Ayu.error
        }
    }
}
