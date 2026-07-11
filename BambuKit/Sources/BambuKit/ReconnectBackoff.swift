/// Exponential backoff for reconnect attempts: 1s doubling to a 30s cap.
public struct ReconnectBackoff {
    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> Duration {
        defer { attempt = min(attempt + 1, 5) }
        return .seconds(min(30, 1 << attempt))
    }

    public mutating func reset() { attempt = 0 }
}
