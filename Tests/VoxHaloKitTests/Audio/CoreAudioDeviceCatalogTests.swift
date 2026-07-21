import CoreAudio
import XCTest
@testable import VoxHaloKit

final class CoreAudioDeviceCatalogTests: XCTestCase {
    func testCatalogStartsWithSyntheticSystemAudioAndOnlyInputDevices() throws {
        let hardware = FakeCoreAudioHardware(devices: [
            device(11, "speaker", "Output", channels: 0),
            device(12, "mic", "USB Mic", channels: 2)
        ])
        let catalog = CoreAudioDeviceCatalog(hardware: hardware)

        XCTAssertEqual(try catalog.sources(), [
            .systemAudio,
            AudioSource(id: "mic", name: "USB Mic", kind: .hardwareInput)
        ])
        XCTAssertEqual(
            AudioSourceSelection.preferred(from: try catalog.sources(), savedID: "missing"),
            .systemAudio
        )
    }

    func testSourcesSortByNameThenPersistentUIDAndResolveTransientDeviceID() throws {
        let hardware = FakeCoreAudioHardware(devices: [
            device(44, "z-uid", "alpha", channels: 1),
            device(33, "a-uid", "Alpha", channels: 1),
            device(22, "beta-uid", "Beta", channels: 1)
        ])
        let catalog = CoreAudioDeviceCatalog(hardware: hardware)

        XCTAssertEqual(try catalog.sources().map(\.id), [
            AudioSource.systemAudioID, "a-uid", "z-uid", "beta-uid"
        ])
        XCTAssertEqual(try catalog.deviceID(forUID: "beta-uid"), 22)
    }

    func testDeadZeroChannelMalformedAndPrivateAggregateDevicesAreExcluded() throws {
        let prefix = CoreAudioDeviceCatalog.privateAggregateUIDPrefix
        let hardware = FakeCoreAudioHardware(devices: [
            device(1, "dead", "Dead", channels: 1, alive: false),
            device(2, "zero", "Zero", channels: 0),
            device(3, "", "Missing UID", channels: 1),
            device(4, "blank-name", "  ", channels: 1),
            device(5, prefix + "session", "VoxHalo Internal", channels: 2),
            device(6, "real", "Real Mic", channels: 1),
            device(7, "real", "Duplicate UID", channels: 1)
        ])
        let catalog = CoreAudioDeviceCatalog(hardware: hardware)

        XCTAssertEqual(try catalog.sources(), [
            .systemAudio,
            AudioSource(id: "real", name: "Real Mic", kind: .hardwareInput)
        ])
        XCTAssertThrowsError(try catalog.deviceID(forUID: prefix + "session"))
    }

    func testRenameAttachRemoveRefreshesExactlyOnceAndUnchangedEventsDeduplicate() throws {
        let initial = [device(1, "mic-a", "Alpha", channels: 1)]
        let hardware = FakeCoreAudioHardware(devices: initial)
        let catalog = CoreAudioDeviceCatalog(hardware: hardware)
        let snapshots = AudioSourceSnapshots()
        try catalog.startObserving { value in
            snapshots.append(value)
        }

        hardware.notifyWithoutChange()
        hardware.replaceDevices([device(1, "mic-a", "Renamed", channels: 1)])
        hardware.notifyWithoutChange()
        hardware.replaceDevices([
            device(1, "mic-a", "Renamed", channels: 1),
            device(2, "mic-b", "Beta", channels: 1)
        ])
        hardware.replaceDevices([device(2, "mic-b", "Beta", channels: 1)])

        let captured = snapshots.values
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured[0].map(\.name), ["System Audio", "Renamed"])
        XCTAssertEqual(captured[1].map(\.id), [
            AudioSource.systemAudioID, "mic-b", "mic-a"
        ])
        XCTAssertEqual(captured[2].map(\.id), [AudioSource.systemAudioID, "mic-b"])

        catalog.stopObserving()
        hardware.replaceDevices(initial)
        XCTAssertEqual(snapshots.values.count, 3)
        XCTAssertEqual(hardware.startObservingCount, 1)
        XCTAssertEqual(hardware.stopObservingCount, 1)
    }

    func testRemovedActiveHardwareReportsDisconnectedInsteadOfSwitching() throws {
        let microphone = AudioSource(id: "mic", name: "USB Mic", kind: .hardwareInput)
        let hardware = FakeCoreAudioHardware(devices: [
            device(7, "mic", "USB Mic", channels: 1)
        ])
        let catalog = CoreAudioDeviceCatalog(hardware: hardware)
        XCTAssertNoThrow(try catalog.validateAvailable(microphone))

        hardware.replaceDevices([], notify: false)

        XCTAssertThrowsError(try catalog.validateAvailable(microphone)) { error in
            XCTAssertEqual(error as? AudioCaptureFailure, .deviceDisconnected(uid: "mic"))
        }
        let neverSeen = AudioSource(id: "other", name: "Other", kind: .hardwareInput)
        XCTAssertThrowsError(try catalog.validateAvailable(neverSeen)) { error in
            XCTAssertEqual(error as? AudioCaptureFailure, .deviceUnavailable(uid: "other"))
        }
    }

    private func device(
        _ id: AudioDeviceID,
        _ uid: String,
        _ name: String,
        channels: Int,
        alive: Bool = true
    ) -> CoreAudioDeviceDescription {
        CoreAudioDeviceDescription(
            id: id,
            uid: uid,
            name: name,
            inputChannels: channels,
            isAlive: alive
        )
    }
}

private final class AudioSourceSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[AudioSource]] = []

    var values: [[AudioSource]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: [AudioSource]) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
