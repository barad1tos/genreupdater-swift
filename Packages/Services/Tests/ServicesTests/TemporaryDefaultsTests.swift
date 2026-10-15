import Foundation
import Testing

// Byte-identical twins: Tests/TemporaryDefaultsTests.swift and
// Packages/Services/Tests/ServicesTests/TemporaryDefaultsTests.swift; change both together.

@Suite("TemporaryDefaults — UserDefaults stored in a private temporary directory")
struct TemporaryDefaultsTests {
    private static let key = "discogsCredentialRevision"

    /// UserDefaults persists changes asynchronously, so the tests poll. The timeout is generous
    /// because Swift Testing runs tests in parallel, and under that load on CI even tests without
    /// I/O take many seconds of wall time.
    private static let timeout = Duration.seconds(30)

    @Test("A written value lands in a plist inside the temporary directory")
    func persistsInDirectory() async throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let plistPath = temporaryDefaults.suiteName + ".plist"
        let value = UUID().uuidString

        temporaryDefaults.defaults.set(value, forKey: Self.key)

        let isPersisted = try await waitForValue(value, inPlistAt: plistPath)
        let diagnosis = describeDirectory(of: plistPath)
        #expect(isPersisted, "No written value in \(plistPath) after at least \(Self.timeout); \(diagnosis)")
    }

    @Test("Removing the defaults deletes its temporary directory")
    func removeDeletesDirectory() async throws {
        let temporaryDefaults = try TemporaryDefaults()
        let plistPath = temporaryDefaults.suiteName + ".plist"
        let directoryPath = URL(fileURLWithPath: plistPath).deletingLastPathComponent().path
        let value = UUID().uuidString
        temporaryDefaults.defaults.set(value, forKey: Self.key)
        try #require(await waitForValue(value, inPlistAt: plistPath))

        temporaryDefaults.remove()

        #expect(!FileManager.default.fileExists(atPath: directoryPath))
    }

    private func waitForValue(_ value: String, inPlistAt path: String) async throws -> Bool {
        let deadline = ContinuousClock.now + Self.timeout
        while ContinuousClock.now < deadline {
            if storedValue(inPlistAt: path) == value {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return storedValue(inPlistAt: path) == value
    }

    private func storedValue(inPlistAt path: String) -> String? {
        NSDictionary(contentsOfFile: path)?[Self.key] as? String
    }

    private func describeDirectory(of path: String) -> String {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: directory) else {
            return "directory \(directory) is missing"
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return "directory \(directory) is unreadable"
        }
        return "directory \(directory) holds \(entries)"
    }
}
