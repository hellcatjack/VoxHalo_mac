public protocol AudioCapturing: Sendable {
    func start(
        source: AudioSource,
        onFrame: @escaping @Sendable (CapturedAudioFrame) -> Void,
        onFailure: @escaping @Sendable (AudioCaptureFailure) -> Void
    ) async throws

    func stop() async
}
