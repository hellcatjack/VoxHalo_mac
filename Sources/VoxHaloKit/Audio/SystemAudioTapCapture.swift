import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

public actor SystemAudioTapCapture: AudioCapturing {
    public typealias HALFactory = @Sendable () -> any AUHALInputUnitProtocol
    public typealias ProgressHandler = @Sendable (
        AudioCapturePipelineProgress
    ) -> Void

    static let permissionDeniedStatuses: [OSStatus] = [
        kAudioHardwareIllegalOperationError,
        kAudioDevicePermissionsError,
        OSStatus(kAudioComponentErr_NotPermitted)
    ]

    private enum Lifecycle {
        case stopped
        case starting
        case running
        case stopping
    }

    private let api: any CoreAudioTapAPI
    private let halFactory: HALFactory
    private let uuidGenerator: @Sendable () -> UUID
    private let onProgress: ProgressHandler

    private var lifecycle: Lifecycle = .stopped
    private var resources: CoreAudioTapResources?
    private var activeHAL: (any AUHALInputUnitProtocol)?
    private var deliveryGate: AUHALCaptureDeliveryGate?
    private var workerTask: Task<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        api: any CoreAudioTapAPI = AppleCoreAudioTapAPI(),
        halFactory: @escaping HALFactory = {
            SystemAudioTapCapture.makeDefaultInputUnit()
        },
        uuidGenerator: @escaping @Sendable () -> UUID = { UUID() },
        onProgress: @escaping ProgressHandler = { _ in }
    ) {
        self.api = api
        self.halFactory = halFactory
        self.uuidGenerator = uuidGenerator
        self.onProgress = onProgress
    }

    public func start(
        source: AudioSource,
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void
    ) async throws {
        guard case .stopped = lifecycle else {
            throw AudioCaptureFailure.coreAudio(
                operation: "start system audio",
                status: kAudioHardwareIllegalOperationError
            )
        }
        guard source.kind == .systemAudio else {
            throw AudioCaptureFailure.unsupportedFormat
        }
        try clearPendingResourcesBeforeStart()
        lifecycle = .starting

        let newResources = CoreAudioTapResources(
            api: api,
            uuidGenerator: uuidGenerator
        )
        resources = newResources
        var hal: (any AUHALInputUnitProtocol)?

        do {
            let prepared = try newResources.prepare()
            var tapFormat = prepared.tapFormat
            guard AVAudioFormat(streamDescription: &tapFormat) != nil else {
                throw AudioCaptureFailure.unsupportedFormat
            }

            let newHAL = halFactory()
            hal = newHAL
            activeHAL = newHAL
            try newHAL.prepare(deviceID: prepared.aggregateDeviceID)
            let converter = try PCM16MonoConverter(
                sourceFormat: newHAL.sourceFormat()
            )
            let gate = AUHALCaptureDeliveryGate(
                onFrame: onFrame,
                onFailure: onFailure,
                onProgress: onProgress
            )
            deliveryGate = gate
            try newHAL.start()
            workerTask = makeAUHALCaptureWorker(
                hal: newHAL,
                converter: converter,
                gate: gate
            )
            lifecycle = .running
        } catch {
            deliveryGate?.deactivate()
            deliveryGate = nil
            workerTask?.cancel()
            workerTask = nil
            hal?.stop()
            hal?.dispose()
            activeHAL = nil
            _ = newResources.cleanup()
            if !newResources.hasLiveResources {
                resources = nil
            }
            lifecycle = .stopped
            throw Self.mapStartupError(error)
        }
    }

    public static func makeDefaultInputUnit() -> any AUHALInputUnitProtocol {
        AudioDeviceInputUnit()
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
            retryResourceCleanup()
            return
        }

        deliveryGate?.deactivate()
        let hal = activeHAL
        let worker = workerTask
        hal?.stop()
        worker?.cancel()
        await worker?.value
        hal?.dispose()

        activeHAL = nil
        workerTask = nil
        deliveryGate = nil
        retryResourceCleanup()
        lifecycle = .stopped
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func clearPendingResourcesBeforeStart() throws {
        guard let resources else { return }
        let failures = resources.cleanup()
        guard !resources.hasLiveResources else {
            throw failures.first ?? .coreAudio(
                operation: "cleanup system audio resources",
                status: kAudioHardwareUnspecifiedError
            )
        }
        self.resources = nil
    }

    private func retryResourceCleanup() {
        guard let resources else { return }
        _ = resources.cleanup()
        if !resources.hasLiveResources {
            self.resources = nil
        }
    }

    private static func mapStartupError(
        _ error: any Error
    ) -> any Error {
        guard case let AudioCaptureFailure.coreAudio(operation, status) = error,
              operation == "createProcessTap",
              permissionDeniedStatuses.contains(status) else {
            return error
        }
        return AudioCaptureFailure.systemAudioPermissionDenied
    }
}
