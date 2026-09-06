import Core
import Foundation
import Services

private let apiClientLog = AppLogger.make(category: "dependencies")

enum DiscogsCredentialIssue: Equatable {
    case missingToken
    case keychain(KeychainError)
    case other(String)

    init(error: any Error) {
        if let keychainError = error as? KeychainError {
            self = .keychain(keychainError)
        } else {
            self = .other(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .missingToken:
            "Discogs Personal Access Token is not configured. Discogs lookups are disabled until a token is saved."
        case .keychain(.authenticationFailed):
            "Keychain authentication was cancelled or failed. Discogs is running without the saved token."
        case .keychain(.unprotectedItemRequiresResave):
            "The saved Discogs token must be saved again to require local authentication."
        case .keychain(.invalidTokenData):
            "The saved Discogs token data is invalid. Delete it and save the token again."
        case let .keychain(error):
            "Failed to load the saved Discogs token: \(error.localizedDescription)"
        case let .other(description):
            "Failed to load the saved Discogs token: \(description)"
        }
    }
}

struct ProviderTransportContext {
    let rawRequestCache: RawAPIRequestCache?
    let analytics: (any AnalyticsService)?
    let requestTimeoutSeconds: TimeInterval
}

struct APIClientFactoryOverrides {
    typealias DiscogsIssueHandler = @MainActor (DiscogsCredentialIssue?) -> Void
    typealias KeychainDiscogsClientFactory = (
        _ contactEmail: String,
        _ rateLimiter: TokenBucketRateLimiter?,
        _ baseURL: URL
    ) throws -> DiscogsClient
    typealias ConfiguredDiscogsClientFactory = (
        _ token: String,
        _ contactEmail: String,
        _ rateLimiter: TokenBucketRateLimiter?,
        _ baseURL: URL
    ) -> DiscogsClient
    typealias MusicBrainzFactory = (
        _ appName: String,
        _ contactEmail: String,
        _ rateLimiter: TokenBucketRateLimiter?,
        _ cleaningConfiguration: CleaningConfig,
        _ transport: ProviderTransportContext
    ) -> any ExternalAPIService
    typealias CatalogFactory = @MainActor (
        _ configuration: AppConfiguration,
        _ rateLimiter: TokenBucketRateLimiter,
        _ transport: ProviderTransportContext
    ) -> any ExternalAPIService

    var keychainDiscogsClientFactory: KeychainDiscogsClientFactory
    var configuredDiscogsClientFactory: ConfiguredDiscogsClientFactory
    var musicBrainzFactory: MusicBrainzFactory
    var catalogFactory: CatalogFactory
    var keychainErrorHandler: (any Error) -> Void
    var discogsCredentialIssueHandler: DiscogsIssueHandler
    var musicBrainz: (any ExternalAPIService)?
    var appleMusic: (any ExternalAPIService)?

    init(
        keychainDiscogsClientFactory: @escaping KeychainDiscogsClientFactory = Self.makeKeychainDiscogsClient,
        configuredDiscogsClientFactory: @escaping ConfiguredDiscogsClientFactory = Self.makeConfiguredDiscogsClient,
        musicBrainzFactory: @escaping MusicBrainzFactory = Self.makeMusicBrainz,
        catalogFactory: @escaping CatalogFactory = AppDependencies.makeCatalogClient,
        keychainErrorHandler: @escaping (any Error) -> Void = { error in
            apiClientLog.error(
                "Failed to load Discogs token from Keychain: \(error.localizedDescription, privacy: .public)"
            )
        },
        discogsCredentialIssueHandler: @escaping DiscogsIssueHandler = { _ in
            // Default factory use has no UI state to update; callers that own state inject a handler.
        },
        musicBrainz: (any ExternalAPIService)? = nil,
        appleMusic: (any ExternalAPIService)? = nil
    ) {
        self.keychainDiscogsClientFactory = keychainDiscogsClientFactory
        self.configuredDiscogsClientFactory = configuredDiscogsClientFactory
        self.musicBrainzFactory = musicBrainzFactory
        self.catalogFactory = catalogFactory
        self.keychainErrorHandler = keychainErrorHandler
        self.discogsCredentialIssueHandler = discogsCredentialIssueHandler
        self.musicBrainz = musicBrainz
        self.appleMusic = appleMusic
    }

