import AVFAudio
import CoreAudio
import Foundation
@testable import VoxHaloKit

enum FakeAUHALSetupStep: String, CaseIterable, Sendable {
    case createHALOutput
    case enableInput = "enableInput:bus1"
    case disableOutput = "disableOutput:bus0"
    case setDevice
    case readFormat = "readFormat:output:bus1"
    case readMaxFrames
    case allocateRing
    case installInputCallback
    case initialize
    case start

    func call(deviceID: AudioDeviceID) -> String {
        self == .setDevice ? "setDevice:\(deviceID)" : rawValue
    }

    func rollback(deviceID: AudioDeviceID) -> String {
        switch self {
        case .createHALOutput: "disposeHALOutput"
        case .enableInput: "disableInput:bus1"
        case .disableOutput: "enableOutput:bus0"
        case .setDevice: "clearDevice:\(deviceID)"
        case .readFormat: "releaseFormat"
        case .readMaxFrames: "releaseMaxFrames"
        case .allocateRing: "releaseRing"
        case .installInputCallback: "removeInputCallback"
        case .initialize: "uninitialize"
        case .start: "stop"
        }
    }
}

final class FakeAUHAL: AUHALInputUnitProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let failingStep: FakeAUHALSetupStep?
    private var storedCalls: [String] = []
    private var completedSteps: [FakeAUHALSetupStep] = []
    private var events: [AUHALInputEvent] = []
    private var preparedDeviceID: AudioDeviceID?
    private var isStarted = false
    private var isDisposed = false

    init(
        format: AVAudioFormat = FakeAUHAL.defaultFormat(),
        failingAt failingStep: FakeAUHALSetupStep? = nil
    ) {
        self.format = format
        self.failingStep = failingStep
    }

    var calls: [String] {
        lock.withLock { storedCalls }
    }

    func prepare(deviceID: AudioDeviceID) throws {
        lock.lock()
        defer { lock.unlock() }
        preparedDeviceID = deviceID
        for step in FakeAUHALSetupStep.allCases where step != .start {
            storedCalls.append(step.call(deviceID: deviceID))
            if failingStep == step {
                throw AudioCaptureFailure.coreAudio(
                    operation: step.rawValue,
                    status: -1
                )
            }
            completedSteps.append(step)
        }
    }

    func sourceFormat() throws -> AVAudioFormat {
        format
    }

    func start() throws {
        try lock.withLock {
            let step = FakeAUHALSetupStep.start
            let deviceID = preparedDeviceID ?? 0
            storedCalls.append(step.call(deviceID: deviceID))
            if failingStep == step {
                throw AudioCaptureFailure.coreAudio(
                    operation: step.rawValue,
                    status: -1
                )
            }
            completedSteps.append(step)
            isStarted = true
        }
    }

    func stop() {
        lock.withLock {
            guard isStarted else { return }
            isStarted = false
            storedCalls.append(FakeAUHALSetupStep.start.rollback(
                deviceID: preparedDeviceID ?? 0
            ))
            completedSteps.removeAll { $0 == .start }
        }
    }

    func dispose() {
        lock.withLock {
            guard !isDisposed else { return }
            isDisposed = true
            let deviceID = preparedDeviceID ?? 0
            for step in completedSteps.reversed() {
                storedCalls.append(step.rollback(deviceID: deviceID))
            }
            completedSteps.removeAll()
            events.removeAll()
        }
    }

    func nextEvent() async throws -> AUHALInputEvent? {
        while !Task.isCancelled {
            if let event = lock.withLock({
                events.isEmpty ? nil : events.removeFirst()
            }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    func emit(
        _ buffer: AVAudioPCMBuffer,
        timestamp: AudioCallbackTimestamp
    ) {
        lock.withLock {
            events.append(.audio(AUHALCapturedAudio(
                buffer: buffer,
                callbackTimestamp: timestamp
            )))
        }
    }

    func emitOverflow() {
        lock.withLock { events.append(.overflow) }
    }

    func emitProgress(_ progress: AudioCapturePipelineProgress) {
        lock.withLock { events.append(.progress(progress)) }
    }

    static func defaultFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }
}

final class AUHALFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var units: [FakeAUHAL]
    private(set) var creationCount = 0

    init(_ units: [FakeAUHAL]) {
        self.units = units
    }

    func make() -> any AUHALInputUnitProtocol {
        lock.withLock {
            creationCount += 1
            return units.removeFirst()
        }
    }

    var count: Int {
        lock.withLock { creationCount }
    }
}
