import Foundation
@testable import VoxHaloKit

actor ManualSessionClock: SessionClock {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var elapsed: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledIDs: Set<UUID> = []

    var pendingSleepCount: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || cancelledIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(
                        deadline: elapsed + duration,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance(by duration: Duration) {
        elapsed += duration
        let ready = sleepers.filter { $0.value.deadline <= elapsed }
        for (id, sleeper) in ready {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        if let sleeper = sleepers.removeValue(forKey: id) {
            sleeper.continuation.resume(throwing: CancellationError())
        } else {
            cancelledIDs.insert(id)
        }
    }
}