    static func makeKeychainDiscogsClient(
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        baseURL: URL
    ) throws -> DiscogsClient {
        try DiscogsClient.fromKeychain(
            contactEmail: contactEmail,
            rateLimiter: rateLimiter,
            baseURL: baseURL
        )
    }

    static func makeConfiguredDiscogsClient(
        token: String,
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        baseURL: URL
    ) -> DiscogsClient {
        DiscogsClient(
            token: token,
            contactEmail: contactEmail,
            rateLimiter: rateLimiter,
            baseURL: baseURL
        )
    }

    static func makeMusicBrainz(
        appName: String,
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        cleaningConfiguration: CleaningConfig,
        transport: ProviderTransportContext
    ) -> any ExternalAPIService {
        MusicBrainzClient(
            appName: appName,
            contactEmail: contactEmail,
            rateLimiter: rateLimiter,
            cleaningConfiguration: cleaningConfiguration,
            rawRequestCache: transport.rawRequestCache,
            analytics: transport.analytics
        )
        .withRequestTimeout(seconds: transport.requestTimeoutSeconds)
    }
}

private struct DiscogsClientContext {
    let client: DiscogsClient
    let disabledSources: Set<APISource>
}

private struct APIServiceContext {
    let services: APIOrchestratorServices
    let disabledSources: Set<APISource>
}

enum DiscogsAccess {
    case enabled(DiscogsClient)
    case disabled

    var isEnabled: Bool {
        if case .enabled = self {
            true
        } else {
            false
        }
    }
}

actor DiscogsAccessStore {
    private var accessByConfigurationID: [UUID: DiscogsAccess] = [:]

    func save(_ access: DiscogsAccess, configurationID: UUID) {
        accessByConfigurationID[configurationID] = access
    }

    func consume(configurationID: UUID) -> DiscogsAccess? {
        accessByConfigurationID.removeValue(forKey: configurationID)
    }

    func discard(configurationID: UUID) {
        accessByConfigurationID.removeValue(forKey: configurationID)
    }
}

extension AppDependencies {
    static func makeRawCache(
        configuration: AppConfiguration,
        cache: (any CacheService)?
    ) -> RawAPIRequestCache? {
        cache.map {
            RawAPIRequestCache(
                cache: $0,
                ttl: min(
                    GRDBCacheService.resolvedGenericTTL(configuration: configuration),
                    max(0, configuration.caching.negativeResultTTL)
                )
            )
        }
    }

    static func makeAPIOrchestrator(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        reachability: NetworkReachabilityMonitor?,
        analytics: (any AnalyticsService)? = nil,
        factoryOverrides: APIClientFactoryOverrides = APIClientFactoryOverrides()
    ) -> APIOrchestrator {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let discogsContext = makeDiscogsClientContext(
            apiAuth: apiAuth,
            contactEmail: contactEmail,
            rateLimiter: discogsLimiter(configuration: configuration),
            factoryOverrides: factoryOverrides
        )
        let serviceContext = makeAPIServiceContext(
            configuration: configuration,
            discogsContext: discogsContext,
            factoryOverrides: factoryOverrides,
            rawRequestCache: makeRawCache(configuration: configuration, cache: cache),
            analytics: analytics
        )
        return makeAPIOrchestrator(
            configuration: configuration,
            cache: cache,
            reachability: reachability,
            analytics: analytics,
            serviceContext: serviceContext
        )
    }

    static func makeCapturedAPI(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        reachability: NetworkReachabilityMonitor?,
        discogsAccess: DiscogsAccess,
        analytics: (any AnalyticsService)? = nil,
        factoryOverrides: APIClientFactoryOverrides = APIClientFactoryOverrides()
    ) -> APIOrchestrator {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let discogsContext = makeDiscogsClientContext(
            access: discogsAccess,
            apiAuth: apiAuth,
            contactEmail: contactEmail
        )
        let serviceContext = makeAPIServiceContext(
            configuration: configuration,
            discogsContext: discogsContext,
            factoryOverrides: factoryOverrides,
            rawRequestCache: makeRawCache(configuration: configuration, cache: cache),
            analytics: analytics
        )
        return makeAPIOrchestrator(
            configuration: configuration,
            cache: cache,
            reachability: reachability,
            analytics: analytics,
            serviceContext: serviceContext
        )
    }

