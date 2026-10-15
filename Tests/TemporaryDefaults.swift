import Foundation
import Testing

/// UserDefaults whose plist lives in a private temporary directory.
///
/// A named suite writes to `~/Library/Preferences`, and `removePersistentDomain(forName:)`
/// leaves an empty plist behind after every run. An absolute-path suite keeps the plist in the
/// temporary directory, and `remove()` deletes it together with the directory.
/// The Services package tests keep a twin of this helper in
/// `Packages/Services/Tests/ServicesTests/TemporaryDefaults.swift`.
struct TemporaryDefaults {
    let defaults: UserDefaults
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
