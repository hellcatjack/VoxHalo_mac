import Foundation
@testable import VoxHaloKit

@MainActor
final class ManualMainActorScheduler: MainActorScheduling {
    private struct Entry {
        let deadline: Duration
        let order: UInt64
        let cancellation: ManualScheduleCancellation
        let action: @MainActor @Sendable () -> Void
    }

    private var currentTime = Duration.zero
    private var nextID: UInt64 = 0
    private var entries: [Entry] = []

    var now: Duration { currentTime }
    var pendingCount: Int {
        entries.filter { !$0.cancellation.isCancelled }.count
    }
    private(set) var scheduleCount = 0

    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any MainActorScheduledTask {
        nextID &+= 1
        let cancellation = ManualScheduleCancellation()
        entries.append(Entry(
            deadline: currentTime + max(.zero, delay),
            order: nextID,
            cancellation: cancellation,
            action: action
        ))
        scheduleCount += 1
        return cancellation
    }

    func advance(by duration: Duration) {
        currentTime += max(.zero, duration)
        runReady()
    }

    func runReady() {
        while let index = nextReadyEntryIndex() {
            let entry = entries.remove(at: index)
            if !entry.cancellation.isCancelled {
                entry.action()
            }
        }
        entries.removeAll { $0.cancellation.isCancelled }
    }

    private func nextReadyEntryIndex() -> Int? {
        entries.indices
            .filter { entries[$0].deadline <= currentTime }
            .min { lhs, rhs in
                let left = entries[lhs]
                let right = entries[rhs]
                return left.deadline == right.deadline
                    ? left.order < right.order
                    : left.deadline < right.deadline
            }
    }
}

private final class ManualScheduleCancellation:
    MainActorScheduledTask,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    nonisolated func cancel() {
        lock.withLock { cancelled = true }
    }
}
