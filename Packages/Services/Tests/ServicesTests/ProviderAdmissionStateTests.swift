import Foundation
import Testing
@testable import Services

#if DEBUG
@Suite("ProviderAdmission — permit state")
struct ProviderAdmissionStateTests {
    @Test("Queued operations start in arrival order")
    func queuedOperationsAreFIFO() async throws {
        let enqueueProbe = AdmissionEnqueueProbe()
        let order = AdmissionOrderProbe()
        let firstGate = AdmissionOperationGate()
        let admission = ProviderAdmission(
            limit: 1,
            hooks: (didEnqueue: { enqueueProbe.record() }, afterGrant: nil)
        )

        let first = operationTask(admission, name: "first", order: order, gate: firstGate)
        #expect(await order.waitForCount(1))
        let second = operationTask(admission, name: "second", order: order)
        #expect(await enqueueProbe.waitForCount(1))
        let third = operationTask(admission, name: "third", order: order)
        #expect(await enqueueProbe.waitForCount(2))

        await firstGate.open()
        try await awaitOperations([first, second, third])

        #expect(await order.names == ["first", "second", "third"])
    }

    @Test("Cancellation after grant skips the operation and advances the queue")
    func cancelledGrantAdvancesQueue() async throws {
        let enqueueProbe = AdmissionEnqueueProbe()
        let grantBarrier = AdmissionGrantBarrier(blockingGrant: 2)
        let order = AdmissionOrderProbe()
        let firstGate = AdmissionOperationGate()
        let admission = ProviderAdmission(
            limit: 1,
            hooks: (
                didEnqueue: { enqueueProbe.record() },
                afterGrant: { await grantBarrier.reach() }
            )
        )

        let first = operationTask(admission, name: "first", order: order, gate: firstGate)
        #expect(await order.waitForCount(1))
        let cancelled = operationTask(admission, name: "cancelled", order: order)
        #expect(await enqueueProbe.waitForCount(1))
        let third = operationTask(admission, name: "third", order: order)
        #expect(await enqueueProbe.waitForCount(2))

        await firstGate.open()
        #expect(await grantBarrier.waitUntilBlocked())
        cancelled.cancel()
        await grantBarrier.release()

        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(cancelled, timeout: AdmissionTestTiming.coordinationTimeout)
        }
        try await awaitOperations([first, third])
        #expect(await order.names == ["first", "third"])
    }

    @Test("Cancellation while queued removes the operation and preserves permit accounting")
    func cancelsQueuedOperation() async throws {
        let enqueueProbe = AdmissionEnqueueProbe()
        let order = AdmissionOrderProbe()
        let firstGate = AdmissionOperationGate()
        let admission = ProviderAdmission(
            limit: 1,
            hooks: (didEnqueue: { enqueueProbe.record() }, afterGrant: nil)
        )

        let first = operationTask(admission, name: "first", order: order, gate: firstGate)
        #expect(await order.waitForCount(1))
        let cancelled = operationTask(admission, name: "cancelled", order: order)
        #expect(await enqueueProbe.waitForCount(1))
        let third = operationTask(admission, name: "third", order: order)
        #expect(await enqueueProbe.waitForCount(2))

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(cancelled, timeout: AdmissionTestTiming.coordinationTimeout)
        }
        await firstGate.open()
        try await awaitOperations([first, third])

        let fourth = operationTask(admission, name: "fourth", order: order)
        try await awaitOperations([fourth])
        #expect(await order.names == ["first", "third", "fourth"])
    }

    @Test("Timed-out request retains its permit until the underlying operation finishes")
    func timedOutRequestRetainsPermit() async throws {
        let admission = ProviderAdmission(limit: 1)
        let requestPolicy = ProviderRequestPolicy(timeoutSeconds: 0.01)
        let firstStarted = EventCounter()
        let order = AdmissionOrderProbe()
        let firstGate = AdmissionOperationGate()

        let request: @Sendable () async -> Void = {
            firstStarted.record()
            await firstGate.wait()
        }
        let first = Task {
            try await admission.execute {
                try await requestPolicy.performClientRequest(operation: .appleMusicCatalogSearch, request)
            }
        }
        #expect(await firstStarted.wait(for: 1, timeout: .seconds(1)))
        await #expect(throws: ProviderRequestTimeout.self) {
            _ = try await taskValue(first, timeout: .seconds(1))
        }

        let second = Task {
            try await admission.execute {
                await order.record("second")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await order.names.isEmpty)

        await firstGate.open()
        #expect(await order.waitForCount(1))
        _ = try await taskValue(second, timeout: .seconds(1))
    }

    @Test("Cancelled request retains its permit until the underlying operation finishes")
    func cancelledRequestRetainsPermit() async throws {
        let admission = ProviderAdmission(limit: 1)
        let requestPolicy = ProviderRequestPolicy(timeoutSeconds: 30)
        let firstStarted = EventCounter()
        let order = AdmissionOrderProbe()
        let firstGate = AdmissionOperationGate()

        let request: @Sendable () async -> Void = {
            firstStarted.record()
            await firstGate.wait()
        }
        let first = Task {
            try await admission.execute {
                try await requestPolicy.performClientRequest(operation: .appleMusicCatalogSearch, request)
            }
        }
        #expect(await firstStarted.wait(for: 1, timeout: .seconds(1)))
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(first, timeout: .seconds(1))
        }

        let second = Task {
            try await admission.execute {
                await order.record("second")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await order.names.isEmpty)

        await firstGate.open()
        #expect(await order.waitForCount(1))
        _ = try await taskValue(second, timeout: .seconds(1))
    }

    @Test("Escaped tasks cannot start requests after their call releases admission")
    func rejectsEscapedRequest() async throws {
        let admission = ProviderAdmission(limit: 1)
        let requestPolicy = ProviderRequestPolicy(timeoutSeconds: 1)
        let requestGate = AdmissionOperationGate()
        let requestStarted = EventCounter()

        let request: @Sendable () async -> Int = {
            requestStarted.record()
            return 1
        }
        let escapedRequest = try await admission.execute {
            Task {
                await requestGate.wait()
                return try await requestPolicy.performClientRequest(operation: .appleMusicCatalogSearch, request)
            }
        }

        await requestGate.open()
        await #expect(throws: ProviderPermitLeaseError.self) {
            _ = try await taskValue(escapedRequest, timeout: .seconds(1))
        }
        #expect(await !requestStarted.wait(for: 1, timeout: .milliseconds(50)))
    }

    private func operationTask(
        _ admission: ProviderAdmission,
        name: String,
        order: AdmissionOrderProbe,
        gate: AdmissionOperationGate? = nil
    ) -> Task<Void, any Error> {
        Task {
            try await admission.execute {
                await order.record(name)
                await gate?.wait()
            }
        }
    }

    private func awaitOperations(_ tasks: [Task<Void, any Error>]) async throws {
        for task in tasks {
            _ = try await taskValue(task, timeout: AdmissionTestTiming.coordinationTimeout)
        }
    }
}

private final class AdmissionEnqueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock {
            count += 1
        }
    }

    func waitForCount(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: AdmissionTestTiming.coordinationTimeout)
        while currentCount < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return currentCount >= expectedCount
    }

    private var currentCount: Int {
        lock.withLock { count }
    }
}

private actor AdmissionGrantBarrier {
    private let blockingGrant: Int
    private var grantCount = 0
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockingGrant: Int) {
        self.blockingGrant = blockingGrant
    }

    func reach() async {
        grantCount += 1
        guard grantCount == blockingGrant else { return }
        isBlocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: AdmissionTestTiming.coordinationTimeout)
        while !isBlocked, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return isBlocked
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AdmissionOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AdmissionOrderProbe {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }

    func waitForCount(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: AdmissionTestTiming.coordinationTimeout)
        while names.count < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return names.count >= expectedCount
    }
}

private enum AdmissionTestTiming {
    static let coordinationTimeout: Duration = .seconds(30)
}
#endif
