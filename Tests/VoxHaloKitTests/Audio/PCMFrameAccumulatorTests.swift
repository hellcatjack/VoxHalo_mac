import Foundation
import XCTest
@testable import VoxHaloKit

final class PCMFrameAccumulatorTests: XCTestCase {
    func testConstantsDescribe320MillisecondsOfPCM16Mono() {
        XCTAssertEqual(VoxBridgePCMFormat.sampleRate, 16_000)
        XCTAssertEqual(VoxBridgePCMFormat.channelCount, 1)
        XCTAssertEqual(VoxBridgePCMFormat.frameDurationMilliseconds, 320)
        XCTAssertEqual(VoxBridgePCMFormat.frameByteCount, 10_240)
    }

    func testPartialThenExactAppendProducesOneExactFrame() {
        let accumulator = PCMFrameAccumulator()
        XCTAssertTrue(accumulator.append(Data(repeating: 1, count: 2_000)).isEmpty)

        let frames = accumulator.append(Data(repeating: 2, count: 8_240))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 10_240)
        XCTAssertEqual(frames[0].prefix(2_000), Data(repeating: 1, count: 2_000))
        XCTAssertEqual(frames[0].suffix(8_240), Data(repeating: 2, count: 8_240))
        XCTAssertEqual(accumulator.remainderByteCount, 0)
    }

    func testMultipleFramesAndRemainderPreserveByteOrder() {
        let accumulator = PCMFrameAccumulator()
        var input = Data()
        input.append(Data(repeating: 3, count: 10_240))
        input.append(Data(repeating: 4, count: 10_240))
        input.append(Data(repeating: 5, count: 17))

        let frames = accumulator.append(input)

        XCTAssertEqual(frames, [
            Data(repeating: 3, count: 10_240),
            Data(repeating: 4, count: 10_240)
        ])
        XCTAssertEqual(accumulator.remainderByteCount, 17)
    }

    func testDiscardRemainderNeverPadsAndStorageIsReusable() {
        let accumulator = PCMFrameAccumulator()
        _ = accumulator.append(Data(repeating: 9, count: 9_000))
        let capacity = accumulator.scratchCapacity

        accumulator.discardRemainder()
        let frames = accumulator.append(Data(repeating: 7, count: 10_240))

        XCTAssertEqual(frames, [Data(repeating: 7, count: 10_240)])
        XCTAssertEqual(accumulator.remainderByteCount, 0)
        XCTAssertGreaterThanOrEqual(accumulator.scratchCapacity, capacity)
    }
}
