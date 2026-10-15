import Foundation
import Testing
@testable import Services

@Suite("SubscriptionService — delivery races")
@MainActor
struct DeliveryRaceTests {
    @Test("Stale status resolution cannot overwrite a replacement delivery")
    func rejectsStaleStatusResolution() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = EntitlementStub(snapshot: StoreEntitlementSnapshot())
        let decision = DeliveryDecisionGate()
        let oldFinish = FinishRecorder()
        let newFinish = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )
        let firstUpdate = Task { @MainActor in
            await service.handleUpdate(
                .transaction(
                    StoreTransactionDelivery(
                        id: transactionID,
                        productID: SubscriptionProductID.proMonthly,
                        state: .statusPending(resolve: { await decision.resolve() }),
                        finish: { await oldFinish.finish() }
                    )
                )
            )
        }
        await decision.waitForRequest()

        await service.handleUpdate(
            .transaction(
                StoreTransactionDelivery(
                    id: transactionID,
                    productID: SubscriptionProductID.proMonthly,
                    finish: { await newFinish.finish() }
                )
            )
        )
        await decision.resume(with: .removal)
        await firstUpdate.value
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

        await service.refreshEntitlements()

        #expect(await oldFinish.finishCount == 0)
        #expect(await newFinish.finishCount == 1)
    }

    @Test("Older status resolution cannot overwrite a newer refresh decision")
    func newestStatusWins() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionID: UInt64 = 42
        let source = EntitlementStub(snapshot: StoreEntitlementSnapshot())
        let decisions = DeliveryDecisionQueue()
        let finish = FinishRecorder()
        let temporaryDefaults = try TemporaryDefaults()
        defer { temporaryDefaults.remove() }
        let service = SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: temporaryDefaults.defaults,
            dateProvider: { now },
            entitlementSource: source
        )
        let firstRefresh = Task { @MainActor in
            await service.handleUpdate(
                .transaction(
                    StoreTransactionDelivery(
                        id: transactionID,
                        productID: SubscriptionProductID.proMonthly,
                        state: .statusPending(resolve: { await decisions.resolve() }),
                        finish: { await finish.finish() }
                    )
                )
            )
        }
        await decisions.waitForRequests(1)
        let newerRefresh = Task { @MainActor in
            _ = await service.refreshEntitlements()
        }
        await decisions.waitForRequests(2)

        await decisions.resume(request: 1, with: .grant)
        await newerRefresh.value
        await decisions.resume(request: 0, with: .removal)
        await firstRefresh.value
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

        await service.refreshEntitlements()

        #expect(await finish.finishCount == 1)
    }
}

private actor DeliveryDecisionGate {
    private var request: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<StoreDeliveryDecision, Never>?

    func resolve() async -> StoreDeliveryDecision {
        request?.resume()
        request = nil
        return await withCheckedContinuation { result = $0 }
    }

    func waitForRequest() async {
        guard result == nil else { return }
        await withCheckedContinuation { request = $0 }
    }

    func resume(with decision: StoreDeliveryDecision) {
        result?.resume(returning: decision)
        result = nil
    }
}

private actor DeliveryDecisionQueue {
    private var requestCount = 0
    private var results: [Int: CheckedContinuation<StoreDeliveryDecision, Never>] = [:]

    func resolve() async -> StoreDeliveryDecision {
        let request = requestCount
        requestCount += 1
        return await withCheckedContinuation { results[request] = $0 }
    }

    func waitForRequests(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            await Task.yield()
        }
    }

    func resume(request: Int, with decision: StoreDeliveryDecision) {
        results.removeValue(forKey: request)?.resume(returning: decision)
    }
}
