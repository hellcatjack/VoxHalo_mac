import Foundation
import XCTest
@testable import VoxHaloKit

final class RealtimeAudioBufferRingTests: XCTestCase {
    func testFixedCapacityPreservesFIFOAndCountsDrops() throws {
        let ring = try XCTUnwrap(
            RealtimeAudioBufferRing(slotCount: 2, bytesPerSlot: 8)
        )

        XCTAssertTrue(ring.write(
            Data([1, 2]),
            frameCount: 1,
            callbackTimestamp: .init(nanosecondsSinceBoot: 10)
        ))
        XCTAssertTrue(ring.write(
            Data([3, 4, 5, 6]),
            frameCount: 2,
            callbackTimestamp: .init(nanosecondsSinceBoot: 20)
        ))
        XCTAssertFalse(ring.write(
            Data([7]),
            frameCount: 1,
            callbackTimestamp: .init(nanosecondsSinceBoot: 30)
        ))
        XCTAssertEqual(ring.droppedPacketCount, 1)

        XCTAssertEqual(ring.read(), RealtimeAudioPacket(
            bytes: Data([1, 2]),
            frameCount: 1,
            callbackTimestamp: .init(nanosecondsSinceBoot: 10)
        ))
        XCTAssertEqual(ring.read(), RealtimeAudioPacket(
            bytes: Data([3, 4, 5, 6]),
            frameCount: 2,
            callbackTimestamp: .init(nanosecondsSinceBoot: 20)
        ))
        XCTAssertNil(ring.read())
    }

    func testResetDropsOldGenerationAndClearsDropCounter() throws {
        let ring = try XCTUnwrap(
            RealtimeAudioBufferRing(slotCount: 1, bytesPerSlot: 4)
        )
        let initialGeneration = ring.generation
        XCTAssertTrue(ring.write(
            Data([1]),
            frameCount: 1,
            callbackTimestamp: .init(nanosecondsSinceBoot: 1)
        ))
        XCTAssertFalse(ring.write(
            Data([2]),
            frameCount: 1,
            callbackTimestamp: .init(nanosecondsSinceBoot: 2)
        ))

        ring.reset()

        XCTAssertGreaterThan(ring.generation, initialGeneration)
        XCTAssertEqual(ring.droppedPacketCount, 0)
        XCTAssertNil(ring.read())
        XCTAssertTrue(ring.write(
            Data([3, 4]),
            frameCount: 1,
            callbackTimestamp: .init(nanosecondsSinceBoot: 3)
        ))
        XCTAssertEqual(ring.read()?.bytes, Data([3, 4]))
    }

    func testOversizedPacketIsRejectedWithoutCorruptingQueuedData() throws {
        let ring = try XCTUnwrap(
            RealtimeAudioBufferRing(slotCount: 2, bytesPerSlot: 4)
        )
        XCTAssertTrue(ring.write(
            Data([9, 8, 7, 6]),
            frameCount: 2,
            callbackTimestamp: .init(nanosecondsSinceBoot: 50)
        ))
        XCTAssertFalse(ring.write(
            Data(repeating: 1, count: 5),
            frameCount: 3,
            callbackTimestamp: .init(nanosecondsSinceBoot: 60)
        ))

        XCTAssertEqual(ring.droppedPacketCount, 1)
        XCTAssertEqual(ring.read()?.bytes, Data([9, 8, 7, 6]))
        XCTAssertNil(ring.read())
    }

    func testCallbackStyleWriteReadStressKeepsFixedStorageShape() throws {
        let ring = try XCTUnwrap(
            RealtimeAudioBufferRing(slotCount: 4, bytesPerSlot: 64)
        )
        let bytes = Data(repeating: 0xA5, count: 64)

        for index in 0 ..< 20_000 {
            XCTAssertTrue(ring.write(
                bytes,
                frameCount: 16,
                callbackTimestamp: .init(nanosecondsSinceBoot: UInt64(index))
            ))
            XCTAssertEqual(ring.read()?.bytes, bytes)
        }

        XCTAssertEqual(ring.slotCount, 4)
        XCTAssertEqual(ring.bytesPerSlot, 64)
        XCTAssertEqual(ring.droppedPacketCount, 0)
    }
}
