import XCTest
@testable import VoxHaloKit

final class SubtitleSessionCoordinatorEventTests: XCTestCase {
    func testKnownEventsPublishImmutableReconciledSubtitleSnapshots() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.client.emit(.event(.committed("s1", "你好", sequence: 1)))
        await fixture.client.emit(.event(.translated("s1", "Hello", sequence: 2)))

        let translated = await waitUntil {
            await fixture.coordinator.currentSubtitle.primaryText == "Hello"
        }
        XCTAssertTrue(translated)
        let snapshots = await output.recorder.subtitles
        XCTAssertTrue(snapshots.contains { $0.referenceText == "你好" })
        XCTAssertEqual(snapshots.last?.primaryText, "Hello")
        XCTAssertEqual(snapshots.last?.referenceText, "你好")
        output.task.cancel()
    }

    func testUnknownAndParseErrorDoNotTerminateBackendOutputPipeline() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .unknown,
            rawType: "future_protocol_event",
            text: "ignored"
        )))
        await fixture.client.emit(.connection(.parseError))
        await fixture.client.emit(.event(.committed("s2", "继续", sequence: 3)))
        await fixture.client.emit(.event(.translated("s2", "Continues", sequence: 4)))

        let continued = await waitUntil {
            await fixture.coordinator.currentSubtitle.primaryText == "Continues"
        }
        let failures = await output.recorder.failures
        XCTAssertTrue(continued)
        XCTAssertTrue(failures.isEmpty)
        output.task.cancel()
    }

    func testFinalFallbackIsAppliedAndReadyStartedNeverGateCapture() async throws {
        let fixture = try SubtitleSessionFixture(direction: .englishToChinese)
        let output = await fixture.recordOutputs()

        try await fixture.coordinator.start(fixture.configuration)
        let startCount = await fixture.audio.startCount
        XCTAssertEqual(startCount, 1)
        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .ready,
            rawType: "ready",
            sampleRate: 16_000
        )))
        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .started,
            rawType: "started"
        )))
        await fixture.client.emit(.event(.final(
            text: "final source",
            translation: "最终译文"
        )))

        let finalized = await waitUntil {
            await fixture.coordinator.currentSubtitle.primaryText == "最终译文"
        }
        let referenceText = await output.recorder.subtitles.last?.referenceText
        XCTAssertTrue(finalized)
        XCTAssertEqual(referenceText, "final source")
        output.task.cancel()
    }

    func testStartedEventReportsAcknowledgedHotwordCount() async throws {
        let fixture = try SubtitleSessionFixture(
            asrContextTerms: ["Elisha", "Qwen3-ASR"]
        )
        let output = await fixture.recordOutputs()
        let client = fixture.client
        await client.setStartProbe {
            await client.emit(.event(VoxBridgeEvent(
                type: .started,
                rawType: "started",
                asrContextActive: true,
                asrContextTermCount: 2,
                asrContextCharacters: 17
            )))
            _ = await waitUntil {
                await output.recorder.statuses.contains(
                    "Running · Hotwords: 2"
                )
            }
        }

        try await fixture.coordinator.start(fixture.configuration)

        let published = await waitUntil {
            await output.recorder.statuses.last == "Running · Hotwords: 2"
        }
        XCTAssertTrue(published)
        output.task.cancel()
    }

    func testStartedEventForEmptyRequestKeepsPlainRunningStatus() async throws {
        let fixture = try SubtitleSessionFixture(asrContextTerms: [])
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .started,
            rawType: "started",
            asrContextActive: false,
            asrContextTermCount: 0,
            asrContextCharacters: 0
        )))

        let published = await waitUntil {
            await output.recorder.statuses.last == "Running"
        }
        XCTAssertTrue(published)
        output.task.cancel()
    }

    func testLegacyStartedEventReportsUnconfirmedNonemptyHotwords() async throws {
        let fixture = try SubtitleSessionFixture(asrContextTerms: ["Elisha"])
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .started,
            rawType: "started"
        )))

        let published = await waitUntil {
            await output.recorder.statuses.last
                == "Running · Hotwords not confirmed"
        }
        XCTAssertTrue(published)
        output.task.cancel()
    }

    func testCapturedFrameUsesOwnedBoundedQueueAndSerializedDrain() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.audio.emit(sessionFrame(0x2A))

        let sent = await waitUntil {
            await fixture.client.audioFrames.count == 1
        }
        let firstFrame = await fixture.client.audioFrames.first
        XCTAssertTrue(sent)
        XCTAssertEqual(firstFrame, sessionFrame(0x2A).pcm16LE)
    }

    func testBackendErrorPublishesStatusButKeepsRunningAndDoesNotFailSession() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)
        let connected = await waitUntil {
            await output.recorder.statuses.contains("Connected")
        }
        XCTAssertTrue(connected)

        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .error,
            rawType: "error",
            message: "Backend temporarily unavailable"
        )))

        let published = await waitUntil {
            await output.recorder.statuses.contains("Backend temporarily unavailable")
        }
        let state = await fixture.coordinator.state
        let failures = await output.recorder.failures
        XCTAssertTrue(published)
        XCTAssertEqual(state, .running)
        XCTAssertTrue(failures.isEmpty)
        output.task.cancel()
    }

    func testConnectionFailuresPublishStableMessagesWithoutRawDetails() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.client.emit(.connection(.receiveError(
            "password cookie authorization private"
        )))
        await fixture.client.emit(.connection(.disconnected))

        let published = await waitUntil {
            let statuses = await output.recorder.statuses
            return statuses.contains("Receive error")
                && statuses.contains("Disconnected")
        }
        let statuses = await output.recorder.statuses
        let rendered = statuses.joined(separator: " ")
        let state = await fixture.coordinator.state
        XCTAssertTrue(published)
        XCTAssertFalse(rendered.contains("password"))
        XCTAssertFalse(rendered.contains("private"))
        XCTAssertEqual(state, .running)
        output.task.cancel()
    }
}
