import AVFAudio
import CoreAudio
import Foundation
import VoxHaloRealtimeAudio

public struct AUHALCapturedAudio: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let callbackTimestamp: AudioCallbackTimestamp

    public init(
        buffer: AVAudioPCMBuffer,
        callbackTimestamp: AudioCallbackTimestamp
    ) {
        self.buffer = buffer
        self.callbackTimestamp = callbackTimestamp
    }
}

public enum AUHALInputEvent: @unchecked Sendable {
    case audio(AUHALCapturedAudio)
    case overflow
    case progress(AudioCapturePipelineProgress)
}

public protocol AUHALInputUnitProtocol: Sendable {
    func prepare(deviceID: AudioDeviceID) throws
    func sourceFormat() throws -> AVAudioFormat
    func start() throws
    func stop()
    func dispose()
    func nextEvent() async throws -> AUHALInputEvent?
}

public final class AUHALInputUnit: AUHALInputUnitProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var ring: RealtimeAudioBufferRing?
    private var input: OpaquePointer?
    private var format: AVAudioFormat?
    private var observedDroppedPacketCount: UInt64 = 0
    private var disposed = false

    public init() {}

    deinit {
        dispose()
    }

    public func prepare(deviceID: AudioDeviceID) throws {
        try lock.withLock {
            guard input == nil, !disposed else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "prepare AUHAL",
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
            let createStatus = VHAUHALInputCreate(
                deviceID,
                newRing.nativePointer,
                &newInput
            )
            guard createStatus == noErr, let newInput else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "create AUHAL input",
                    status: createStatus
                )
            }

            var description = AudioStreamBasicDescription()
            let formatStatus = VHAUHALInputGetFormat(newInput, &description)
            guard formatStatus == noErr,
                  let newFormat = AVAudioFormat(
                      streamDescription: &description
                  ) else {
                VHAUHALInputDispose(newInput)
                throw AudioCaptureFailure.coreAudio(
                    operation: "read AUHAL source format",
                    status: formatStatus == noErr
                        ? kAudioFormatUnsupportedDataFormatError
                        : formatStatus
                )
            }

            ring = newRing
            input = newInput
            format = newFormat
            observedDroppedPacketCount = 0
        }
    }

    public func sourceFormat() throws -> AVAudioFormat {
        try lock.withLock {
            guard let format else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "read AUHAL source format",
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
                    operation: "start AUHAL input",
                    status: kAudio_ParamError
                )
            }
            let status = VHAUHALInputStart(input)
            guard status == noErr else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "start AUHAL input",
                    status: status
                )
            }
        }
    }

    public func stop() {
        lock.withLock {
            guard let input else { return }
            _ = VHAUHALInputStop(input)
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
            VHAUHALInputDispose(inputToDispose)
        }
        lock.withLock { ring = nil }
    }

    public func nextEvent() async throws -> AUHALInputEvent? {
        while !Task.isCancelled {
            let state = lock.withLock {
                (ring, format, observedDroppedPacketCount)
            }
            guard let ring = state.0, let format = state.1 else {
                return nil
            }

            let dropped = ring.droppedPacketCount
            if dropped != state.2 {
                while ring.read() != nil {}
                let latestDroppedCount = ring.droppedPacketCount
                lock.withLock {
                    observedDroppedPacketCount = latestDroppedCount
                }
                return .overflow
            }
            if let packet = ring.read() {
                return .audio(try Self.makeCapturedAudio(
                    packet: packet,
                    format: format
                ))
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    static func makeCapturedAudio(
        packet: RealtimeAudioPacket,
        format: AVAudioFormat
    ) throws -> AUHALCapturedAudio {
        guard packet.frameCount > 0,
              format.streamDescription.pointee.mFormatID
                  == kAudioFormatLinearPCM,
              format.streamDescription.pointee.mBytesPerFrame > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(packet.frameCount)
              ) else {
            throw AudioCaptureFailure.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(packet.frameCount)
        let byteCountPerBuffer = Int(packet.frameCount)
            * Int(format.streamDescription.pointee.mBytesPerFrame)
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        let expectedByteCount = byteCountPerBuffer * audioBuffers.count
        guard packet.bytes.count == expectedByteCount else {
            throw AudioCaptureFailure.unsupportedFormat
        }

        try packet.bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else {
                throw AudioCaptureFailure.unsupportedFormat
            }
            for index in audioBuffers.indices {
                guard let destination = audioBuffers[index].mData else {
                    throw AudioCaptureFailure.unsupportedFormat
                }
                memcpy(
                    destination,
                    sourceBase.advanced(by: index * byteCountPerBuffer),
                    byteCountPerBuffer
                )
                audioBuffers[index].mDataByteSize = UInt32(byteCountPerBuffer)
            }
        }
        return AUHALCapturedAudio(
            buffer: buffer,
            callbackTimestamp: packet.callbackTimestamp
        )
    }
}

final class AUHALCaptureDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let onFrame: @Sendable (CapturedAudioFrame) -> Void
    private let onFailure: @Sendable (AudioCaptureFailure) -> Void
    private let onProgress: @Sendable (AudioCapturePipelineProgress) -> Void
    private var isActive = true
    private var fatalFailureWasReported = false

    init(
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void,
        onProgress: @escaping @Sendable (AudioCapturePipelineProgress) -> Void = { _ in }
    ) {
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.onProgress = onProgress
    }

    func deliver(_ frame: CapturedAudioFrame) {
        let callback = lock.withLock { isActive ? onFrame : nil }
        callback?(frame)
    }

    func reportOverflow() {
        let callback = lock.withLock { isActive ? onFailure : nil }
        callback?(.pipelineOverloaded)
    }

    func reportProgress(_ progress: AudioCapturePipelineProgress) {
        let callback = lock.withLock { isActive ? onProgress : nil }
        callback?(progress)
    }

    func reportFatal(_ failure: AudioCaptureFailure) {
        let callback: (@Sendable (AudioCaptureFailure) -> Void)? = lock.withLock {
            guard isActive, !fatalFailureWasReported else { return nil }
            fatalFailureWasReported = true
            isActive = false
            return onFailure
        }
        callback?(failure)
    }

    func deactivate() {
        lock.withLock { isActive = false }
    }
}

