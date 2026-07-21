import CoreAudio
import CoreFoundation
import Foundation

public struct CoreAudioDeviceDescription: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let isAlive: Bool

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        inputChannels: Int,
        isAlive: Bool
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.isAlive = isAlive
    }
}

public protocol CoreAudioHardwareProviding: AnyObject, Sendable {
    func devices() throws -> [CoreAudioDeviceDescription]
    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void) throws
    func stopObservingChanges()
}

public final class CoreAudioHardware: CoreAudioHardwareProviding, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "VoxHalo.CoreAudioHardware")
    private var deviceListRegistration: ListenerRegistration?
    private var deviceRegistrations: [ListenerRegistration] = []
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    public func devices() throws -> [CoreAudioDeviceDescription] {
        try deviceIDs().map { id in
            CoreAudioDeviceDescription(
                id: id,
                uid: try stringProperty(
                    objectID: id,
                    selector: kAudioDevicePropertyDeviceUID
                ),
                name: try stringProperty(
                    objectID: id,
                    selector: kAudioObjectPropertyName
                ),
                inputChannels: try inputChannelCount(deviceID: id),
                isAlive: try uint32Property(
                    objectID: id,
                    selector: kAudioDevicePropertyDeviceIsAlive
                ) != 0
            )
        }
    }

    public func startObservingChanges(
        _ onChange: @escaping @Sendable () -> Void
    ) throws {
        try listenerQueue.sync {
            stopLocked()
            self.onChange = onChange
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceListChange()
            }
            try addListener(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: &address,
                block: block,
                destination: &deviceListRegistration
            )
            try refreshDeviceListeners()
        }
    }

    public func stopObservingChanges() {
        listenerQueue.sync { stopLocked() }
    }

    deinit {
        stopObservingChanges()
    }

    private func handleDeviceListChange() {
        try? refreshDeviceListeners()
        onChange?()
    }

    private func refreshDeviceListeners() throws {
        for registration in deviceRegistrations {
            remove(registration)
        }
        deviceRegistrations.removeAll()

        for deviceID in try deviceIDs() {
            for selector in [
                kAudioObjectPropertyName,
                kAudioDevicePropertyDeviceIsAlive
            ] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.onChange?()
                }
                var registration: ListenerRegistration?
                try addListener(
                    objectID: deviceID,
                    address: &address,
                    block: block,
                    destination: &registration
                )
                if let registration { deviceRegistrations.append(registration) }
            }
        }
    }

    private func addListener(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        block: @escaping AudioObjectPropertyListenerBlock,
        destination: inout ListenerRegistration?
    ) throws {
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            listenerQueue,
            block
        )
        try check(status, operation: "add property listener")
        destination = ListenerRegistration(
            objectID: objectID,
            address: address,
            block: block
        )
    }

    private func stopLocked() {
        if let deviceListRegistration {
            remove(deviceListRegistration)
        }
        deviceListRegistration = nil
        for registration in deviceRegistrations {
            remove(registration)
        }
        deviceRegistrations.removeAll()
        onChange = nil
    }

    private func remove(_ registration: ListenerRegistration) {
        var address = registration.address
        AudioObjectRemovePropertyListenerBlock(
            registration.objectID,
            &address,
            listenerQueue,
            registration.block
        )
    }

    private func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount
            ),
            operation: "read device-list size"
        )
        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        try ids.withUnsafeMutableBytes { bytes in
            var size = byteCount
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    bytes.baseAddress!
                ),
                operation: "read device list"
            )
        }
        return ids
    }

    private func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
                objectID,
                &address,
                0,
                nil,
                &size,
                value
            ),
            operation: "read string property"
        )
        guard let string = value.pointee else {
            throw AudioCaptureFailure.coreAudio(
                operation: "read string property",
                status: kAudioHardwareUnspecifiedError
            )
        }
        return string as String
    }

    private func uint32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                &value
            ),
            operation: "read integer property"
        )
        return value
    }

    private func inputChannelCount(deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &byteCount
            ),
            operation: "read input stream size"
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        try check(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &byteCount,
                storage
            ),
            operation: "read input streams"
        )
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureFailure.coreAudio(operation: operation, status: status)
        }
    }

    private struct ListenerRegistration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
}