    private static func makeAPIOrchestrator(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        reachability: NetworkReachabilityMonitor?,
        analytics: (any AnalyticsService)?,
        serviceContext: APIServiceContext
    ) -> APIOrchestrator {
        let orchestratorConfiguration = orchestratorConfiguration(
            configuration: configuration,
            cache: cache,
            reachability: reachability,
            analytics: analytics,
            disabledSources: serviceContext.disabledSources
        )

        return APIOrchestrator(
            services: serviceContext.services,
            configuration: orchestratorConfiguration
        )
    }

    private static func makeAPIServiceContext(
        configuration: AppConfiguration,
        discogsContext: DiscogsClientContext,
        factoryOverrides: APIClientFactoryOverrides,
        rawRequestCache: RawAPIRequestCache? = nil,
        analytics: (any AnalyticsService)? = nil
    ) -> APIServiceContext {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let transport = ProviderTransportContext(
            rawRequestCache: rawRequestCache,
            analytics: analytics,
            requestTimeoutSeconds: configuration.yearRetrieval.requestTimeoutSeconds
        )
        let musicBrainz = factoryOverrides.musicBrainz ?? factoryOverrides.musicBrainzFactory(
            apiAuth.musicBrainzAppName,
            contactEmail,
            musicBrainzLimiter(configuration: configuration),
            configuration.cleaning,
            transport
        )
        let appleMusic = factoryOverrides.appleMusic ?? factoryOverrides.catalogFactory(
            configuration,
            itunesLimiter(configuration: configuration),
            transport
        )
        return APIServiceContext(
            services: APIOrchestratorServices(
                musicBrainz: musicBrainz,
                // The credential factories predate the raw cache, so the
                // composition root attaches it to the built client.
                discogs: discogsContext.client
                    .withSearchConfiguration(configuration.yearRetrieval.discogsSearch)
                    .withReissueKeywords(configuration.yearRetrieval.reissueDetection.reissueKeywords)
                    .withRawRequestCache(transport.rawRequestCache)
                    .withAnalytics(transport.analytics)
                    .withRequestTimeout(seconds: transport.requestTimeoutSeconds),
                appleMusic: appleMusic
            ),
            disabledSources: discogsContext.disabledSources
        )
    }

    static func captureDiscogsAccess(
        configuration: AppConfiguration,
        factoryOverrides: APIClientFactoryOverrides = APIClientFactoryOverrides()
    ) -> DiscogsAccess {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let context = makeDiscogsClientContext(
            apiAuth: apiAuth,
            contactEmail: contactEmail,
            rateLimiter: discogsLimiter(configuration: configuration),
            factoryOverrides: factoryOverrides
        )
        return context.disabledSources.contains(.discogs) ? .disabled : .enabled(context.client)
    }

    private static func makeDiscogsClientContext(
        access: DiscogsAccess,
        apiAuth: APIAuthConfig,
        contactEmail: String
    ) -> DiscogsClientContext {
        switch access {
        case let .enabled(client):
            DiscogsClientContext(client: client, disabledSources: [])
        case .disabled:
            DiscogsClientContext(
                client: makeDisabledDiscogsClient(
                    contactEmail,
                    nil,
                    apiAuth.discogsBaseURL
                ),
                disabledSources: [.discogs]
            )
        }
    }

    private static func makeDiscogsClientContext(
        apiAuth: APIAuthConfig,
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        factoryOverrides: APIClientFactoryOverrides
    ) -> DiscogsClientContext {
        let discogsBaseURL = apiAuth.discogsBaseURL
        let configuredDiscogsToken = APIAuthReferenceResolver.resolve(apiAuth.discogsTokenReference)

        if configuredDiscogsToken.isEmpty {
            return makeKeychainDiscogsClientContext(
                contactEmail: contactEmail,
                rateLimiter: rateLimiter,
                baseURL: discogsBaseURL,
                factoryOverrides: factoryOverrides
            )
        }

        factoryOverrides.discogsCredentialIssueHandler(nil)
        return DiscogsClientContext(
            client: factoryOverrides.configuredDiscogsClientFactory(
                configuredDiscogsToken,
                contactEmail,
                rateLimiter,
                discogsBaseURL
            ),
            disabledSources: []
        )
    }

