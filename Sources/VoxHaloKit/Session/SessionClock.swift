public protocol SessionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousSessionClock: SessionClock, Sendable {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
