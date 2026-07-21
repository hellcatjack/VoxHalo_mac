import Foundation
@testable import VoxHaloKit

actor FakeAudioCapture: AudioCapturing {
    private let calls: CallRecorder
    private let startError: (any Error & Sendable)?
    private var frameHandler: (@Sendable (CapturedAudioFrame) -> Void)?
    private var failureHandler: (@Sendable (AudioCaptureFailure) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var source: AudioSource?

    init(
        calls: CallRecorder,
        startError: (any Error & Sendable)? = nil
    ) {
        self.calls = calls
        self.startError = startError
    }

    func start(
        source: AudioSource,
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void
    ) async throws {
        calls.record("audio.start:\(source.id)")
        startCount += 1
        self.source = source
        frameHandler = onFrame
        failureHandler = onFailure
        if let startError { throw startError }
    }

    func stop() async {
        calls.record("audio.stop")
        stopCount += 1
        frameHandler = nil
        failureHandler = nil
    }

    func emit(_ frame: CapturedAudioFrame) {
        frameHandler?(frame)
    }

    func fail(_ failure: AudioCaptureFailure) {
        failureHandler?(failure)
    }
}
