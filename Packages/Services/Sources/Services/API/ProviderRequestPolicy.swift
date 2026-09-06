import Core
import Foundation

struct ProviderRequestOperation: RawRepresentable, Equatable, Sendable {
    let rawValue: String

    static let appleMusicCatalogSearch = Self(rawValue: "applemusic.catalog_search")

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ analyticsOperation: AnalyticsOperation) {
        rawValue = analyticsOperation.rawValue
    }
}

struct ProviderRequestTimeout: LocalizedError, Equatable, Sendable {
    let operation: ProviderRequestOperation
    let timeoutSeconds: TimeInterval

    var errorDescription: String? {
        "\(operation.rawValue) timed out after \(timeoutSeconds) seconds"
    }
}

struct ProviderRequestPolicy: Sendable {
    let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = YearRetrievalConfig.defaultRequestTimeoutSeconds) {
        self.timeoutSeconds = YearRetrievalConfig.resolvedRequestTimeout(timeoutSeconds)
    }

    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        return request
    }

    func performClientRequest<Value: Sendable>(
        operation: ProviderRequestOperation,
        _ request: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let deadline = RequestDeadline<Value>()
        let finishTrackedRequest = try ProviderPermitScope.current?.beginRequest()
        return try await withTaskCancellationHandler {
            try await deadline.wait(
                operation: operation,
                timeoutSeconds: timeoutSeconds,
                finishTrackedRequest: finishTrackedRequest,
                request: request
            )
        } onCancel: {
            deadline.resolve(.failure(CancellationError()))
        }
    }
}

// Safety: the lock serializes the one-shot continuation and both unstructured tasks.
private final class RequestDeadline<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedContinuation: CheckedContinuation<Value, any Error>?
    private var storedResult: Result<Value, any Error>?
    private var activeOperation: Task<Void, Never>?
    private var activeTimeout: Task<Void, Never>?
    private var isResolved = false

    func wait(
        operation: ProviderRequestOperation,
        timeoutSeconds: TimeInterval,
        finishTrackedRequest: (@Sendable () -> Void)?,
        request: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { waitingContinuation in
            install(waitingContinuation)
            installOperation(Task {
                let outcome: Result<Value, any Error>
                do {
                    try Task.checkCancellation()
                    let value = try await request()
                    outcome = .success(value)
                } catch {
                    outcome = .failure(error)
                }
                finishTrackedRequest?()
                resolve(outcome)
            })
            installTimeout(Task {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return
                }
                resolve(.failure(ProviderRequestTimeout(
                    operation: operation,
                    timeoutSeconds: timeoutSeconds
                )))
            })
        }
    }

    func install(_ waitingContinuation: CheckedContinuation<Value, any Error>) {
        let resolvedResult = lock.withLock {
            guard !isResolved else { return storedResult }
            storedContinuation = waitingContinuation
            return nil
        }
        if let resolvedResult {
            waitingContinuation.resume(with: resolvedResult)
        }
    }

    func installOperation(_ operationTask: Task<Void, Never>) {
        installTask(operationTask, at: \Self.activeOperation)
    }

    func installTimeout(_ timeoutTask: Task<Void, Never>) {
        installTask(timeoutTask, at: \Self.activeTimeout)
    }

    func resolve(_ outcome: Result<Value, any Error>) {
        let completion: (
            CheckedContinuation<Value, any Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        )? = lock.withLock {
            guard !isResolved else { return nil }
            isResolved = true
            storedResult = outcome
            let storedTasks = (storedContinuation, activeOperation, activeTimeout)
            storedContinuation = nil
            activeOperation = nil
            activeTimeout = nil
            return storedTasks
        }
        guard let (waitingContinuation, operationTask, timeoutTask) = completion else { return }

        operationTask?.cancel()
        timeoutTask?.cancel()
        waitingContinuation?.resume(with: outcome)
    }

    private func installTask(
        _ task: Task<Void, Never>,
        at keyPath: ReferenceWritableKeyPath<RequestDeadline, Task<Void, Never>?>
    ) {
        let shouldCancel = lock.withLock {
            guard !isResolved else { return true }
            self[keyPath: keyPath] = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }
}
