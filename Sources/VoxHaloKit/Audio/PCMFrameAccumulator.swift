import Foundation

public final class PCMFrameAccumulator {
    private var remainder: Data
    private let reservedCapacity = VoxBridgePCMFormat.frameByteCount

    public init() {
        remainder = Data()
        remainder.reserveCapacity(VoxBridgePCMFormat.frameByteCount)
    }

    public var remainderByteCount: Int { remainder.count }

    public var scratchCapacity: Int {
        reservedCapacity
    }

    public func append(_ bytes: Data) -> [Data] {
        guard !bytes.isEmpty else { return [] }
        var frames: [Data] = []
        var offset = bytes.startIndex

        while offset < bytes.endIndex {
            let needed = VoxBridgePCMFormat.frameByteCount - remainder.count
            let available = bytes.distance(from: offset, to: bytes.endIndex)
            let copied = min(needed, available)
            let end = bytes.index(offset, offsetBy: copied)
            remainder.append(contentsOf: bytes[offset ..< end])
            offset = end

            if remainder.count == VoxBridgePCMFormat.frameByteCount {
                frames.append(remainder)
                remainder = Data()
                remainder.reserveCapacity(VoxBridgePCMFormat.frameByteCount)
            }
        }
        return frames
    }

    public func discardRemainder() {
        remainder.removeAll(keepingCapacity: true)
    }
}
