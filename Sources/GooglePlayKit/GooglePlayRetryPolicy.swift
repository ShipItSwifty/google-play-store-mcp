import Foundation
import GoogleAuthKit

/// How ``GooglePlayClient`` retries a request that failed for a reason likely to pass.
///
/// Only idempotent requests are retried — `GET`, `PUT`, and `DELETE` — and only on a transient
/// failure: a dropped connection, `408`, `429`, or a `5xx` other than `501`. A `POST` such as
/// `edits.insert` or `edits.commit` is never repeated, because a second attempt could create a
/// second edit or apply a change twice. Media uploads are not retried either.
///
/// The delay doubles from ``baseDelay`` on each attempt, with up to 25% random jitter, and is
/// capped at ``maxDelay``. A `Retry-After` header given in seconds takes precedence, under the
/// same cap.
public struct GooglePlayRetryPolicy: Sendable, Equatable {
    /// The total number of attempts, including the first. `1` disables retries.
    public var maxAttempts: Int
    /// The delay before the first retry.
    public var baseDelay: Duration
    /// The longest the client will wait between attempts, whatever the server asks for.
    public var maxDelay: Duration

    public init(maxAttempts: Int, baseDelay: Duration, maxDelay: Duration) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Three attempts, waiting about 0.5s and then 1s, never more than 8s.
    public static let `default` = GooglePlayRetryPolicy(
        maxAttempts: 3, baseDelay: .milliseconds(500), maxDelay: .seconds(8))

    /// Every request is sent exactly once.
    public static let none = GooglePlayRetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)

    static let idempotentMethods: Set<String> = ["GET", "PUT", "DELETE"]

    static let transientStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// Whether `error` is worth another attempt.
    ///
    /// A status code of zero is a transport failure (timeout, dropped connection) per
    /// ``GoogleAPIError/apiError(statusCode:body:)``.
    static func isTransient(_ error: GoogleAPIError) -> Bool {
        guard case .apiError(let status, _) = error else { return false }
        return status == 0 || transientStatusCodes.contains(status)
    }

    /// The wait before attempt `attempt + 1`.
    func delay(afterAttempt attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Int(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(.seconds(seconds), maxDelay)
        }
        let exponential = baseDelay * (1 << max(0, min(attempt - 1, 16)))
        let jitter = exponential * Double.random(in: 0...0.25)
        return min(exponential + jitter, maxDelay)
    }
}
