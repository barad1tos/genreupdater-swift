import Foundation
import Testing

@Suite("TemporaryDefaults — UserDefaults kept out of ~/Library/Preferences")
struct TemporaryDefaultsTests {
    @Test("A written value lands in a plist inside the temporary directory")
    func persistsInDirectory() async throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let plistPath = temporaryDefaults.suiteName + ".plist"
        let directoryPath = URL(fileURLWithPath: temporaryDefaults.suiteName).deletingLastPathComponent().path

        temporaryDefaults.defaults.set(UUID().uuidString, forKey: "discogsCredentialRevision")

        // UserDefaults persists changes asynchronously, so poll. The timeout is generous because
        // Swift Testing runs tests in parallel, and under that load on CI even tests without
        // I/O take many seconds of wall time.
        let timeout = Duration.seconds(30)
        let deadline = ContinuousClock.now + timeout
        while !FileManager.default.fileExists(atPath: plistPath), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: directoryPath))?.description ?? "unreadable"
        #expect(
            FileManager.default.fileExists(atPath: plistPath),
            "No plist at \(plistPath) after waiting \(timeout); directory listing: \(listing)"
        )
    }

    @Test("Removing the defaults deletes its temporary directory")
    func removeDeletesDirectory() throws {
        let temporaryDefaults = try TemporaryDefaults()
        let directoryPath = URL(fileURLWithPath: temporaryDefaults.suiteName).deletingLastPathComponent().path
        temporaryDefaults.defaults.set(UUID().uuidString, forKey: "discogsCredentialRevision")

        temporaryDefaults.remove()

        #expect(!FileManager.default.fileExists(atPath: directoryPath))
    }
}
