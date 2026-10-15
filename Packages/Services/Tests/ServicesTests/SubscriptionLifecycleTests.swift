import Foundation
import StoreKit
import Testing
@testable import Services

// MARK: - Entitlement Lifecycle

@Suite("SubscriptionService — entitlement lifecycle")
@MainActor
struct EntitlementLifecycleTests {
    @Test("Week Pass downgrades at expiry without a transaction update")
    func downgradesWeekPass() async throws {
        let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = purchaseDate.addingTimeInterval(7 * 86400)
        let date = TestDate(purchaseDate.addingTimeInterval(6 * 86400))
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(weekPassPurchases: [purchaseDate])
        )
        let sleeper = TestSleeper()
        var tierChangeCount = 0
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: date.now,
            entitlementSource: source,
            sleep: sleeper.sleep,
            tierChangeHandler: { tierChangeCount += 1 }
        )

        await service.refreshEntitlements()

        #expect(service.currentTier == .weekPass)
        #expect(await sleeper.waitForDelay() == .seconds(86400))
        #expect(tierChangeCount == 1)

        date.set(expiry)
        await sleeper.resume()
        await source.waitForSnapshots(2)

        #expect(service.currentTier == .free)
        #expect(tierChangeCount == 2)
    }

    @Test("Store update refreshes a running service")
    func refreshesOnStoreUpdate() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(
                proStatuses: [
                    .active(expiresAt: now.addingTimeInterval(86400), renewal: .unknown),
                ]
            )
        )
        var tierChangeCount = 0
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source,
            productLoader: { [] },
            tierChangeHandler: { tierChangeCount += 1 }
        )

        await service.start()
        #expect(service.currentTier == .pro)

        await source.setSnapshot(StoreEntitlementSnapshot())
        await source.emitUpdate()
        await source.waitForSnapshots(2)

        #expect(service.currentTier == .free)
        #expect(tierChangeCount == 2)
    }

    @Test("Refresh resolves against time after the snapshot returns")
    func resolvesAtCompletion() async throws {
        let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = purchaseDate.addingTimeInterval(7 * 86400)
        let date = TestDate(expiry.addingTimeInterval(-1))
        let source = SequencedSource()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: date.now,
            entitlementSource: source
        )
        let refresh = Task { @MainActor in
            _ = await service.refreshEntitlements()
        }
        await source.waitForRequests(1)

        date.set(expiry)
        await source.respond(
            to: 0,
            with: .complete(StoreEntitlementSnapshot(weekPassPurchases: [purchaseDate]))
        )
        await refresh.value

        #expect(service.currentTier == .free)
    }

    @Test("Listener registers before product loading completes")
    func listensDuringStartup() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = EntitlementStub(snapshot: StoreEntitlementSnapshot())
        let loader = ProductLoaderGate()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source,
            productLoader: loader.load
        )
        let startup = Task { @MainActor in
            await service.start()
        }
        await loader.waitForRequest()

        #expect(await source.hasUpdateListener())
        await source.setSnapshot(
            StoreEntitlementSnapshot(
                proStatuses: [.active(expiresAt: now.addingTimeInterval(86400), renewal: .renews)]
            )
        )
        await source.emitUpdate()
        await source.waitForSnapshots(1)
        #expect(service.currentTier == .pro)

        await loader.resume()
        await startup.value
    }

    @Test("Transaction finishes only after refreshed access is applied")
    func finishesAfterRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = SequencedSource()
        let recorder = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )
        let update = Task { @MainActor in
            await service.handleUpdate(
                .transaction(
                    StoreTransactionDelivery(
                        id: transactionID,
                        productID: SubscriptionProductID.proMonthly,
                        finish: { await recorder.finish() }
                    )
                )
            )
        }
        await source.waitForRequests(1)

        #expect(await recorder.finishCount == 0)
        await source.respond(
            to: 0,
            with: .complete(
                StoreEntitlementSnapshot(
                    entitlements: [
                        .pro(
                            transactionID: transactionID,
                            status: .active(expiresAt: now.addingTimeInterval(86400), renewal: .renews)
                        ),
                    ]
                )
            )
        )
        await update.value

        #expect(await recorder.finishCount == 1)
        #expect(service.currentTier == .pro)
    }

    @Test("Superseded transaction refresh retries before finishing")
    func finishesAfterSupersededRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = SequencedSource()
        let recorder = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )
        let update = Task { @MainActor in
            await service.handleUpdate(
                .transaction(
                    StoreTransactionDelivery(
                        id: transactionID,
                        productID: SubscriptionProductID.proMonthly,
                        finish: { await recorder.finish() }
                    )
                )
            )
        }
        await source.waitForRequests(1)
        let newerRefresh = Task { @MainActor in
            _ = await service.refreshEntitlements()
        }
        await source.waitForRequests(2)

        let activeStatus = StoreProStatus.active(
            expiresAt: now.addingTimeInterval(86400),
            renewal: .renews
        )
        let active = StoreEntitlementSnapshot(proStatuses: [activeStatus])
        let delivered = StoreEntitlementSnapshot(
            entitlements: [
                .pro(transactionID: transactionID, status: activeStatus),
            ]
        )
        await source.respond(to: 1, with: .complete(active))
        await newerRefresh.value
        await source.respond(to: 0, with: .complete(delivered))
        await source.waitForRequests(3)
        #expect(await recorder.finishCount == 0)

        await source.respond(to: 2, with: .complete(delivered))
        await update.value

        #expect(await recorder.finishCount == 1)
    }

    @Test("Verification failure stays unfinished and recovers on redelivery")
    func recoversVerificationFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = EntitlementStub(read: .verificationFailed(StoreEntitlementSnapshot()))
        let sleeper = TestSleeper()
        let recorder = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source,
            sleep: sleeper.sleep
        )
        let update = StoreUpdate.transaction(
            StoreTransactionDelivery(
                id: transactionID,
                productID: SubscriptionProductID.proMonthly,
                finish: { await recorder.finish() }
            )
        )

        await service.handleUpdate(update)

        #expect(service.hasVerificationError)
        #expect(await recorder.finishCount == 0)
        #expect(await sleeper.waitForDelay() == .seconds(SubscriptionDuration.statusRetrySeconds))

        await source.setSnapshot(
            StoreEntitlementSnapshot(
                entitlements: [
                    .pro(
                        transactionID: transactionID,
                        status: .active(expiresAt: now.addingTimeInterval(86400), renewal: .renews)
                    ),
                ]
            )
        )
        await service.handleUpdate(update)

        #expect(!service.hasVerificationError)
        #expect(service.currentTier == .pro)
        #expect(await recorder.finishCount == 1)
    }

    @Test("Transaction stays pending until its identity appears in a verified snapshot")
    func waitsForTransactionIdentity() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(
                entitlements: [
                    .pro(
                        transactionID: 99,
                        status: .active(expiresAt: now.addingTimeInterval(86400), renewal: .renews)
                    ),
                ]
            )
        )
        let sleeper = TestSleeper()
        let recorder = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source,
            sleep: sleeper.sleep
        )

        await service.handleUpdate(
            .transaction(
                StoreTransactionDelivery(
                    id: transactionID,
                    productID: SubscriptionProductID.proMonthly,
                    isPurchase: true,
                    finish: { await recorder.finish() }
                )
            )
        )

        #expect(await recorder.finishCount == 0)
        #expect(service.activatingProductIDs == [SubscriptionProductID.proMonthly])
        #expect(!service.canPurchase(productID: SubscriptionProductID.proMonthly))
        #expect(!service.canPurchase(productID: SubscriptionProductID.proYearly))
        #expect(await sleeper.waitForDelay() == .seconds(SubscriptionDuration.statusRetrySeconds))

        await source.setSnapshot(
            StoreEntitlementSnapshot(
                entitlements: [
                    .pro(
                        transactionID: transactionID,
                        status: .active(expiresAt: now.addingTimeInterval(86400), renewal: .renews)
                    ),
                ]
            )
        )
        await sleeper.resume()
        await source.waitForSnapshots(2)
        await recorder.waitForFinishes(1)

        #expect(await recorder.finishCount == 1)
        #expect(service.activatingProductIDs.isEmpty)
        #expect(service.canPurchase(productID: SubscriptionProductID.proMonthly))
    }

    @Test("Removal transaction finishes after a verified snapshot proves absence")
    func finishesRemovalAfterAbsence() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = EntitlementStub(snapshot: StoreEntitlementSnapshot())
        let recorder = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )

        await service.handleUpdate(
            .transaction(
                StoreTransactionDelivery(
                    id: 42,
                    productID: SubscriptionProductID.proMonthly,
                    state: .removalPending,
                    finish: { await recorder.finish() }
                )
            )
        )

        #expect(await recorder.finishCount == 1)
        #expect(service.currentTier == .free)
    }

    @Test("Unavailable delivery status is resolved again before finishing")
    func resolvesPendingStatus() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(
                entitlements: [
                    .pro(
                        transactionID: transactionID,
                        status: .active(expiresAt: now.addingTimeInterval(86400), renewal: .renews)
                    ),
                ]
            )
        )
        let recorder = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )

        await service.handleUpdate(
            .transaction(
                StoreTransactionDelivery(
                    id: transactionID,
                    productID: SubscriptionProductID.proMonthly,
                    state: .statusPending(resolve: { .grant }),
                    finish: { await recorder.finish() }
                )
            )
        )

        #expect(await recorder.finishCount == 1)
    }

    @Test("Store update decision follows signed removal facts")
    func classifiesRemovalUpdates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(
            StoreKitSource.deliveryDecision(
                for: StoreDeliveryFacts(
                    productID: SubscriptionProductID.proMonthly,
                    revocationDate: now,
                    isUpgraded: false,
                    expirationDate: now.addingTimeInterval(86400),
                    subscriptionState: .subscribed
                ),
                at: now
            ) == .removal
        )
        #expect(
            StoreKitSource.deliveryDecision(
                for: StoreDeliveryFacts(
                    productID: SubscriptionProductID.proMonthly,
                    revocationDate: nil,
                    isUpgraded: true,
                    expirationDate: now.addingTimeInterval(86400),
                    subscriptionState: .subscribed
                ),
                at: now
            ) == .removal
        )
    }

    @Test("Store update decision follows renewal state after transaction expiry")
    func classifiesRenewalStates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(
            StoreKitSource.deliveryDecision(
                for: StoreDeliveryFacts(
                    productID: SubscriptionProductID.proMonthly,
                    revocationDate: nil,
                    isUpgraded: false,
                    expirationDate: now,
                    subscriptionState: .expired
                ),
                at: now
            ) == .removal
        )
        #expect(
            StoreKitSource.deliveryDecision(
                for: StoreDeliveryFacts(
                    productID: SubscriptionProductID.proMonthly,
                    revocationDate: nil,
                    isUpgraded: false,
                    expirationDate: now.addingTimeInterval(-1),
                    subscriptionState: .inGracePeriod
                ),
                at: now
            ) == .grant
        )
        #expect(
            StoreKitSource.deliveryDecision(
                for: StoreDeliveryFacts(
                    productID: SubscriptionProductID.proMonthly,
                    revocationDate: nil,
                    isUpgraded: false,
                    expirationDate: now.addingTimeInterval(-1),
                    subscriptionState: nil
                ),
                at: now
            ) == .pending
        )
    }

    @Test("Listener status uncertainty keeps a direct Pro purchase blocked")
    func keepsMergedPurchaseBlocked() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = EntitlementStub(snapshot: StoreEntitlementSnapshot())
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )
        let finish = FinishRecorder()

        await service.handleUpdate(
            .transaction(
                StoreTransactionDelivery(
                    id: transactionID,
                    productID: SubscriptionProductID.proMonthly,
                    isPurchase: true,
                    finish: { await finish.finish() }
                )
            )
        )
        await service.handleUpdate(
            .transaction(
                StoreTransactionDelivery(
                    id: transactionID,
                    productID: SubscriptionProductID.proMonthly,
                    state: .statusPending(resolve: { .pending }),
                    finish: { await finish.finish() }
                )
            )
        )

        #expect(service.activatingProductIDs == [SubscriptionProductID.proMonthly])
        #expect(!service.canPurchase(productID: SubscriptionProductID.proMonthly))
        #expect(!service.canPurchase(productID: SubscriptionProductID.proYearly))
        #expect(await finish.finishCount == 0)
    }

    @Test("Refresh cancels the old boundary before rearming")
    func rearmsBoundary() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let laterPurchase = now.addingTimeInterval(86400)
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(weekPassPurchases: [now])
        )
        let sleeper = TestSleeper()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source,
            sleep: sleeper.sleep
        )

        await service.refreshEntitlements()
        #expect(await sleeper.waitForDelay() == .seconds(7 * 86400))

        await source.setSnapshot(
            StoreEntitlementSnapshot(weekPassPurchases: [now, laterPurchase])
        )
        await service.refreshEntitlements()
        await sleeper.waitForCancellation()
        await sleeper.waitForDelay(.seconds(8 * 86400))

        #expect(await sleeper.pendingDelays() == [.seconds(8 * 86400)])
    }

    @Test("Older refresh cannot restore stale access")
    func rejectsStaleRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = SequencedSource()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )
        let firstRefresh = Task { @MainActor in
            _ = await service.refreshEntitlements()
        }
        await source.waitForRequests(1)
        let secondRefresh = Task { @MainActor in
            _ = await service.refreshEntitlements()
        }
        await source.waitForRequests(2)

        await source.respond(to: 1, with: .complete(StoreEntitlementSnapshot()))
        await secondRefresh.value
        await source.respond(
            to: 0,
            with: .complete(StoreEntitlementSnapshot(weekPassPurchases: [now]))
        )
        await firstRefresh.value

        #expect(service.currentTier == .free)
    }
}

private actor SequencedSource: StoreEntitlementSource {
    private var requestCount = 0
    private var continuations: [Int: CheckedContinuation<StoreSnapshotRead, Never>] = [:]

    func snapshot() async -> StoreSnapshotRead {
        let request = requestCount
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    nonisolated func updates() -> AsyncStream<StoreUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func waitForRequests(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            await Task.yield()
        }
    }

    func respond(to request: Int, with read: StoreSnapshotRead) {
        continuations.removeValue(forKey: request)?.resume(returning: read)
    }
}

private actor ProductLoaderGate {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var loadContinuation: CheckedContinuation<[StoreKit.Product], Never>?

    func load() async -> [StoreKit.Product] {
        requestContinuation?.resume()
        requestContinuation = nil
        return await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func waitForRequest() async {
        guard loadContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func resume() {
        loadContinuation?.resume(returning: [])
        loadContinuation = nil
    }
}
