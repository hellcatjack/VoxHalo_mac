import CoreAudio
import Foundation

public protocol AudioDeviceCataloging: AudioSourceValidating, Sendable {
    func sources() throws -> [AudioSource]
    func deviceID(forUID uid: String) throws -> AudioDeviceID
    func startObserving(
        _ onChange: @escaping @Sendable ([AudioSource]) -> Void
    ) throws
    func stopObserving()
}

public final class CoreAudioDeviceCatalog: AudioDeviceCataloging, @unchecked Sendable {
    public static let privateAggregateUIDPrefix = "com.voxhalo.private-aggregate."

    private let hardware: any CoreAudioHardwareProviding
    private let stateQueue = DispatchQueue(label: "VoxHalo.CoreAudioDeviceCatalog")
    private var lastSnapshot: [AudioSource]?
    private var knownHardwareUIDs: Set<String> = []
    private var onChange: (@Sendable ([AudioSource]) -> Void)?
    private var isObserving = false

    public init(hardware: any CoreAudioHardwareProviding = CoreAudioHardware()) {
        self.hardware = hardware
    }

    public func sources() throws -> [AudioSource] {
        let snapshot = try makeSnapshot()
        stateQueue.sync {
            knownHardwareUIDs.formUnion(snapshot.dropFirst().map(\.id))
        }
        return snapshot
    }

    public func deviceID(forUID uid: String) throws -> AudioDeviceID {
        guard let device = try hardware.devices().filter({ device in
            guard let identity = eligibleIdentity(for: device) else { return false }
            return identity.uid == uid
        }).min(by: { $0.id < $1.id }) else {
            throw AudioCaptureFailure.deviceUnavailable(uid: uid)
        }
        _ = stateQueue.sync { knownHardwareUIDs.insert(uid) }
        return device.id
    }

    public func validateAvailable(_ source: AudioSource) throws {
        guard source.kind == .hardwareInput else { return }
        let available = try makeSnapshot().contains(where: { $0.id == source.id })
        if available {
            _ = stateQueue.sync { knownHardwareUIDs.insert(source.id) }
            return
        }
        let wasKnown = stateQueue.sync { knownHardwareUIDs.contains(source.id) }
        if wasKnown {
            throw AudioCaptureFailure.deviceDisconnected(uid: source.id)
        }
        throw AudioCaptureFailure.deviceUnavailable(uid: source.id)
    }

    public func startObserving(
        _ onChange: @escaping @Sendable ([AudioSource]) -> Void
    ) throws {
        stopObserving()
        let initial = try sources()
        stateQueue.sync {
            lastSnapshot = initial
            self.onChange = onChange
        }
        do {
            try hardware.startObservingChanges { [weak self] in
                self?.refresh()
            }
            stateQueue.sync { isObserving = true }
        } catch {
            stateQueue.sync {
                lastSnapshot = nil
                self.onChange = nil
                isObserving = false
            }
            throw error
        }
    }

    public func stopObserving() {
        let shouldStop = stateQueue.sync {
            let wasObserving = isObserving
            isObserving = false
            lastSnapshot = nil
            onChange = nil
            return wasObserving
        }
        if shouldStop {
            hardware.stopObservingChanges()
        }
    }

    deinit {
        if stateQueue.sync(execute: { isObserving }) {
            hardware.stopObservingChanges()
        }
    }

    private func refresh() {
        guard let snapshot = try? makeSnapshot() else { return }
        let callback: (@Sendable ([AudioSource]) -> Void)? = stateQueue.sync {
            knownHardwareUIDs.formUnion(snapshot.dropFirst().map(\.id))
            guard snapshot != lastSnapshot else { return nil }
            lastSnapshot = snapshot
            return onChange
        }
        callback?(snapshot)
    }

    private func makeSnapshot() throws -> [AudioSource] {
        var uniqueDevices: [String: CoreAudioDeviceDescription] = [:]
        for device in try hardware.devices() {
            guard let identity = eligibleIdentity(for: device) else { continue }
            if let existing = uniqueDevices[identity.uid], existing.id <= device.id {
                continue
            }
            uniqueDevices[identity.uid] = device
        }
        let hardwareSources = uniqueDevices.values.compactMap { device -> AudioSource? in
            guard let identity = eligibleIdentity(for: device) else { return nil }
            return AudioSource(
                id: identity.uid,
                name: identity.name,
                kind: .hardwareInput
            )
        }.sorted { lhs, rhs in
            let leftName = lhs.name.lowercased()
            let rightName = rhs.name.lowercased()
            return leftName == rightName ? lhs.id < rhs.id : leftName < rightName
        }
        return [.systemAudio] + hardwareSources
    }

    private func eligibleIdentity(
        for device: CoreAudioDeviceDescription
    ) -> (uid: String, name: String)? {
        let uid = device.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard device.isAlive,
              device.inputChannels > 0,
              !uid.isEmpty,
              !name.isEmpty,
              !uid.hasPrefix(Self.privateAggregateUIDPrefix) else {
            return nil
        }
        return (uid, name)
    }
}
