import Foundation
import XCTest
@testable import VoxHaloKit

@MainActor
final class SubtitleUIUpdatePumpTests: XCTestCase {
    func testBurstCoalescesToLatestModelAfter150Milliseconds() {
        let scheduler = ManualMainActorScheduler()
        var applied: [SubtitleDisplayModel] = []
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .milliseconds(150),
            scheduler: scheduler
        ) { applied.append($0) }

        pump.post(model("one"))
        pump.post(model("two"))
        pump.post(model("three"))

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(by: .milliseconds(149))
        XCTAssertTrue(applied.isEmpty)
        scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(applied.map(\.primaryText), ["three"])
    }

    func testZeroIntervalStillNeverAppliesSynchronously() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .zero,
            scheduler: scheduler
        ) { applied.append($0.primaryText) }

        pump.post(model("first"))

        XCTAssertTrue(applied.isEmpty)
        scheduler.runReady()
        XCTAssertEqual(applied, ["first"])
    }

    func testCanScheduleAnotherBatchAfterCurrentBatchIsApplied() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .zero,
            scheduler: scheduler
        ) { applied.append($0.primaryText) }

        pump.post(model("first"))
        scheduler.runReady()
        pump.post(model("second"))
        scheduler.runReady()

        XCTAssertEqual(applied, ["first", "second"])
        XCTAssertEqual(scheduler.scheduleCount, 2)
    }

    func testSubsequentBurstWaitsForRemainingMinimumInterval() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .milliseconds(80),
            scheduler: scheduler
        ) { applied.append($0.primaryText) }
        pump.post(model("first"))
        scheduler.advance(by: .milliseconds(80))

        pump.post(model("second"))
        pump.post(model("latest"))
        scheduler.advance(by: .milliseconds(79))
        XCTAssertEqual(applied, ["first"])

        scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(applied, ["first", "latest"])
    }

    func testInteractiveChangeDefersLatestUntilMoveCompletes() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .milliseconds(150),
            scheduler: scheduler
        ) { applied.append($0.primaryText) }

        pump.beginInteractiveChange()
        pump.post(model("first"))
        pump.post(model("latest"))
        scheduler.advance(by: .seconds(1))
        XCTAssertTrue(applied.isEmpty)

        pump.endInteractiveChange()
        XCTAssertTrue(applied.isEmpty)
        scheduler.runReady()
        XCTAssertEqual(applied, ["latest"])
    }

    func testAlreadyQueuedApplyKeepsOriginalDeadlineAcrossInteractiveChange() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .milliseconds(150),
            scheduler: scheduler
        ) { applied.append($0.primaryText) }

        pump.post(model("queued"))
        pump.beginInteractiveChange()
        scheduler.advance(by: .milliseconds(149))
        pump.endInteractiveChange()
        scheduler.runReady()
        XCTAssertTrue(applied.isEmpty)

        scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(applied, ["queued"])
    }

    func testApplyCanSynchronouslyPostAnotherModelWithoutLosingIt() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        let pumpReference = WeakSubtitlePumpReference()
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .zero,
            scheduler: scheduler
        ) { value in
            applied.append(value.primaryText)
            if value.primaryText == "first" {
                pumpReference.value?.post(self.model("second"))
            }
        }
        pumpReference.value = pump

        pump.post(model("first"))
        scheduler.runReady()

        XCTAssertEqual(applied, ["first", "second"])
    }

    func testCancelDropsPendingModelAndScheduledDeadline() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        let pump = SubtitleUIUpdatePump(
            minimumInterval: .milliseconds(150),
            scheduler: scheduler
        ) { applied.append($0.primaryText) }
        pump.post(model("pending"))

        pump.cancel()
        scheduler.advance(by: .seconds(1))

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDeinitCancelsScheduledDeadline() {
        let scheduler = ManualMainActorScheduler()
        var applied: [String] = []
        var pump: SubtitleUIUpdatePump? = SubtitleUIUpdatePump(
            minimumInterval: .milliseconds(150),
            scheduler: scheduler
        ) { applied.append($0.primaryText) }
        pump?.post(model("pending"))
        XCTAssertEqual(scheduler.pendingCount, 1)

        pump = nil
        scheduler.advance(by: .seconds(1))

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    private func model(_ primaryText: String) -> SubtitleDisplayModel {
        SubtitleDisplayModel(
            primaryText: primaryText,
            referenceText: primaryText,
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        )
    }
}

@MainActor
private final class WeakSubtitlePumpReference {
    weak var value: SubtitleUIUpdatePump?
}
