import Foundation

/// Protocol for cache operations (in-memory + persistent).
public protocol CacheService: Actor, Sendable {
    func initialize() async throws
    func get<T: Codable & Sendable>(key: String) async -> T?
    func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async
    func invalidate(key: String) async throws
    func clear() async
    func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry?
    func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async
    func invalidateAlbum(artist: String, album: String) async throws
    func invalidateAllAlbumYears() async
    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult?
    func setCachedAPIResult(_ result: CachedAPIResult) async
    func invalidateCachedAPIResults(artist: String, album: String) async throws
    func syncToDisk() async throws
}

/// Cache capability for values that must not expire by time.
public protocol PersistentCacheService: CacheService {
    /// Stores a value without time-based expiry; it remains removable by `invalidate(key:)`, `clear()`, or capacity
    /// eviction.
    func setPersistent(key: String, value: some Codable & Sendable) async

    /// Removes persistent values whose keys match both the prefix and one of the suffixes.
    /// Empty selectors are ignored so an invalid request cannot clear unrelated cache entries.
    func invalidatePersistentValues(keyPrefix: String, keySuffixes: [String]) async throws
}

public enum TrackStoreError: LocalizedError, Sendable, Equatable {
    case missingTrack(id: String)
    case missingDatabaseID(trackID: String)
    case nonCanonicalTrack(trackID: String, databaseID: MusicDatabaseTrackID)
    case emptySource
    case duplicateRepairSources(ids: [String])
    case duplicateRepairTargets(ids: [MusicDatabaseTrackID])
    case nonLegacyRepairSources(ids: [String])
    case unsafeAliasRetirement(ids: [String])
    case conflictingRepairEvidence(field: String, sourceIDs: [String])
    case redundantRepair(id: MusicDatabaseTrackID)
    case missingSource(id: String)
    case targetExists(id: MusicDatabaseTrackID)
    case duplicateUpserts(ids: [MusicDatabaseTrackID])
    case duplicateMembershipIDs(ids: [MusicDatabaseTrackID])
    case invalidMembershipIDs(ids: [String])
    case membershipStampMismatch(expected: MembershipStamp, actual: MembershipStamp)
    case operationsOutsideMembership(ids: [MusicDatabaseTrackID])
    case identityOverlap(ids: [MusicDatabaseTrackID])
    case identityCollisions(ids: [MusicDatabaseTrackID])
    case certificateRevisionMismatch(expected: MirrorRevision, actual: MirrorRevision)
    case certificateMembershipMismatch(expected: MembershipStamp, actual: MembershipStamp)
    case incompleteCertificate
    case invalidCertificateTrackCount(Int)
    case unsafeCertificatePreserve
    case unprovenCertificateRebase
    case invalidSyncRecord
    case appliedChangeIdentityConflict(id: UUID)

