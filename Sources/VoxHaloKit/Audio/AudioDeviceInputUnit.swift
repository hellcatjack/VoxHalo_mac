import AVFAudio
import CoreAudio
import Dispatch
import Foundation
import VoxHaloRealtimeAudio

/// Reads a Core Audio input device through the device IOProc path Apple uses
/// for process-tap aggregate devices.
public final class AudioDeviceInputUnit: AUHALInputUnitProtocol, @unchecked Sendable {
    private static let progressIntervalNanoseconds: UInt64 = 1_000_000_000

    private let lock = NSLock()
    private var ring: RealtimeAudioBufferRing?
    private var input: OpaquePointer?
    private var format: AVAudioFormat?
    private var observedDroppedPacketCount: UInt64 = 0
    private var nextProgressDeadline: UInt64 = 0
    private var disposed = false

    public init() {}

    deinit {
        dispose()
    }

    public func prepare(deviceID: AudioDeviceID) throws {
        try lock.withLock {
            guard input == nil, !disposed else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "prepare audio device input",
                    status: kAudio_ParamError
                )
            }
            guard let newRing = RealtimeAudioBufferRing(
                slotCount: 1,
                bytesPerSlot: 1
            ) else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "allocate real-time ring",
                    status: OSStatus(memFullErr)
                )
            }

            var newInput: OpaquePointer?
            let createStatus = VHAudioDeviceInputCreate(
                deviceID,
                newRing.nativePointer,
                &newInput
            )
            guard createStatus == noErr, let newInput else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "create audio device IOProc",
                    status: createStatus
                )
            }

            var description = AudioStreamBasicDescription()
            let formatStatus = VHAudioDeviceInputGetFormat(
                newInput,
                &description
            )
            guard formatStatus == noErr,
                  let newFormat = AVAudioFormat(
                      streamDescription: &description
                  ) else {
                VHAudioDeviceInputDispose(newInput)
                throw AudioCaptureFailure.coreAudio(
                    operation: "read audio device input format",
                    status: formatStatus == noErr
                        ? kAudioFormatUnsupportedDataFormatError
                        : formatStatus
                )
            }

            ring = newRing
            input = newInput
            format = newFormat
            observedDroppedPacketCount = 0
            nextProgressDeadline = Self.nextProgressDeadline(after: Self.now())
        }
    }

    public func sourceFormat() throws -> AVAudioFormat {
        try lock.withLock {
            guard let format else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "read audio device input format",
                    status: kAudio_ParamError
                )
            }
            return format
        }
    }

    public func start() throws {
        try lock.withLock {
            guard let input else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "start audio device IOProc",
                    status: kAudio_ParamError
                )
            }
            let status = VHAudioDeviceInputStart(input)
            guard status == noErr else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "start audio device IOProc",
                    status: status
                )
            }
        }
    }

    public func stop() {
        lock.withLock {
            guard let input else { return }
            _ = VHAudioDeviceInputStop(input)
        }
    }

    public func dispose() {
        let inputToDispose: OpaquePointer? = lock.withLock {
            guard !disposed else { return nil }
            disposed = true
            let value = input
            input = nil
            format = nil
            return value
        }
        if let inputToDispose {
            VHAudioDeviceInputDispose(inputToDispose)
        }
        lock.withLock { ring = nil }
    }

    public func nextEvent() async throws -> AUHALInputEvent? {
        while !Task.isCancelled {
            let state = lock.withLock {
                (
                    ring,
                    format,
                    input,
                    observedDroppedPacketCount,
                    nextProgressDeadline
                )
            }
            guard let ring = state.0,
                  let format = state.1,
                  let input = state.2 else {
                return nil
            }

            let dropped = ring.droppedPacketCount
            if dropped != state.3 {
                while ring.read() != nil {}
                let latestDroppedCount = ring.droppedPacketCount
                lock.withLock {
                    observedDroppedPacketCount = latestDroppedCount
                }
                return .overflow
            }

            let now = Self.now()
            if now >= state.4 {
                var metrics = VHAudioDeviceInputMetrics()
                let status = VHAudioDeviceInputGetMetrics(input, &metrics)
                guard status == noErr else {
                    throw AudioCaptureFailure.coreAudio(
                        operation: "read audio device capture metrics",
                        status: status
                    )
                }
                lock.withLock {
                    nextProgressDeadline = Self.nextProgressDeadline(after: now)
                }
                return .progress(AudioCapturePipelineProgress(
                    callbackCount: metrics.callbackCount,
                    sourcePacketCount: metrics.sourcePacketCount,
                    sourceFrameCount: metrics.sourceFrameCount,
                    sourceByteCount: metrics.sourceByteCount,
                    ringWriteFailureCount: metrics.ringWriteFailureCount,
                    lastNativeStatus: metrics.lastStatus,
                    convertedByteCount: 0,
                    deliveredFrameCount: 0
                ))
            }

            if let packet = ring.read() {
                return .audio(try AUHALInputUnit.makeCapturedAudio(
                    packet: packet,
                    format: format
                ))
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func nextProgressDeadline(after value: UInt64) -> UInt64 {
        let (deadline, overflow) = value.addingReportingOverflow(
            progressIntervalNanoseconds
        )
        return overflow ? UInt64.max : deadline
    }
}
