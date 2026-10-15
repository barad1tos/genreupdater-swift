import Foundation
@testable import Services

actor EntitlementStub: StoreEntitlementSource {
    private var read: StoreSnapshotRead
    private var snapshotCount = 0
    nonisolated private let updateFeed = UpdateFeed()

    init(snapshot: StoreEntitlementSnapshot) {
        read = .complete(snapshot)
    }

    init(read: StoreSnapshotRead) {
        self.read = read
    }

    func snapshot() async -> StoreSnapshotRead {
        snapshotCount += 1
        return read
    }

    nonisolated func updates() -> AsyncStream<StoreUpdate> {
        updateFeed.register()
        return updateFeed.stream
    }

    func setSnapshot(_ snapshot: StoreEntitlementSnapshot) {
        read = .complete(snapshot)
    }

    func emitUpdate() {
        updateFeed.emit(.status)
    }

    nonisolated func hasUpdateListener() async -> Bool {
        updateFeed.isRegistered
    }

    func waitForSnapshots(_ expectedCount: Int) async {
        while snapshotCount < expectedCount {
            await Task.yield()
        }
    }
}

private final class UpdateFeed: @unchecked Sendable {
    let stream: AsyncStream<StoreUpdate>
    private let continuation: AsyncStream<StoreUpdate>.Continuation
    private let lock = NSLock()
    private var registered = false

    init() {
        let pair = AsyncStream<StoreUpdate>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    var isRegistered: Bool {
        lock.withLock { registered }
    }

    func register() {
        lock.withLock { registered = true }
    }

    func emit(_ update: StoreUpdate) {
        continuation.yield(update)
    }
}

actor FinishRecorder {
    private(set) var finishCount = 0

    func finish() {
        finishCount += 1
    }

    func waitForFinishes(_ expectedCount: Int) async {
        while finishCount < expectedCount {
            await Task.yield()
        }
    }
}

actor TestSleeper {
    private struct Wait {
        let delay: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waits: [UUID: Wait] = [:]
    private var cancellationCount = 0

    func sleep(for delay: Duration) async throws {
        let waitID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waits[waitID] = Wait(delay: delay, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waitID) }
        }
    }

    func waitForDelay() async -> Duration? {
        while waits.isEmpty {
            await Task.yield()
        }
        return waits.values.first?.delay
    }

    func resume() {
        guard let waitID = waits.keys.first, let wait = waits.removeValue(forKey: waitID) else { return }
        wait.continuation.resume()
    }

    func waitForCancellation() async {
        while cancellationCount == 0 {
            await Task.yield()
        }
    }

    func pendingDelays() -> [Duration] {
        waits.values.map(\.delay).sorted()
    }

    func waitForDelay(_ expectedDelay: Duration) async {
        while !waits.values.contains(where: { $0.delay == expectedDelay }) {
            await Task.yield()
        }
    }

    private func cancel(_ waitID: UUID) {
        guard let wait = waits.removeValue(forKey: waitID) else { return }
        cancellationCount += 1
        wait.continuation.resume(throwing: CancellationError())
    }
}

final class TestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

final class CounterStub: SubscriptionCounterStore {
    func counter(forKey key: String) -> Int64 {
        _ = key
        return 0
    }

    func setCounter(_ value: Int64, forKey key: String) {
        _ = value
        _ = key
    }
}
