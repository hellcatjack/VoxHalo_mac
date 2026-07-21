@testable import VoxHaloKit

final class FakeAudioSourceValidator: AudioSourceValidating, @unchecked Sendable {
    private let calls: CallRecorder
    private let error: (any Error & Sendable)?

    init(
        calls: CallRecorder,
        error: (any Error & Sendable)? = nil
    ) {
        self.calls = calls
        self.error = error
    }

    func validateAvailable(_ source: AudioSource) throws {
        calls.record("validate:source")
        if let error { throw error }
    }
}
