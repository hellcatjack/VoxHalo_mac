import CoreAudio
import Foundation

public actor HardwareInputCapture: AudioCapturing {
    public typealias HALFactory = @Sendable () -> any AUHALInputUnitProtocol

    private enum Lifecycle {
        case stopped
        case starting(UInt64)
        case running(UInt64)
        case stopping
    }

    private let deviceCatalog: any AudioDeviceCataloging
    private let permissionProvider: any AudioPermissionProviding
    private let halFactory: HALFactory

    private var lifecycle: Lifecycle = .stopped
    private var nextGeneration: UInt64 = 0
    private var activeHAL: (any AUHALInputUnitProtocol)?
    private var deliveryGate: AUHALCaptureDeliveryGate?
    private var workerTask: Task<Void, Never>?
    private var isObservingDevices = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        deviceCatalog: any AudioDeviceCataloging,
        permissionProvider: any AudioPermissionProviding = AudioPermissionProvider(),
        halFactory: @escaping HALFactory = { AUHALInputUnit() }
    ) {
        self.deviceCatalog = deviceCatalog
        self.permissionProvider = permissionProvider
        self.halFactory = halFactory
    }

    public func start(
        source: AudioSource,
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void
    ) async throws {
        guard case .stopped = lifecycle else {
            throw AudioCaptureFailure.coreAudio(
                operation: "start hardware input",
                status: kAudio_ParamError
            )
        }
        guard source.kind == .hardwareInput else {
            throw AudioCaptureFailure.unsupportedFormat
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        lifecycle = .starting(generation)
        var hal: (any AUHALInputUnitProtocol)?

        do {
            try await permissionProvider.authorize(source)
            try ensureStarting(generation)
            try Task.checkCancellation()

            let deviceID = try deviceCatalog.deviceID(forUID: source.id)
            try ensureStarting(generation)

            let newHAL = halFactory()
            hal = newHAL
            activeHAL = newHAL
            try newHAL.prepare(deviceID: deviceID)
            let converter = try PCM16MonoConverter(
                sourceFormat: newHAL.sourceFormat()
            )

            try deviceCatalog.startObserving { [weak self] sources in
                Task {
                    await self?.handleDeviceSnapshot(
                        sources,
                        activeUID: source.id,
                        generation: generation
                    )
                }
            }
            isObservingDevices = true
            try ensureStarting(generation)

            let gate = AUHALCaptureDeliveryGate(
                onFrame: onFrame,
                onFailure: onFailure
            )
            deliveryGate = gate
            try newHAL.start()
            try ensureStarting(generation)

            workerTask = makeAUHALCaptureWorker(
                hal: newHAL,
                converter: converter,
                gate: gate
            )
            lifecycle = .running(generation)
        } catch {
            deliveryGate?.deactivate()
            deliveryGate = nil
            if isObservingDevices {
                deviceCatalog.stopObserving()
                isObservingDevices = false
            }
            hal?.stop()
            hal?.dispose()
            if activeHAL != nil {
                activeHAL = nil
            }
            workerTask?.cancel()
            workerTask = nil
            if case .starting(generation) = lifecycle {
                lifecycle = .stopped
            }
            throw error
        }
    }

    public func stop() async {
        switch lifecycle {
        case .stopped:
            return
        case .stopping:
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
            return
        case .starting, .running:
            break
        }

        lifecycle = .stopping
        deliveryGate?.deactivate()
        let hal = activeHAL
        let worker = workerTask

        hal?.stop()
        worker?.cancel()
        await worker?.value

        if isObservingDevices {
            deviceCatalog.stopObserving()
            isObservingDevices = false
        }
        hal?.dispose()
        activeHAL = nil
        workerTask = nil
        deliveryGate = nil
        lifecycle = .stopped
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ensureStarting(_ generation: UInt64) throws {
        guard case .starting(generation) = lifecycle else {
            throw CancellationError()
        }
    }

    private func handleDeviceSnapshot(
        _ sources: [AudioSource],
        activeUID: String,
        generation: UInt64
    ) async {
        guard case .running(generation) = lifecycle,
              !sources.contains(where: {
                  $0.kind == .hardwareInput && $0.id == activeUID
              }) else {
            return
        }
        deliveryGate?.reportFatal(.deviceDisconnected(uid: activeUID))
        await stop()
    }

}
