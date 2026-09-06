import Foundation
import os

// MARK: - Retry Utility

/// Logger for retry operations.
///
/// Uses a distinct subsystem to separate retry diagnostics from general API logs.
private let log = Logger(subsystem: "com.genreupdater.retry", category: "retry")

/// Retries an async operation with exponential backoff and jitter.
///
/// Designed for transient API failures (503, 429, network errors).
/// Non-retryable errors (400, 401, 404) are thrown immediately.
///
/// - Parameters:
///   - maxAttempts: Maximum number of attempts (default: 3).
///   - initialDelay: Delay before first retry (default: 1s).
///   - maxDelay: Upper bound on delay (default: 30s).
///   - shouldRetry: Closure to classify errors as retryable (default: built-in classifier).
///   - operation: The async throwing operation to retry.
/// - Returns: The operation's result.
/// - Throws: The last error if all attempts fail, or a non-retryable error immediately.
public func withRetry<T: Sendable>(
    maxAttempts: Int = 3,
    initialDelay: Duration = .seconds(1),
    maxDelay: Duration = .seconds(30),
    shouldRetry: @Sendable (any Error) -> Bool = isTransientError,
    operation: @Sendable () async throws -> T
) async throws -> T {
    try await withRetry(
        maxAttempts: maxAttempts,
        initialDelay: initialDelay,
        maxDelay: maxDelay,
        shouldRetry: shouldRetry,
        jitter: applyJitter,
        sleep: { try await Task.sleep(for: $0) },
        operation: operation
    )
}

func withRetry<T: Sendable>(
    maxAttempts: Int = 3,
    initialDelay: Duration = .seconds(1),
    maxDelay: Duration = .seconds(30),
    shouldRetry: @Sendable (any Error) -> Bool = isTransientError,
    jitter: @Sendable (Duration) -> Duration,
    sleep: @Sendable (Duration) async throws -> Void,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var currentDelay = initialDelay

    for attempt in 1 ... maxAttempts {
        do {
            return try await operation()
        } catch {
            let isLastAttempt = attempt == maxAttempts

            guard !isLastAttempt, shouldRetry(error) else {
                if isLastAttempt {
                    log.warning(
                        "All \(maxAttempts, privacy: .public) attempts exhausted. Last error: \(error.localizedDescription, privacy: .public)"
                    )
                }
                throw error
            }

            try Task.checkCancellation()

            let jitteredDelay = jitter(currentDelay)
            log.debug(
                "Attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed: \(error.localizedDescription, privacy: .public). Retrying in \(jitteredDelay, privacy: .public)."
            )

            try await sleep(jitteredDelay)
            currentDelay = min(currentDelay * 2, maxDelay)
        }
    }

    // Unreachable: the loop always returns or throws.
    fatalError("withRetry loop exited without returning or throwing")
}

// MARK: - Default Error Classifier

/// Default transient error classifier.
///
/// Retryable: `MusicBrainzError.serviceUnavailable`, `DiscogsError.rateLimited`,
/// and transient `URLError` codes. Provider hard deadlines use a distinct,
/// non-retryable error because their underlying transport may still be active.
/// Non-retryable: everything else.
public func isTransientError(_ error: any Error) -> Bool {
    switch error {
    case MusicBrainzError.serviceUnavailable:
        return true

    case DiscogsError.rateLimited:
        return true

    case let urlError as URLError:
        let transientCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
        ]
        return transientCodes.contains(urlError.code)

    default:
        return false
    }
}

// MARK: - Jitter

/// Applies +/-25% random jitter to a delay to prevent thundering herd.
private func applyJitter(to delay: Duration) -> Duration {
    let (seconds, attoseconds) = delay.components
    let totalNanoseconds = Double(seconds) * 1_000_000_000 + Double(attoseconds) / 1_000_000_000
    let jitterFactor = Double.random(in: 0.75 ... 1.25)
    let jitteredNanoseconds = Int64(totalNanoseconds * jitterFactor)
    return .nanoseconds(jitteredNanoseconds)
}
