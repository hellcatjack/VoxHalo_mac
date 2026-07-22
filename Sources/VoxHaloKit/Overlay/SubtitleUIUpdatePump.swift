import Foundation

public protocol MainActorScheduledTask: Sendable {
    func cancel()
}

@MainActor
public protocol MainActorScheduling: AnyObject {
    var now: Duration { get }
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any MainActorScheduledTask
}

@MainActor
public final class ContinuousMainActorScheduler: MainActorScheduling {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public var now: Duration {
        origin.duration(to: clock.now)
    }

    public func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any MainActorScheduledTask {
        let normalizedDelay = max(.zero, delay)
        let task = Task { @MainActor [clock] in
            do {
                if normalizedDelay > .zero {
                    try await clock.sleep(for: normalizedDelay)
                } else {
                    await Task.yield()
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return ContinuousScheduledTask(task: task)
    }
}

private final class ContinuousScheduledTask:
    MainActorScheduledTask,
    @unchecked Sendable
{
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

@MainActor
public final class SubtitleUIUpdatePump {
    public static let defaultMinimumInterval = Duration.milliseconds(80)

    private let minimumInterval: Duration
    private let scheduler: any MainActorScheduling
    private let apply: @MainActor (SubtitleDisplayModel) -> Void

    private var pendingModel: SubtitleDisplayModel?
    private var pendingDeadline: Duration?
    private var scheduledTask: (any MainActorScheduledTask)?
    private var lastAppliedAt: Duration?
    private var isInteractiveChangeActive = false

    public init(
        minimumInterval: Duration = SubtitleUIUpdatePump.defaultMinimumInterval,
        scheduler: any MainActorScheduling = ContinuousMainActorScheduler(),
        apply: @escaping @MainActor (SubtitleDisplayModel) -> Void
    ) {
        self.minimumInterval = max(.zero, minimumInterval)
        self.scheduler = scheduler
        self.apply = apply
    }

    deinit {
        scheduledTask?.cancel()
    }

    public func post(_ model: SubtitleDisplayModel) {
        pendingModel = model
        if pendingDeadline == nil {
            pendingDeadline = nextEligibleDeadline()
        }
        scheduleIfNeeded()
    }

    public func beginInteractiveChange() {
        guard !isInteractiveChangeActive else { return }
        isInteractiveChangeActive = true
        cancelScheduledTask()
    }

    public func endInteractiveChange() {
        guard isInteractiveChangeActive else { return }
        isInteractiveChangeActive = false
        scheduleIfNeeded()
    }

    public func cancel() {
        cancelScheduledTask()
        pendingModel = nil
        pendingDeadline = nil
        isInteractiveChangeActive = false
    }

    private func nextEligibleDeadline() -> Duration {
        if let lastAppliedAt {
            return max(scheduler.now, lastAppliedAt + minimumInterval)
        }
        return scheduler.now + minimumInterval
    }

    private func scheduleIfNeeded() {
        guard pendingModel != nil,
              !isInteractiveChangeActive,
              scheduledTask == nil else {
            return
        }
        let deadline = pendingDeadline ?? nextEligibleDeadline()
        pendingDeadline = deadline
        let delay = max(.zero, deadline - scheduler.now)
        scheduledTask = scheduler.schedule(after: delay) { [weak self] in
            self?.deadlineReached()
        }
    }

    private func deadlineReached() {
        scheduledTask = nil
        guard !isInteractiveChangeActive,
              let deadline = pendingDeadline else {
            return
        }
        if scheduler.now < deadline {
            scheduleIfNeeded()
            return
        }
        guard let model = pendingModel else {
            pendingDeadline = nil
            return
        }

        pendingModel = nil
        pendingDeadline = nil
        lastAppliedAt = scheduler.now
        apply(model)
        scheduleIfNeeded()
    }

    private func cancelScheduledTask() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}
