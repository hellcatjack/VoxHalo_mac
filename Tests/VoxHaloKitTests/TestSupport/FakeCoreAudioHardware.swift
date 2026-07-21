import CoreAudio
import Foundation
@testable import VoxHaloKit

final class FakeCoreAudioHardware: CoreAudioHardwareProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDevices: [CoreAudioDeviceDescription]
    private var observer: (@Sendable () -> Void)?
    private(set) var startObservingCount = 0
    private(set) var stopObservingCount = 0

    init(devices: [CoreAudioDeviceDescription]) {
        storedDevices = devices
    }

    func devices() throws -> [CoreAudioDeviceDescription] {
        lock.lock()
        defer { lock.unlock() }
        return storedDevices
    }

    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void) throws {
        lock.lock()
        observer = onChange
        startObservingCount += 1
        lock.unlock()
    }

    func stopObservingChanges() {
        lock.lock()
        observer = nil
        stopObservingCount += 1
        lock.unlock()
    }

    func replaceDevices(_ devices: [CoreAudioDeviceDescription], notify: Bool = true) {
        lock.lock()
        storedDevices = devices
        let observer = notify ? observer : nil
        lock.unlock()
        observer?()
    }

    func notifyWithoutChange() {
        lock.lock()
        let observer = observer
        lock.unlock()
        observer?()
    }
}

actor FakeMicrophonePermissionClient: MicrophonePermissionChecking {
    var statusValue: MicrophonePermissionStatus
    var requestResult: Bool
    private(set) var statusCount = 0
    private(set) var requestCount = 0

    init(status: MicrophonePermissionStatus, requestResult: Bool = false) {
        statusValue = status
        self.requestResult = requestResult
    }

    func status() async -> MicrophonePermissionStatus {
        statusCount += 1
        return statusValue
    }

    func request() async -> Bool {
        requestCount += 1
        return requestResult
    }

    func counts() -> (status: Int, request: Int) {
        (statusCount, requestCount)
    }
}
