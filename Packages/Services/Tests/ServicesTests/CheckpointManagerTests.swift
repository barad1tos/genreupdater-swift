import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Tests

@Suite("CheckpointManager — save/load/cleanup batch checkpoints")
struct CheckpointManagerTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeCheckpoint(
        batchID: UUID = UUID(),
        processedIDs: [String] = ["T1", "T2"],
        totalCount: Int = 10,
        lastIndex: Int = 1,
        timestamp: Date = Date(),
        requiresRecovery: Bool = false
    ) -> BatchCheckpoint {
        BatchCheckpoint(
            batchID: batchID,
            processedTrackIDs: processedIDs,
            totalCount: totalCount,
            lastProcessedIndex: lastIndex,
            timestamp: timestamp,
            changes: [],
            requiresRecovery: requiresRecovery
        )
    }

    @Test("Save and load round-trip preserves all fields")
    func saveLoadRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let batchID = UUID()
        let checkpoint = makeCheckpoint(
            batchID: batchID,
            processedIDs: ["T1", "T2", "T3"],
            totalCount: 100,
            lastIndex: 2
        )

        try await manager.save(checkpoint)
        let loaded = try await manager.load(batchID: batchID)

        #expect(loaded != nil)
        #expect(loaded?.batchID == batchID)
        #expect(loaded?.processedTrackIDs == ["T1", "T2", "T3"])
        #expect(loaded?.totalCount == 100)
        #expect(loaded?.lastProcessedIndex == 2)
        #expect(loaded?.requiresRecovery == false)
    }

    @Test("Legacy checkpoint defaults to no recovery hold")
    func decodesLegacyCheckpoint() throws {
        let batchID = UUID()
        let data = Data("""
        {"batchID":"\(batchID
            .uuidString)","processedTrackIDs":[],"totalCount":1,"lastProcessedIndex":-1,"timestamp":"2026-07-11T00:00:00Z","changes":[]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let checkpoint = try decoder.decode(BatchCheckpoint.self, from: data)

        #expect(!checkpoint.requiresRecovery)
    }

    @Test("Load recovery returns the newest recovery checkpoint")
    func loadsRecoveryCheckpoint() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let normal = makeCheckpoint(timestamp: Date(), requiresRecovery: false)
        let recovery = makeCheckpoint(timestamp: Date().addingTimeInterval(-1), requiresRecovery: true)
        try await manager.save(normal)
        try await manager.save(recovery)

        #expect(try await manager.loadRecovery()?.batchID == recovery.batchID)
        try await manager.clearRecovery(batchID: recovery.batchID)
    }

    @Test("Recovery marker survives a corrupt checkpoint file")
    func loadsCorruptRecoveryMarker() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let suiteName = temporaryDefaults.suiteName
        let manager = CheckpointManager(directory: dir, recoverySuiteName: suiteName)
        let recovery = makeCheckpoint(requiresRecovery: true)
        try await manager.save(recovery)
        let file = dir.appendingPathComponent("checkpoints/\(recovery.batchID.uuidString).json")
        try Data("invalid".utf8).write(to: file)

        let restarted = CheckpointManager(directory: dir, recoverySuiteName: suiteName)
        let loaded = try await restarted.loadRecovery()

        #expect(loaded?.batchID == recovery.batchID)
        #expect(loaded?.requiresRecovery == true)
        try await restarted.clearRecovery(batchID: recovery.batchID)
    }

    @Test("Load returns nil for nonexistent batch")
    func loadNonexistent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let result = try await manager.load(batchID: UUID())
        #expect(result == nil)
    }

    @Test("Load latest returns most recent checkpoint")
    func loadLatest() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)

        let older = makeCheckpoint(
            timestamp: Date().addingTimeInterval(-3600)
        )
        let newer = makeCheckpoint(
            timestamp: Date()
        )

        try await manager.save(older)
        try await manager.save(newer)

        let latest = try await manager.loadLatest()
        #expect(latest?.batchID == newer.batchID)
    }

    @Test("Delete removes checkpoint file")
    func delete() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let batchID = UUID()

        try await manager.save(makeCheckpoint(batchID: batchID))
        let loaded = try await manager.load(batchID: batchID)
        #expect(loaded != nil)

        try await manager.delete(batchID: batchID)
        let deleted = try await manager.load(batchID: batchID)
        #expect(deleted == nil)
    }

    @Test("Delete nonexistent batch does not throw")
    func deleteNonexistent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        try await manager.delete(batchID: UUID())
    }

    @Test("Cleanup removes old checkpoints")
    func cleanupOld() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)

        let old = makeCheckpoint(
            timestamp: Date().addingTimeInterval(-8 * 24 * 3600)
        )
        let recent = makeCheckpoint(
            timestamp: Date()
        )

        try await manager.save(old)
        try await manager.save(recent)

        try await manager.cleanupOld(olderThan: 7 * 24 * 3600)

        let oldLoaded = try await manager.load(batchID: old.batchID)
        let recentLoaded = try await manager.load(batchID: recent.batchID)
        #expect(oldLoaded == nil)
        #expect(recentLoaded != nil)
    }

    @Test("Cleanup preserves recovery checkpoints")
    func cleanupPreservesRecovery() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let recovery = makeCheckpoint(
            timestamp: Date().addingTimeInterval(-8 * 24 * 3600),
            requiresRecovery: true
        )
        try await manager.save(recovery)

        try await manager.cleanupOld(olderThan: 7 * 24 * 3600)

        #expect(try await manager.load(batchID: recovery.batchID) != nil)
        try await manager.clearRecovery(batchID: recovery.batchID)
    }

    @Test("Corrupt JSON returns nil instead of throwing")
    func corruptionHandling() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let batchID = UUID()

        let checkpointDir = dir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        let filePath = checkpointDir.appendingPathComponent("\(batchID.uuidString).json")
        let invalidData = Data("{ invalid json".utf8)
        try invalidData.write(to: filePath)

        let loaded = try await manager.load(batchID: batchID)
        #expect(loaded == nil)
        #expect(try await manager.loadRecovery() == nil)
    }

    @Test("An unparseable recovery marker is discarded, not replaced with a phantom hold")
    func unparseableRecoveryMarkerIsDiscarded() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The manager keys the marker on its own checkpoints subdirectory.
        let markerKey = "com.genreupdater.recovery."
            + dir.appendingPathComponent("checkpoints", isDirectory: true).path
        UserDefaults.standard.set("not-a-uuid", forKey: markerKey)
        defer { UserDefaults.standard.removeObject(forKey: markerKey) }

        let manager = CheckpointManager(directory: dir)

        // Minting a replacement id would name a batch that never existed, and
        // loadRecovery would hand back a placeholder for it — a hold nothing
        // on disk can justify, which also masks any real pending recovery.
        #expect(try await manager.loadRecovery() == nil)
        #expect(UserDefaults.standard.string(forKey: markerKey) == nil)
    }

    @Test("Load latest with empty directory returns nil")
    func loadLatestEmpty() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let result = try await manager.loadLatest()
        #expect(result == nil)
    }
}
