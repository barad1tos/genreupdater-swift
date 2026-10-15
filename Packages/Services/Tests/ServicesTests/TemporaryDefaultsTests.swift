import Foundation
import Testing

@Suite("TemporaryDefaults — UserDefaults kept out of ~/Library/Preferences")
struct TemporaryDefaultsTests {
    @Test("A written value lands in the temporary directory instead of ~/Library/Preferences")
    func persistsInsideTemporaryDirectory() async throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let plistPath = temporaryDefaults.suiteName + ".plist"

        temporaryDefaults.defaults.set(UUID().uuidString, forKey: "discogsCredentialRevision")

        // cfprefsd writes the plist asynchronously, so poll instead of checking once.
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: plistPath), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            FileManager.default.fileExists(atPath: plistPath),
            "UserDefaults wrote the suite outside its temporary directory"
        )
    }
}