    private static func makeKeychainDiscogsClientContext(
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        baseURL: URL,
        factoryOverrides: APIClientFactoryOverrides
    ) -> DiscogsClientContext {
        do {
            let client = try factoryOverrides.keychainDiscogsClientFactory(contactEmail, rateLimiter, baseURL)
            guard client.isConfigured else {
                factoryOverrides.discogsCredentialIssueHandler(.missingToken)
                return DiscogsClientContext(
                    client: client,
                    disabledSources: [.discogs]
                )
            }

            factoryOverrides.discogsCredentialIssueHandler(nil)
            return DiscogsClientContext(client: client, disabledSources: [])
        } catch {
            factoryOverrides.keychainErrorHandler(error)
            factoryOverrides.discogsCredentialIssueHandler(DiscogsCredentialIssue(error: error))
            return DiscogsClientContext(
                client: makeDisabledDiscogsClient(contactEmail, rateLimiter, baseURL),
                disabledSources: [.discogs]
            )
        }
    }

    static func orchestratorConfiguration(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        reachability: NetworkReachabilityMonitor?,
        analytics: (any AnalyticsService)?,
        disabledSources: Set<APISource>
    ) -> APIOrchestratorConfiguration {
        var orchestratorConfiguration = APIOrchestratorConfiguration(configuration: configuration)
        orchestratorConfiguration.reachability = reachability
        orchestratorConfiguration.cache = cache
        orchestratorConfiguration.analytics = analytics
        orchestratorConfiguration.disabledSources = disabledSources
        return orchestratorConfiguration
    }

    private static func makeDisabledDiscogsClient(
        _ contactEmail: String,
        _ rateLimiter: TokenBucketRateLimiter?,
        _ baseURL: URL
    ) -> DiscogsClient {
        DiscogsClient(contactEmail: contactEmail, rateLimiter: rateLimiter, baseURL: baseURL)
    }

    static func makeCatalogClient(
        configuration: AppConfiguration,
        rateLimiter: TokenBucketRateLimiter,
        transport: ProviderTransportContext
    ) -> CatalogSearchClient {
        let itunesSearch = configuration.yearRetrieval.itunesSearch
        return CatalogSearchClient.paced(
            settings: itunesSearch,
            rateLimiter: rateLimiter,
            rawRequestCache: transport.rawRequestCache,
            analytics: transport.analytics
        )
        .withRequestTimeout(seconds: transport.requestTimeoutSeconds)
    }

    private static func itunesLimiter(configuration: AppConfiguration) -> TokenBucketRateLimiter {
        makeRateLimiter(
            requests: configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond,
            perSeconds: 1
        )
    }

    private static func musicBrainzLimiter(configuration: AppConfiguration) -> TokenBucketRateLimiter {
        let configuredRate = configuration.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond
        return makeRateLimiter(
            requests: APIRateLimits.musicBrainzRate(configuredRate),
            perSeconds: 1
        )
    }

    private static func discogsLimiter(configuration: AppConfiguration) -> TokenBucketRateLimiter {
        makeRateLimiter(
            requests: Double(configuration.yearRetrieval.rateLimits.discogsRequestsPerMinute),
            perSeconds: 60
        )
    }

    private static func makeRateLimiter(
        requests: Double,
        perSeconds windowSizeSeconds: Double
    ) -> TokenBucketRateLimiter {
        guard let refillMilliseconds = APIRateLimits.refillMilliseconds(
            requests: requests,
            perSeconds: windowSizeSeconds
        ) else {
            preconditionFailure("API rate limits must be validated before composing clients")
        }

        return TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .milliseconds(max(1, refillMilliseconds))
        )
    }
}
