import Foundation
import XCTest
@testable import VoxHaloKit

final class BoundedAudioFrameQueueTests: XCTestCase {
    func testFourFrameFIFOAndCallbackTimestamp() async {
        let queue = BoundedAudioFrameQueue(capacity: 4)
        let generation = queue.reset()
        for byte in 1 ... 4 {
            queue.offer(frame(UInt8(byte)), generation: generation)
        }

        for byte in 1 ... 4 {
            let event = await queue.next()
            XCTAssertEqual(event, .frame(frame(UInt8(byte))))
        }
    }

    func testFifthFrameClearsStaleFramesAndNextFreshFrameSurvives() async {
        let queue = BoundedAudioFrameQueue(capacity: 4)
        let generation = queue.reset()
        for byte in 1 ... 5 {
            queue.offer(frame(UInt8(byte)), generation: generation)
        }

        let overflow = await queue.next()
        XCTAssertEqual(overflow, .overflow)
        queue.offer(frame(6), generation: generation)
        let fresh = await queue.next()
        XCTAssertEqual(fresh, .frame(frame(6)))
    }

    func testRepeatedOverflowBeforeConsumptionQueuesExactlyOneMarker() async {
        let queue = BoundedAudioFrameQueue(capacity: 2)
        let generation = queue.reset()
        for byte in 1 ... 8 {
            queue.offer(frame(UInt8(byte)), generation: generation)
        }

        let overflow = await queue.next()
        XCTAssertEqual(overflow, .overflow)
        queue.finish(generation: generation)
        let finished = await queue.next()
        XCTAssertNil(finished)
    }

    func testExplicitOverflowClearsFramesAndWakesWaiter() async {
        let queue = BoundedAudioFrameQueue()
        let generation = queue.reset()
        queue.offer(frame(1), generation: generation)
        queue.signalOverflow(generation: generation)

        let overflow = await queue.next()
        XCTAssertEqual(overflow, .overflow)
    }

    func testFinishUnblocksNextAndLateOrStaleOffersAreIgnored() async {
        let queue = BoundedAudioFrameQueue()
        let firstGeneration = queue.reset()
        let waiter = Task { await queue.next() }
        await Task.yield()

        queue.finish(generation: firstGeneration)
        let finishedWaiter = await waiter.value
        XCTAssertNil(finishedWaiter)
        queue.offer(frame(1), generation: firstGeneration)
        let late = await queue.next()
        XCTAssertNil(late)

        let secondGeneration = queue.reset()
        queue.offer(frame(2), generation: firstGeneration)
        queue.offer(frame(3), generation: secondGeneration)
        let fresh = await queue.next()
        XCTAssertEqual(fresh, .frame(frame(3)))
    }

    func testResetEndsPriorWaiterAndUsesMonotonicGeneration() async {
        let queue = BoundedAudioFrameQueue()
        let first = queue.reset()
        let waiter = Task { await queue.next() }
        await Task.yield()

        let second = queue.reset()

        XCTAssertGreaterThan(second, first)
        let prior = await waiter.value
        XCTAssertNil(prior)
        queue.finish(generation: second)
    }

    func testTimestampDurationUsesMonotonicNanoseconds() {
        let early = AudioCallbackTimestamp(nanosecondsSinceBoot: 1_000)
        let late = AudioCallbackTimestamp(nanosecondsSinceBoot: 2_500)

        XCTAssertLessThan(early, late)
        XCTAssertEqual(late.duration(since: early), .nanoseconds(1_500))
    }

    private func frame(_ byte: UInt8) -> CapturedAudioFrame {
        CapturedAudioFrame(
            pcm16LE: Data(repeating: byte, count: 8),
            callbackTimestamp: AudioCallbackTimestamp(
                nanosecondsSinceBoot: UInt64(byte)
            )
        )
    }
}
