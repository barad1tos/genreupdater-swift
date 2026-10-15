import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("App process mode")
struct AppProcessModeTests {
    @Test("Injected unit-test hosts use isolated persistence without live startup")
    func unitTestHostPolicy() {
        let mode = AppProcessMode(environment: [
            "XCTestConfigurationFilePath": "injected",
        ])

        #expect(mode == .unitTestHost)
        #expect(!mode.shouldUsePersistentStorage)
        #expect(!mode.shouldStartLiveServices)
    }

    @Test("Ordinary app processes retain persistent storage and live startup")
    func applicationPolicy() {
        let mode = AppProcessMode(environment: [:])

        #expect(mode == .application)
        #expect(mode.shouldUsePersistentStorage)
        #expect(mode.shouldStartLiveServices)
    }

    @Test("Unit-test hosts never load the persisted application configuration")
    func unitTestHostConfigurationIsInMemory() throws {
        var applicationLoadCount = 0

        let configuration = try loadProcessConfiguration(for: .unitTestHost) {
            applicationLoadCount += 1
            return AppConfiguration()
        }

        #expect(applicationLoadCount == 0)
        #expect(configuration.revision == 0)
    }

    @Test("Application processes retain the persisted configuration loader")
    func applicationConfigurationUsesStorageLoader() throws {
        var persistedConfiguration = AppConfiguration()
        persistedConfiguration.revision = 42
        var applicationLoadCount = 0

        let configuration = try loadProcessConfiguration(for: .application) {
            applicationLoadCount += 1
            return persistedConfiguration
        }

        #expect(applicationLoadCount == 1)
        #expect(configuration.revision == 42)
    }

    @MainActor
    @Test("Default unit-test dependencies never connect to the live MusicKit catalog")
    func defaultCatalogIsInactive() async {
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })

        #expect(await !dependencies.musicCatalog.isAuthorized)
        do {
            let snapshot = try await dependencies.musicCatalog.loadCatalog()
            Issue.record("Unit-test catalog reached the live library and returned \(snapshot.tracks.count) tracks")
        } catch let error as MusicLibraryError {
            guard case .musicAppNotAvailable = error else {
                Issue.record("Expected an inactive unit-test catalog, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MusicLibraryError.musicAppNotAvailable, got \(error)")
        }
    }

    @MainActor
    @Test("Direct unit-test initialization never starts live services")
    func directInitializationIsInert() async throws {
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let defaults = temporaryDefaults.defaults
        defaults.set("genre_only", forKey: AppStorageKey.defaultUpdateBehavior)
        var savedConfigurations: [AppConfiguration] = []
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { savedConfigurations.append($0) },
            legacyPreferenceStore: defaults
        )

        await dependencies.initialize()

        guard case .loading = dependencies.appState else {
            Issue.record("Unit-test initialization changed app state to \(dependencies.appState)")
            return
        }
        #expect(dependencies.scriptInstaller == nil)
        #expect(dependencies.applescriptBridge == nil)
        #expect(dependencies.subscriptionService == nil)
        #expect(savedConfigurations.isEmpty)
        #expect(defaults.string(forKey: AppStorageKey.defaultUpdateBehavior) == "genre_only")
    }
}
