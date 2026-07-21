import AVFAudio
import Foundation

public enum VoxBridgePCMFormat {
    public static let sampleRate = 16_000.0
    public static let channelCount: AVAudioChannelCount = 1
    public static let frameDurationMilliseconds = 320
    public static let frameByteCount = 10_240
}

public struct AudioCallbackTimestamp: Equatable, Comparable, Sendable {
    public let nanosecondsSinceBoot: UInt64

    public init(nanosecondsSinceBoot: UInt64) {
        self.nanosecondsSinceBoot = nanosecondsSinceBoot
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanosecondsSinceBoot < rhs.nanosecondsSinceBoot
    }

    public func duration(since earlier: Self) -> Duration {
        guard nanosecondsSinceBoot >= earlier.nanosecondsSinceBoot else {
            return .zero
        }
        return .nanoseconds(Int64(clamping:
            nanosecondsSinceBoot - earlier.nanosecondsSinceBoot))
    }
}

public struct CapturedAudioFrame: Equatable, Sendable {
    public let pcm16LE: Data
    public let callbackTimestamp: AudioCallbackTimestamp

    public init(pcm16LE: Data, callbackTimestamp: AudioCallbackTimestamp) {
        self.pcm16LE = pcm16LE
        self.callbackTimestamp = callbackTimestamp
    }
}

public enum AudioFrameQueueEvent: Equatable, Sendable {
    case frame(CapturedAudioFrame)
    case overflow
}
