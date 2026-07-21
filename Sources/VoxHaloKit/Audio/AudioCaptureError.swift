import CoreAudio

public enum AudioCaptureFailure: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case deviceUnavailable(uid: String)
    case deviceDisconnected(uid: String)
    case pipelineOverloaded
    case unsupportedFormat
    case coreAudio(operation: String, status: OSStatus)
}