    public var errorDescription: String? {
        switch self {
        case let .missingTrack(id):
            "Track state store has no track with ID \(id)"
        case let .missingDatabaseID(trackID):
            "Track mirror upsert has no Music database ID for track ID \(trackID)"
        case let .nonCanonicalTrack(trackID, databaseID):
            "Track mirror upsert ID \(trackID) does not match Music database ID \(databaseID.rawValue)"
        case .emptySource:
            "Track mirror repair has an empty legacy source ID"
        case let .duplicateRepairSources(ids):
            "Track mirror update contains duplicate repair sources: \(ids.joined(separator: ", "))"
        case let .duplicateRepairTargets(ids):
            "Track mirror update contains duplicate repair targets: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .nonLegacyRepairSources(ids):
            "Track mirror repair sources are already canonical: \(ids.joined(separator: ", "))"
        case let .unsafeAliasRetirement(ids):
            "Track mirror aliases contain durable evidence and cannot be retired: \(ids.joined(separator: ", "))"
        case let .conflictingRepairEvidence(field, sourceIDs):
            "Track mirror aliases disagree on \(field): \(sourceIDs.joined(separator: ", "))"
        case let .redundantRepair(id):
            "Track mirror repair target \(id.rawValue) is already canonical"
        case let .missingSource(id):
            "Track mirror repair has no stored source with ID \(id)"
        case let .targetExists(id):
            "Track mirror repair target already exists with ID \(id.rawValue)"
        case let .duplicateUpserts(ids):
            "Track mirror update contains duplicate upsert IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .duplicateMembershipIDs(ids):
            "Track mirror update contains duplicate membership IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .invalidMembershipIDs(ids):
            "Stored track mirror membership contains invalid IDs: \(ids.joined(separator: ", "))"
        case let .membershipStampMismatch(expected, actual):
            "Track mirror membership stamp \(actual.fingerprint) does not match expected \(expected.fingerprint)"
        case let .operationsOutsideMembership(ids):
            "Track mirror operations target IDs outside current membership: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .identityOverlap(ids):
            "Track mirror update contains overlapping operation IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .identityCollisions(ids):
            "Track mirror upserts collide with noncanonical stored IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .certificateRevisionMismatch(expected, actual):
            "Scope certificate revision \(actual.value) does not match committed revision \(expected.value)"
        case let .certificateMembershipMismatch(expected, actual):
            "Scope certificate membership \(actual.fingerprint) does not match current membership \(expected.fingerprint)"
        case .incompleteCertificate:
            "Scope certificate requested and observed fingerprints do not match"
        case let .invalidCertificateTrackCount(count):
            "Scope certificate has invalid track count \(count)"
        case .unsafeCertificatePreserve:
            "Scope certificate preservation requires a maintenance-only mirror commit"
        case .unprovenCertificateRebase:
            "Scope certificate rebase lacks disjoint membership proof"
        case .invalidSyncRecord:
            "Mirror synchronization record does not match its atomic commit"
        case let .appliedChangeIdentityConflict(id):
            "Applied change ID \(id) already belongs to different durable evidence"
        }
    }
}

/// Repairs legacy persisted aliases to one authoritative Music database identity.
public struct TrackMirrorRepair: Sendable {
    public let sourceIDs: [String]
    public let target: Track

    public init(sourceIDs: [String], target: Track) {
        self.sourceIDs = sourceIDs
        self.target = target
    }
}

/// Minimal AppleScript identity used to classify one canonical library member.
public struct MemberIdentity: Equatable, Sendable {
    public let databaseID: MusicDatabaseTrackID
    public let artist: String?
    public let albumArtist: String?
    public let observedAt: Date

    public init(
        databaseID: MusicDatabaseTrackID,
        artist: String?,
        albumArtist: String?,
        observedAt: Date
    ) {
        self.databaseID = databaseID
        self.artist = artist
        self.albumArtist = albumArtist
        self.observedAt = observedAt
    }
}

/// Canonical-library membership and observed classification carried by one mirror mutation.
public enum InventoryChange: Equatable, Sendable {
    case preserve
    case replace(
        stamp: MembershipStamp,
        ids: [MusicDatabaseTrackID],
        identities: [MemberIdentity],
        observedAt: Date
    )
}

/// Protocol for persisting the track metadata mirror and processing state.
public protocol TrackStateStore: Actor {
    func initialize() async throws
    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot
    /// Atomically commits one coherent metadata-mirror mutation.
    @discardableResult
    func commitMirror(_ commit: MirrorCommit) async throws -> MirrorCommitResult
    func getTrack(byID id: String) async throws -> Track?
    func getHistoricalTrack(byID id: String) async throws -> Track?
    /// Atomically persists metadata, member classification, history, and a new
    /// mirror revision for a verified Music.app change. Repeating the same
    /// change ID returns the already committed revision without duplicating it.
    @discardableResult
    func commitAppliedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision
    /// Advances the mirror to a value already observed in Music.app without
    /// creating undo history for a write that made no physical change.
    @discardableResult
    func commitObservedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision
    /// Atomically applies a verified undo, removes the reverted history event,
    /// and advances the mirror revision when metadata changed.
    @discardableResult
    func commitRevertedChange(
        _ change: ChangeLogEntry,
        removingHistoryEntryID entryID: UUID
    ) async throws -> MirrorRevision
    /// Returns the first incomplete effect in stable originating-revision and sequence order.
    func nextPendingMirrorEffect() async throws -> PendingMirrorEffect?
    /// Returns incomplete effects in stable originating-revision and sequence order.
    func pendingMirrorEffects() async throws -> [PendingMirrorEffect]
    /// Marks an effect complete only after its idempotent target has succeeded.
    func completeMirrorEffect(id: UUID) async throws
    func getUnprocessedTracks() async throws -> [Track]
    func trackCount() async throws -> Int
}

