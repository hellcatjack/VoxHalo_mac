import Foundation
import VoxHaloRealtimeAudio

public struct RealtimeAudioPacket: Equatable, Sendable {
    public let bytes: Data
    public let frameCount: UInt32
    public let callbackTimestamp: AudioCallbackTimestamp

    public init(
        bytes: Data,
        frameCount: UInt32,
        callbackTimestamp: AudioCallbackTimestamp
    ) {
        self.bytes = bytes
        self.frameCount = frameCount
        self.callbackTimestamp = callbackTimestamp
    }
}

public final class RealtimeAudioBufferRing: @unchecked Sendable {
    public let slotCount: Int
    public let bytesPerSlot: Int

    private let pointer: OpaquePointer
    private let consumerLock = NSLock()
    private let generationLock = NSLock()
    private var scratch: Data
    private var storedGeneration: UInt64 = 1

    public init?(slotCount: Int, bytesPerSlot: Int) {
        guard slotCount > 0,
              bytesPerSlot > 0,
              slotCount <= Int(UInt32.max),
              bytesPerSlot <= Int(UInt32.max),
              let pointer = VHRealtimeRingCreate(
                  UInt32(slotCount),
                  UInt32(bytesPerSlot)
              ) else {
            return nil
        }
        self.slotCount = slotCount
        self.bytesPerSlot = bytesPerSlot
        self.pointer = pointer
        scratch = Data(count: bytesPerSlot)
    }

    deinit {
        VHRealtimeRingDestroy(pointer)
    }

    public var generation: UInt64 {
        generationLock.withLock { storedGeneration }
    }

    public var droppedPacketCount: UInt64 {
        VHRealtimeRingDroppedPacketCount(pointer)
    }

    public func reset() {
        consumerLock.withLock {
            VHRealtimeRingReset(pointer)
            generationLock.withLock { storedGeneration &+= 1 }
        }
    }

    @discardableResult
    public func write(
        _ bytes: Data,
        frameCount: UInt32,
        callbackTimestamp: AudioCallbackTimestamp
    ) -> Bool {
        bytes.withUnsafeBytes { rawBytes in
            VHRealtimeRingWrite(
                pointer,
                rawBytes.baseAddress,
                UInt32(clamping: bytes.count),
                frameCount,
                callbackTimestamp.nanosecondsSinceBoot
            )
        }
    }

    public func read() -> RealtimeAudioPacket? {
        consumerLock.withLock {
            var nativePacket = VHRealtimePacket()
            let didRead = scratch.withUnsafeMutableBytes { bytes in
                VHRealtimeRingRead(
                    pointer,
                    bytes.baseAddress,
                    UInt32(clamping: bytes.count),
                    &nativePacket
                )
            }
            if !didRead, nativePacket.byteCount > scratch.count {
                scratch = Data(count: Int(nativePacket.byteCount))
                nativePacket = VHRealtimePacket()
                let retried = scratch.withUnsafeMutableBytes { bytes in
                    VHRealtimeRingRead(
                        pointer,
                        bytes.baseAddress,
                        UInt32(clamping: bytes.count),
                        &nativePacket
                    )
                }
                guard retried else { return nil }
            } else if !didRead {
                return nil
            }

            return RealtimeAudioPacket(
                bytes: Data(scratch.prefix(Int(nativePacket.byteCount))),
                frameCount: nativePacket.frameCount,
                callbackTimestamp: AudioCallbackTimestamp(
                    nanosecondsSinceBoot: nativePacket.callbackNanoseconds
                )
            )
        }
    }

    var nativePointer: OpaquePointer { pointer }
}
