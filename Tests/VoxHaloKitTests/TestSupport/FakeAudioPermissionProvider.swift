@testable import VoxHaloKit

actor FakeAudioPermissionProvider: AudioPermissionProviding {
    private let calls: CallRecorder
    private let error: (any Error & Sendable)?
    private(set) var sources: [AudioSource] = []

    init(
        calls: CallRecorder,
        error: (any Error & Sendable)? = nil
    ) {
        self.calls = calls
        self.error = error
    }

    func authorize(_ source: AudioSource) async throws {
        calls.record("permission:\(source.kind.rawValue)")
        sources.append(source)
        if let error { throw error }
    }
}