extension TrackStateStore {
    public func getHistoricalTrack(byID id: String) async throws -> Track? {
        try await getTrack(byID: id)
    }

    public func nextPendingMirrorEffect() async throws -> PendingMirrorEffect? {
        try await pendingMirrorEffects().first
    }
}

/// Protocol for external music metadata API clients.
///
/// Implementations must bound every external request and throw when that request
/// reaches its deadline. External conformers must not return until the underlying
/// transport has physically completed or is guaranteed cancelled. GenreUpdater's
/// built-in clients invoked through `APIOrchestrator` may return a deadline error
/// while a non-cooperative transport finishes because they register that work with
/// the orchestrator's capacity lease.
/// Orchestration intentionally does not impose a separate queue or whole-service
/// timeout because those budgets would hide physical work.
public protocol ExternalAPIService: Sendable {
    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> [ReleaseCandidate]

    func getArtistActivityPeriod(normalizedArtist: String) async throws -> (start: Int?, end: Int?)
    func getArtistStartYear(normalizedArtist: String) async throws -> Int?
    /// The artist's region NAME for release-country scoring; nil when
    /// the lookup SUCCEEDED but found no region (cacheable miss). A
    /// transport/decoding failure THROWS so callers never confuse it
    /// with a confirmed absence. Only MusicBrainz answers.
    func getArtistRegion(artist: String) async throws -> String?
    func initialize(force: Bool) async throws
    func close() async
}

extension ExternalAPIService {
    public func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        []
    }

    public func initialize(force: Bool = false) async throws {
        try await initialize(force: force)
    }

    public func close() async {
        // Services without retained connections have nothing to release.
    }

    public func getArtistRegion(artist _: String) async throws -> String? {
        nil
    }
}

/// Protocol for managing albums that need manual year verification.
public protocol PendingVerificationService: Actor, Sendable {
    func initialize() async throws
    func markForVerification(
        artist: String,
        album: String,
        reason: String,
        metadata: [String: String]?,
        recheckDays: Int?
    ) async
    func removeFromPending(artist: String, album: String) async
    func getEntry(artist: String, album: String) async -> PendingAlbumEntry?
    func getAttemptCount(artist: String, album: String) async -> Int
    func isVerificationNeeded(artist: String, album: String) async -> Bool
    func getAllPendingAlbums() async -> [PendingAlbumEntry]
    func getPendingAlbums(reason: String) async -> [PendingAlbumEntry]
    func getDuePendingAlbums() async -> [PendingAlbumEntry]
    func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry])
    func getProblematicPendingAlbums(minAttempts: Int) async -> [ProblematicPendingAlbum]
    func shouldAutoVerify() async -> Bool
    func updateVerificationTimestamp() async throws
}

extension PendingVerificationService {
    public func getDuePendingAlbums() async -> [PendingAlbumEntry] {
        let allEntries = await getAllPendingAlbums()
        return await duePendingAlbums(from: allEntries)
    }

    public func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry]) {
        let allEntries = await getAllPendingAlbums()
        let dueEntries = await duePendingAlbums(from: allEntries)
        return (allEntries, dueEntries)
    }

    public func getPendingAlbums(reason: String) async -> [PendingAlbumEntry] {
        let normalizedReason = normalizedPendingVerificationReason(reason)
        return await getAllPendingAlbums().filter {
            normalizedPendingVerificationReason($0.reason) == normalizedReason
        }
    }

    public func getProblematicPendingAlbums(minAttempts _: Int) async -> [ProblematicPendingAlbum] {
        []
    }

    private func duePendingAlbums(from entries: [PendingAlbumEntry]) async -> [PendingAlbumEntry] {
        var dueEntries: [PendingAlbumEntry] = []
        for entry in entries {
            let isDue = await isVerificationNeeded(artist: entry.artist, album: entry.album)
            guard isDue else { continue }
            dueEntries.append(entry)
        }
        return dueEntries
    }
}

