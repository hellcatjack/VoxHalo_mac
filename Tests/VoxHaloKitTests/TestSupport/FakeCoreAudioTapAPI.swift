import CoreAudio
import Foundation
@testable import VoxHaloKit

enum FakeCoreAudioTapStep: String, CaseIterable, Sendable {
    case createProcessTap
    case readTapUID
    case readTapFormat
    case createAggregate
    case destroyAggregate
    case destroyProcessTap
}

final class FakeCoreAudioTapAPI: CoreAudioTapAPI, @unchecked Sendable {
    static let tapID = AudioObjectID(101)
    static let aggregateID = AudioDeviceID(202)

    private let lock = NSLock()
    private let createdTapUID: String
    private let createdTapFormat: AudioStreamBasicDescription
    private let failureStatus: OSStatus
    private var failuresRemaining: [FakeCoreAudioTapStep: Int]
    private var storedCalls: [String] = []
    private var storedProcessConfiguration: ProcessTapConfiguration?
    private var storedAggregateConfiguration: AggregateTapConfiguration?
    private var storedLiveTapIDs: Set<AudioObjectID> = []
    private var storedLiveAggregateIDs: Set<AudioDeviceID> = []

    init(
        createdTapUID: String = "actual-tap-uid",
        tapFormat: AudioStreamBasicDescription = FakeCoreAudioTapAPI.defaultFormat(),
        failingAt step: FakeCoreAudioTapStep? = nil,
        failureStatus: OSStatus = -1,
        failureCount: Int = 1
    ) {
        self.createdTapUID = createdTapUID
        createdTapFormat = tapFormat
        self.failureStatus = failureStatus
        failuresRemaining = step.map { [$0: failureCount] } ?? [:]
    }

    var calls: [String] { lock.withLock { storedCalls } }
    var processTapConfiguration: ProcessTapConfiguration? {
        lock.withLock { storedProcessConfiguration }
    }
    var aggregateConfiguration: AggregateTapConfiguration? {
        lock.withLock { storedAggregateConfiguration }
    }
    var liveTapIDs: Set<AudioObjectID> { lock.withLock { storedLiveTapIDs } }
    var liveAggregateIDs: Set<AudioDeviceID> {
        lock.withLock { storedLiveAggregateIDs }
    }

    func createProcessTap(
        _ configuration: ProcessTapConfiguration
    ) throws -> AudioObjectID {
        try lock.withLock {
            storedCalls.append(FakeCoreAudioTapStep.createProcessTap.rawValue)
            storedProcessConfiguration = configuration
            try failIfNeeded(.createProcessTap)
            storedLiveTapIDs.insert(Self.tapID)
            return Self.tapID
        }
    }

    func tapUID(_ tapID: AudioObjectID) throws -> String {
        try lock.withLock {
            storedCalls.append(FakeCoreAudioTapStep.readTapUID.rawValue)
            precondition(storedLiveTapIDs.contains(tapID))
            try failIfNeeded(.readTapUID)
            return createdTapUID
        }
    }

    func tapFormat(
        _ tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        try lock.withLock {
            storedCalls.append(FakeCoreAudioTapStep.readTapFormat.rawValue)
            precondition(storedLiveTapIDs.contains(tapID))
            try failIfNeeded(.readTapFormat)
            return createdTapFormat
        }
    }

    func createAggregate(
        _ configuration: AggregateTapConfiguration
    ) throws -> AudioDeviceID {
        try lock.withLock {
            storedCalls.append(FakeCoreAudioTapStep.createAggregate.rawValue)
            storedAggregateConfiguration = configuration
            try failIfNeeded(.createAggregate)
            storedLiveAggregateIDs.insert(Self.aggregateID)
            return Self.aggregateID
        }
    }

    func destroyAggregate(_ deviceID: AudioDeviceID) throws {
        try lock.withLock {
            storedCalls.append(FakeCoreAudioTapStep.destroyAggregate.rawValue)
            try failIfNeeded(.destroyAggregate)
            storedLiveAggregateIDs.remove(deviceID)
        }
    }

    func destroyProcessTap(_ tapID: AudioObjectID) throws {
        try lock.withLock {
            storedCalls.append(FakeCoreAudioTapStep.destroyProcessTap.rawValue)
            try failIfNeeded(.destroyProcessTap)
            storedLiveTapIDs.remove(tapID)
        }
    }

    private func failIfNeeded(_ step: FakeCoreAudioTapStep) throws {
        let remaining = failuresRemaining[step, default: 0]
        guard remaining > 0 else { return }
        failuresRemaining[step] = remaining - 1
        throw AudioCaptureFailure.coreAudio(
            operation: step.rawValue,
            status: failureStatus
        )
    }

    static func defaultFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock { values.removeFirst() }
    }
}
