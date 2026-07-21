import Foundation

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func record(_ value: String) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}