func makeAUHALCaptureWorker(
    hal: any AUHALInputUnitProtocol,
    converter: PCM16MonoConverter,
    gate: AUHALCaptureDeliveryGate
) -> Task<Void, Never> {
    Task.detached(priority: .high) {
        let accumulator = PCMFrameAccumulator()
        var activeConverter = converter
        var convertedByteCount: UInt64 = 0
        var deliveredFrameCount: UInt64 = 0
        defer { accumulator.discardRemainder() }
        do {
            while !Task.isCancelled,
                  let event = try await hal.nextEvent() {
                switch event {
                case let .audio(captured):
                    let converted = try activeConverter.convert(captured.buffer)
                    convertedByteCount &+= UInt64(converted.count)
                    let frames = accumulator.append(converted)
                    deliveredFrameCount &+= UInt64(frames.count)
                    for bytes in frames {
                        gate.deliver(CapturedAudioFrame(
                            pcm16LE: bytes,
                            callbackTimestamp: captured.callbackTimestamp
                        ))
                    }
                case .overflow:
                    accumulator.discardRemainder()
                    activeConverter = try PCM16MonoConverter(
                        sourceFormat: activeConverter.sourceFormat
                    )
                    gate.reportOverflow()
                case let .progress(progress):
                    gate.reportProgress(progress.includingWorkerCounts(
                        convertedByteCount: convertedByteCount,
                        deliveredFrameCount: deliveredFrameCount
                    ))
                }
            }
        } catch is CancellationError {
            return
        } catch let failure as AudioCaptureFailure {
            gate.reportFatal(failure)
        } catch {
            gate.reportFatal(.unsupportedFormat)
        }
    }
}