private func normalizedPendingVerificationReason(_ reason: String) -> String {
    let normalizedReason = reason
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()
    return normalizedReason == "pre_release" ? "prerelease" : normalizedReason
}

/// Token-bucket rate limiter for API calls.
public protocol RateLimiter: Actor {
    func acquire() async -> Duration
    func release()
    func getStats() -> RateLimiterStats
}

public struct RateLimiterStats: Sendable {
    public let totalRequests: Int
    public let totalWaitTime: Duration
    public let currentTokens: Int

    public init(totalRequests: Int, totalWaitTime: Duration, currentTokens: Int) {
        self.totalRequests = totalRequests
        self.totalWaitTime = totalWaitTime
        self.currentTokens = currentTokens
    }
}

/// Protocol for library snapshot persistence.
public protocol LibrarySnapshotService: Actor {
    func loadSnapshot() async throws -> [Track]?
    func saveSnapshot(_ tracks: [Track]) async throws -> String
    /// Invalidates cached tracks while retaining all snapshot metadata, including the force-refresh schedule.
    func clearSnapshot() async throws
    func isSnapshotValid() async -> Bool
    func getSnapshotMetadata() async -> LibraryCacheMetadata?
    func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws
    func getLibraryModificationDate() async throws -> Date
    var isEnabled: Bool { get }
}

/// Protocol for track processing operations.
public protocol TrackProcessor: Sendable {
    func updateArtist(
        track: Track,
        newArtistName: String,
        originalArtist: String?,
        updateAlbumArtist: Bool
    ) async throws -> Bool
}

extension TrackProcessor {
    public func updateArtist(
        track: Track,
        newArtistName: String,
        originalArtist: String? = nil,
        updateAlbumArtist: Bool = true
    ) async throws -> Bool {
        try await updateArtist(
            track: track,
            newArtistName: newArtistName,
            originalArtist: originalArtist,
            updateAlbumArtist: updateAlbumArtist
        )
    }
}

public protocol ChangeLogStore: Actor {
    func saveEntries(_ entries: [ChangeLogEntry]) async throws
    func loadAll() async throws -> [ChangeLogEntry]
    /// Newest-first bounded read for display surfaces; `loadAll` stays
    /// the undo/audit path.
    func loadRecent(limit: Int) async throws -> [ChangeLogEntry]
    func delete(entryID: UUID) async throws
    func deleteAll() async throws
}

public protocol TrackIDMapping: Sendable {
    func appleScriptID(forMusicKitID musicKitID: String) async -> String?
    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track?
    func hasMappingFor(musicKitID: String) async -> Bool
}

public protocol AnalyticsService: Sendable {
    /// Records one privacy-safe operation result.
    func record(_ operation: AnalyticsOperation, duration: Duration, outcome: AnalyticsOutcome) async
}

extension AnalyticsService {
    /// Measures an async operation while preserving its value and error behavior.
    public func measure<Value: Sendable>(
        _ operation: AnalyticsOperation,
        isolation _: isolated (any Actor)? = #isolation,
        errorOutcome: @Sendable (any Error, Bool) -> AnalyticsOutcome = {
            AnalyticsOutcome(error: $0, isTaskCancelled: $1)
        },
        body: () async throws -> Value
    ) async rethrows -> Value {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            let value = try await body()
            await record(operation, duration: start.duration(to: clock.now), outcome: .succeeded)
            return value
        } catch {
            await record(
                operation,
                duration: start.duration(to: clock.now),
                outcome: errorOutcome(error, Task.isCancelled)
            )
            throw error
        }
    }
}
