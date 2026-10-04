import Foundation

/// A drain watchdog observing existing native playback and producer metrics.
/// It never schedules, acknowledges, trims or otherwise changes audio.
struct NativeSpeechDrainProgress {
    enum Expiry: Equatable { case stalled, limit }
    static let noProgressSeconds: Double = 60
    static let absoluteLimitSeconds: Double = 180
    static let minimumBufferDecrease: Double = 100

    private struct Metrics {
        let received: Int
        let played: Int
        let buffered: Double
        let queued: Int
        let preparing: Int
        let synthesizing: Bool
    }
    private var startedAt: Double?
    private var observedAt: Double?
    private var progressAt: Double?
    private var previous: Metrics?

    init(now: Double) {
        guard now.isFinite, now >= 0 else { return }
        startedAt = now; observedAt = now; progressAt = now
    }

    mutating func observe(now: Double, receivedSequence: Int, playedSequence: Int,
                          bufferedMilliseconds: Double, queued: Int, preparing: Int,
                          synthesisActive: Bool) -> Expiry? {
        guard now.isFinite, now >= 0, observedAt.map({ now >= $0 }) ?? true else { return nil }
        if startedAt == nil { startedAt = now; progressAt = now }
        observedAt = now
        // The absolute cap wins even when this observation reports healthy
        // progress. It cannot be extended by a continually growing producer.
        if now - startedAt! >= Self.absoluteLimitSeconds { return .limit }
        if receivedSequence >= 0, playedSequence >= 0, playedSequence <= receivedSequence,
           bufferedMilliseconds.isFinite, bufferedMilliseconds >= 0, queued >= 0, preparing >= 0 {
            let current = Metrics(received: receivedSequence, played: playedSequence,
                buffered: bufferedMilliseconds, queued: queued, preparing: preparing,
                synthesizing: synthesisActive)
            if let previous {
                let progress = current.received > previous.received || current.played > previous.played
                    || (previous.buffered > 0 && previous.buffered - current.buffered >= Self.minimumBufferDecrease)
                    || current.queued != previous.queued || current.preparing != previous.preparing
                    || current.synthesizing != previous.synthesizing
                if progress { progressAt = now }
                // Sequence regressions must not turn replayed old counters into
                // fresh progress. Buffer/producer comparisons remain adjacent.
                self.previous = Metrics(received: max(current.received, previous.received),
                    played: max(current.played, previous.played), buffered: current.buffered,
                    queued: current.queued, preparing: current.preparing, synthesizing: current.synthesizing)
            } else { previous = current }
        }
        // Invalid metrics cannot renew inactivity. A valid clock still expires
        // their deadline instead of waiting forever for a parseable snapshot.
        return now - progressAt! >= Self.noProgressSeconds ? .stalled : nil
    }
}
