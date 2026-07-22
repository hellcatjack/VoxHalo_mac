import CoreAudio
import Foundation

public actor CoreAudioCaptureService: AudioCapturing {
    private enum Lifecycle {
        case stopped
        case starting(UInt64)
        case running(UInt64)
        case stopping
    }

    private let systemAudioCapture: any AudioCapturing
    private let hardwareInputCapture: any AudioCapturing

    private var lifecycle: Lifecycle = .stopped
    private var generation: UInt64 = 0
    private var systemAudioWasUsed = false
    private var hardwareInputWasUsed = false
    private var deliveryGate: CoreAudioServiceDeliveryGate?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        systemAudioCapture: any AudioCapturing,
        hardwareInputCapture: any AudioCapturing
    ) {
        self.systemAudioCapture = systemAudioCapture
        self.hardwareInputCapture = hardwareInputCapture
    }

    public func start(
        source: AudioSource,
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void
    ) async throws {
        guard case .stopped = lifecycle else {
            throw AudioCaptureFailure.coreAudio(
                operation: "start audio capture",
                status: kAudioHardwareIllegalOperationError
            )
        }
        generation &+= 1
        let token = generation
        lifecycle = .starting(token)

        await stopPreviouslyUsedCaptures()
        try ensureStarting(token)

        let selected: any AudioCapturing = switch source.kind {
        case .systemAudio:
            systemAudioCapture
        case .hardwareInput:
            hardwareInputCapture
        }
        if source.kind == .systemAudio {
            systemAudioWasUsed = true
        } else {
            hardwareInputWasUsed = true
        }
        let gate = CoreAudioServiceDeliveryGate(
            onFrame: onFrame,
            onFailure: onFailure
        )
        deliveryGate = gate

        do {
            try await selected.start(
                source: source,
                onFrame: { frame in gate.deliver(frame) },
                onFailure: { failure in gate.report(failure) }
            )
            try ensureStarting(token)
            lifecycle = .running(token)
        } catch {
            gate.deactivate()
            await selected.stop()
            if case .starting(token) = lifecycle {
                deliveryGate = nil
                lifecycle = .stopped
            }
            throw error
        }
    }

    public func stop() async {
        switch lifecycle {
        case .stopping:
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
            return
        case .starting, .running:
            lifecycle = .stopping
        case .stopped:
            guard systemAudioWasUsed || hardwareInputWasUsed else { return }
            lifecycle = .stopping
        }

        deliveryGate?.deactivate()
        await stopPreviouslyUsedCaptures()
        deliveryGate = nil
        lifecycle = .stopped

        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ensureStarting(_ token: UInt64) throws {
        guard case .starting(token) = lifecycle else {
            throw CancellationError()
        }
    }

    private func stopPreviouslyUsedCaptures() async {
        if systemAudioWasUsed {
            await systemAudioCapture.stop()
        }
        if hardwareInputWasUsed {
            await hardwareInputCapture.stop()
        }
    }
}

private final class CoreAudioServiceDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let onFrame: @Sendable (CapturedAudioFrame) -> Void
    private let onFailure: @Sendable (AudioCaptureFailure) -> Void
    private var isActive = true

    init(
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void
    ) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func deliver(_ frame: CapturedAudioFrame) {
        let callback = lock.withLock { isActive ? onFrame : nil }
        callback?(frame)
    }

    func report(_ failure: AudioCaptureFailure) {
        let callback = lock.withLock { isActive ? onFailure : nil }
        callback?(failure)
    }

    func deactivate() {
        lock.withLock { isActive = false }
    }
}
