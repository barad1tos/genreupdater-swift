import Foundation
import Testing

/// UserDefaults whose plist lives in a private temporary directory.
///
/// A named suite writes to `~/Library/Preferences`, and `removePersistentDomain(forName:)` leaves an
/// empty plist there; deleting that file right away does not stick, because cfprefsd writes it back.
/// Given an absolute path as its suite name, UserDefaults stores the domain in `<suiteName>.plist`,
/// so the plist stays in the temporary directory and `remove()` deletes it with the directory.
/// Apple documents plist-path domains only for `defaults(1)`, so `TemporaryDefaultsTests` pins it.
/// Call `remove()` last: a write after it creates the directory again.
/// The ServicesTests target keeps a twin of this helper in
/// `Packages/Services/Tests/ServicesTests/TemporaryDefaults.swift`; change both together.
struct TemporaryDefaults {
    let defaults: UserDefaults
    /// Absolute plist path without the `.plist` extension; any `UserDefaults(suiteName:)` opened
    /// with it shares this store.
    let suiteName: String
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemporaryDefaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = directory.appendingPathComponent("defaults").path
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
