import CoreAudio
import Foundation

public struct ProcessTapConfiguration: Equatable, Sendable {
    public let name: String
    public let uuid: UUID
    public let isPrivate: Bool
    public let excludesProcessObjectIDs: [AudioObjectID]
    public let isMuted: Bool

    public init(
        name: String,
        uuid: UUID,
        isPrivate: Bool,
        excludesProcessObjectIDs: [AudioObjectID],
        isMuted: Bool
    ) {
        self.name = name
        self.uuid = uuid
        self.isPrivate = isPrivate
        self.excludesProcessObjectIDs = excludesProcessObjectIDs
        self.isMuted = isMuted
    }
}

public struct AggregateTapConfiguration: Equatable, Sendable {
    public let name: String
    public let uid: String
    public let tapUID: String
    public let isPrivate: Bool
    public let driftCompensation: Bool
    public let tapAutoStart: Bool

    public init(
        name: String,
        uid: String,
        tapUID: String,
        isPrivate: Bool,
        driftCompensation: Bool,
        tapAutoStart: Bool
    ) {
        self.name = name
        self.uid = uid
        self.tapUID = tapUID
        self.isPrivate = isPrivate
        self.driftCompensation = driftCompensation
        self.tapAutoStart = tapAutoStart
    }
}

public protocol CoreAudioTapAPI: Sendable {
    func createProcessTap(
        _ configuration: ProcessTapConfiguration
    ) throws -> AudioObjectID
    func tapUID(_ tapID: AudioObjectID) throws -> String
    func tapFormat(
        _ tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription
    func createAggregate(
        _ configuration: AggregateTapConfiguration
    ) throws -> AudioDeviceID
    func destroyAggregate(_ deviceID: AudioDeviceID) throws
    func destroyProcessTap(_ tapID: AudioObjectID) throws
}

public struct PreparedCoreAudioTap: Sendable {
    public let aggregateDeviceID: AudioDeviceID
    public let tapFormat: AudioStreamBasicDescription

    public init(
        aggregateDeviceID: AudioDeviceID,
        tapFormat: AudioStreamBasicDescription
    ) {
        self.aggregateDeviceID = aggregateDeviceID
        self.tapFormat = tapFormat
    }
}

public final class CoreAudioTapResources: @unchecked Sendable {
    public static let tapName = "VoxHalo System Audio"

    private let api: any CoreAudioTapAPI
    private let uuidGenerator: @Sendable () -> UUID
    private let lock = NSLock()
    private var tapID: AudioObjectID?
    private var aggregateDeviceID: AudioDeviceID?

    public init(
        api: any CoreAudioTapAPI,
        uuidGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.api = api
        self.uuidGenerator = uuidGenerator
    }

    deinit {
        _ = cleanup()
    }

    public var hasLiveResources: Bool {
        lock.withLock { tapID != nil || aggregateDeviceID != nil }
    }

    public func prepare() throws -> PreparedCoreAudioTap {
        try lock.withLock {
            guard tapID == nil, aggregateDeviceID == nil else {
                throw AudioCaptureFailure.coreAudio(
                    operation: "prepare system audio resources",
                    status: kAudioHardwareIllegalOperationError
                )
            }

            do {
                let processUUID = uuidGenerator()
                let createdTapID = try api.createProcessTap(
                    ProcessTapConfiguration(
                        name: Self.tapName,
                        uuid: processUUID,
                        isPrivate: true,
                        excludesProcessObjectIDs: [],
                        isMuted: false
                    )
                )
                tapID = createdTapID

                let actualTapUID = try api.tapUID(createdTapID)
                let actualTapFormat = try api.tapFormat(createdTapID)
                let aggregateUUID = uuidGenerator()
                let aggregateUID = CoreAudioDeviceCatalog
                    .privateAggregateUIDPrefix
                    + aggregateUUID.uuidString.lowercased()
                let aggregateName = "\(Self.tapName) \(aggregateUUID.uuidString)"
                let createdAggregateID = try api.createAggregate(
                    AggregateTapConfiguration(
                        name: aggregateName,
                        uid: aggregateUID,
                        tapUID: actualTapUID,
                        isPrivate: true,
                        driftCompensation: true,
                        tapAutoStart: false
                    )
                )
                aggregateDeviceID = createdAggregateID
                return PreparedCoreAudioTap(
                    aggregateDeviceID: createdAggregateID,
                    tapFormat: actualTapFormat
                )
            } catch {
                _ = cleanupLocked()
                throw error
            }
        }
    }

