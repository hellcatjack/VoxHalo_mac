import AVFAudio

public protocol AudioPermissionProviding: Sendable {
    func authorize(_ source: AudioSource) async throws
}

public enum MicrophonePermissionStatus: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

public protocol MicrophonePermissionChecking: Sendable {
    func status() async -> MicrophonePermissionStatus
    func request() async -> Bool
}

public struct AudioPermissionProvider: AudioPermissionProviding, Sendable {
    private let microphone: any MicrophonePermissionChecking

    public init(
        microphone: any MicrophonePermissionChecking = AVMicrophonePermissionClient()
    ) {
        self.microphone = microphone
    }

    public func authorize(_ source: AudioSource) async throws {
        guard source.kind == .hardwareInput else { return }

        switch await microphone.status() {
        case .authorized:
            return
        case .denied, .restricted:
            throw AudioCaptureFailure.microphonePermissionDenied
        case .notDetermined:
            guard await microphone.request() else {
                throw AudioCaptureFailure.microphonePermissionDenied
            }
        }
    }
}

public struct AVMicrophonePermissionClient: MicrophonePermissionChecking, Sendable {
    public init() {}

    public func status() async -> MicrophonePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            .authorized
        case .denied:
            .denied
        case .undetermined:
            .notDetermined
        @unknown default:
            .restricted
        }
    }

    public func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
