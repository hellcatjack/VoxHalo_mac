import Foundation
@testable import VoxHaloKit

actor FakeAudioCapture: AudioCapturing {
    private let calls: CallRecorder
    private let startError: (any Error & Sendable)?
    private let failureDuringStart: AudioCaptureFailure?
    private var frameHandler: (@Sendable (CapturedAudioFrame) -> Void)?
    private var failureHandler: (@Sendable (AudioCaptureFailure) -> Void)?
    private var startProbe: (@Sendable () async -> Void)?
    private var historicalFrameHandlers: [
        @Sendable (CapturedAudioFrame) -> Void
    ] = []
    private var historicalFailureHandlers: [
        @Sendable (AudioCaptureFailure) -> Void
    ] = []

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var source: AudioSource?

    init(
        calls: CallRecorder,
        startError: (any Error & Sendable)? = nil,
        failureDuringStart: AudioCaptureFailure? = nil
    ) {
        self.calls = calls
        self.startError = startError
        self.failureDuringStart = failureDuringStart
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
        historicalFrameHandlers.append(onFrame)
        historicalFailureHandlers.append(onFailure)
        if let startProbe { await startProbe() }
        if let failureDuringStart { onFailure(failureDuringStart) }
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

    func emit(_ frames: [CapturedAudioFrame]) {
        for frame in frames { frameHandler?(frame) }
    }

    func fail(_ failure: AudioCaptureFailure) {
        failureHandler?(failure)
    }

    func fail(_ failures: [AudioCaptureFailure]) {
        for failure in failures { failureHandler?(failure) }
    }

    func emitFromStart(_ index: Int, frame: CapturedAudioFrame) {
        historicalFrameHandlers[index](frame)
    }

    func failFromStart(_ index: Int, failure: AudioCaptureFailure) {
        historicalFailureHandlers[index](failure)
    }

    func setStartProbe(_ probe: @escaping @Sendable () async -> Void) {
        startProbe = probe
    }
}
