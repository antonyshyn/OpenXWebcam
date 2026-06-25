import Foundation

public struct RetryPolicy {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public private(set) var attempt = 0

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 0.3, maxDelay: TimeInterval = 2.0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public mutating func nextDelay() -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let delay = min(baseDelay * pow(2, Double(attempt)), maxDelay)
        attempt += 1
        return delay
    }

    public mutating func reset() {
        attempt = 0
    }
}
