import Foundation

actor ProviderAdmission {
    #if DEBUG
    typealias TestHooks = (
        didEnqueue: (@Sendable () -> Void)?,
        afterGrant: (@Sendable () async -> Void)?
    )
    #endif

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var activeCalls = 0
    private var waiters: [Waiter] = []
    #if DEBUG
    private let hooks: TestHooks?
    #endif

    #if DEBUG
    init(limit: Int, hooks: TestHooks? = nil) {
        self.limit = max(1, limit)
        self.hooks = hooks
    }
    #else
    init(limit: Int) {
        self.limit = max(1, limit)
    }
    #endif

    func execute<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        let permitLease = ProviderPermitLease {
            Task { await self.release() }
        }
        defer { finish(permitLease) }
        return try await ProviderPermitScope.$current.withValue(permitLease) {
            try await operation()
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCalls < limit {
            activeCalls += 1
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, continuation: continuation))
                    #if DEBUG
                    hooks?.didEnqueue?()
                    #endif
                    if Task.isCancelled {
                        cancel(id)
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        #if DEBUG
        await hooks?.afterGrant?()
        #endif
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    private func release() {
        guard activeCalls > 0 else {
            assertionFailure("Provider admission count underflow")
            return
        }
        activeCalls -= 1
        resumeWaiters()
    }

    private func finish(_ permitLease: ProviderPermitLease) {
        if permitLease.finishCall() {
            release()
        }
    }

    private func resumeWaiters() {
        while activeCalls < limit, !waiters.isEmpty {
            activeCalls += 1
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum ProviderPermitScope {
    @TaskLocal static var current: ProviderPermitLease?
}

enum ProviderPermitLeaseError: Error, Equatable, Sendable {
    case callFinished
}

/// Connects physical provider requests to one admitted logical call through task-local scope.
/// A logical return or deadline keeps the permit occupied until every registered request closure finishes.
///
/// Safety: the lock protects the call/request lifetime counters and one-shot release state.
final class ProviderPermitLease: @unchecked Sendable {
    private enum State {
        case acceptingRequests
        case awaitingRequests
        case released
    }

    private let lock = NSLock()
    private let deferredRelease: @Sendable () -> Void
    private var activeRequests = 0
    private var state = State.acceptingRequests

    init(deferredRelease: @escaping @Sendable () -> Void) {
        self.deferredRelease = deferredRelease
    }

    func beginRequest() throws -> @Sendable () -> Void {
        try lock.withLock {
            guard state == .acceptingRequests else {
                throw ProviderPermitLeaseError.callFinished
            }
            activeRequests += 1
        }
        return { self.finishRequest() }
    }

    func finishCall() -> Bool {
        lock.withLock {
            guard state == .acceptingRequests else {
                assertionFailure("Provider call finished more than once")
                return false
            }
            if activeRequests == 0 {
                state = .released
                return true
            }
            state = .awaitingRequests
            return false
        }
    }

    private func finishRequest() {
        let shouldRelease = lock.withLock {
            guard activeRequests > 0 else {
                assertionFailure("Provider request count underflow")
                return false
            }
            activeRequests -= 1
            guard activeRequests == 0, state == .awaitingRequests else { return false }
            state = .released
            return true
        }
        if shouldRelease {
            deferredRelease()
        }
    }
}