    @discardableResult
    public func cleanup() -> [AudioCaptureFailure] {
        lock.withLock { cleanupLocked() }
    }

    private func cleanupLocked() -> [AudioCaptureFailure] {
        var failures: [AudioCaptureFailure] = []
        if let aggregateDeviceID {
            do {
                try api.destroyAggregate(aggregateDeviceID)
                self.aggregateDeviceID = nil
            } catch {
                failures.append(Self.captureFailure(
                    error,
                    fallbackOperation: "destroy private aggregate"
                ))
            }
        }
        if let tapID {
            do {
                try api.destroyProcessTap(tapID)
                self.tapID = nil
            } catch {
                failures.append(Self.captureFailure(
                    error,
                    fallbackOperation: "destroy process tap"
                ))
            }
        }
        return failures
    }

    private static func captureFailure(
        _ error: any Error,
        fallbackOperation: String
    ) -> AudioCaptureFailure {
        if let failure = error as? AudioCaptureFailure {
            return failure
        }
        return .coreAudio(
            operation: fallbackOperation,
            status: kAudioHardwareUnspecifiedError
        )
    }
}

public struct AppleCoreAudioTapAPI: CoreAudioTapAPI, Sendable {
    public init() {}

    public func createProcessTap(
        _ configuration: ProcessTapConfiguration
    ) throws -> AudioObjectID {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses:
                configuration.excludesProcessObjectIDs
        )
        description.name = configuration.name
        description.uuid = configuration.uuid
        description.isPrivate = configuration.isPrivate
        description.muteBehavior = configuration.isMuted ? .muted : .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(description, &tapID),
            operation: "createProcessTap"
        )
        return tapID
    }

    public func tapUID(_ tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                value
            ),
            operation: "readTapUID"
        )
        guard let uid = value.pointee as String?, !uid.isEmpty else {
            throw AudioCaptureFailure.coreAudio(
                operation: "readTapUID",
                status: kAudioHardwareUnspecifiedError
            )
        }
        return uid
    }

    public func tapFormat(
        _ tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &format
            ),
            operation: "readTapFormat"
        )
        return format
    }

    public func createAggregate(
        _ configuration: AggregateTapConfiguration
    ) throws -> AudioDeviceID {
        let tap: [String: Any] = [
            kAudioSubTapUIDKey: configuration.tapUID,
            kAudioSubTapDriftCompensationKey:
                configuration.driftCompensation
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: configuration.name,
            kAudioAggregateDeviceUIDKey: configuration.uid,
            kAudioAggregateDeviceIsPrivateKey: configuration.isPrivate,
            kAudioAggregateDeviceTapListKey: [tap],
            kAudioAggregateDeviceTapAutoStartKey:
                configuration.tapAutoStart
        ]
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(
                description as CFDictionary,
                &deviceID
            ),
            operation: "createAggregate"
        )
        return deviceID
    }

    public func destroyAggregate(_ deviceID: AudioDeviceID) throws {
        try check(
            AudioHardwareDestroyAggregateDevice(deviceID),
            operation: "destroyAggregate"
        )
    }

    public func destroyProcessTap(_ tapID: AudioObjectID) throws {
        try check(
            AudioHardwareDestroyProcessTap(tapID),
            operation: "destroyProcessTap"
        )
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureFailure.coreAudio(
                operation: operation,
                status: status
            )
        }
    }
}
