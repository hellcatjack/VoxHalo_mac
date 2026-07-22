import Foundation

public struct AudioCapturePipelineProgress: Equatable, Sendable {
    public let callbackCount: UInt64
    public let sourcePacketCount: UInt64
    public let sourceFrameCount: UInt64
    public let sourceByteCount: UInt64
    public let ringWriteFailureCount: UInt64
    public let lastNativeStatus: Int32
    public let convertedByteCount: UInt64
    public let deliveredFrameCount: UInt64

    public init(
        callbackCount: UInt64,
        sourcePacketCount: UInt64,
        sourceFrameCount: UInt64,
        sourceByteCount: UInt64,
        ringWriteFailureCount: UInt64,
        lastNativeStatus: Int32,
        convertedByteCount: UInt64,
        deliveredFrameCount: UInt64
    ) {
        self.callbackCount = callbackCount
        self.sourcePacketCount = sourcePacketCount
        self.sourceFrameCount = sourceFrameCount
        self.sourceByteCount = sourceByteCount
        self.ringWriteFailureCount = ringWriteFailureCount
        self.lastNativeStatus = lastNativeStatus
        self.convertedByteCount = convertedByteCount
        self.deliveredFrameCount = deliveredFrameCount
    }

    func includingWorkerCounts(
        convertedByteCount: UInt64,
        deliveredFrameCount: UInt64
    ) -> Self {
        Self(
            callbackCount: callbackCount,
            sourcePacketCount: sourcePacketCount,
            sourceFrameCount: sourceFrameCount,
            sourceByteCount: sourceByteCount,
            ringWriteFailureCount: ringWriteFailureCount,
            lastNativeStatus: lastNativeStatus,
            convertedByteCount: convertedByteCount,
            deliveredFrameCount: deliveredFrameCount
        )
    }
}
