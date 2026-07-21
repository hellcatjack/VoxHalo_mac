import Foundation

public final class BoundedAudioFrameQueue: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var events: [AudioFrameQueueEvent] = []
    private var queuedFrameCount = 0
    private var isFinished = true
    private var waiter: CheckedContinuation<AudioFrameQueueEvent?, Never>?

    public init(capacity: Int = 4) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    @discardableResult
    public func reset() -> UInt64 {
        let priorWaiter: CheckedContinuation<AudioFrameQueueEvent?, Never>?
        lock.lock()
        generation &+= 1
        events.removeAll(keepingCapacity: true)
        queuedFrameCount = 0
        isFinished = false
        priorWaiter = waiter
        waiter = nil
        let activeGeneration = generation
        lock.unlock()
        priorWaiter?.resume(returning: nil)
        return activeGeneration
    }

    public func offer(_ frame: CapturedAudioFrame, generation: UInt64) {
        var waiting: CheckedContinuation<AudioFrameQueueEvent?, Never>?
        lock.lock()
        guard generation == self.generation, !isFinished else {
            lock.unlock()
            return
        }
        if let waiter {
            waiting = waiter
            self.waiter = nil
        } else if queuedFrameCount < capacity {
            events.append(.frame(frame))
            queuedFrameCount += 1
        } else {
            events.removeAll(keepingCapacity: true)
            queuedFrameCount = 0
            events.append(.overflow)
        }
        lock.unlock()
        waiting?.resume(returning: .frame(frame))
    }

    public func signalOverflow(generation: UInt64) {
        var waiting: CheckedContinuation<AudioFrameQueueEvent?, Never>?
        lock.lock()
        guard generation == self.generation, !isFinished else {
            lock.unlock()
            return
        }
        events.removeAll(keepingCapacity: true)
        queuedFrameCount = 0
        if let waiter {
            waiting = waiter
            self.waiter = nil
        } else {
            events.append(.overflow)
        }
        lock.unlock()
        waiting?.resume(returning: .overflow)
    }

    public func next() async -> AudioFrameQueueEvent? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !events.isEmpty {
                let event = events.removeFirst()
                if case .frame = event {
                    queuedFrameCount -= 1
                }
                lock.unlock()
                continuation.resume(returning: event)
            } else if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else if waiter != nil {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    public func finish(generation: UInt64) {
        let waiting: CheckedContinuation<AudioFrameQueueEvent?, Never>?
        lock.lock()
        guard generation == self.generation, !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        events.removeAll(keepingCapacity: true)
        queuedFrameCount = 0
        waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }
}
