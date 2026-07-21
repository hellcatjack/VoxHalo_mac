import Foundation
import XCTest
@testable import VoxHaloKit

final class SubtitleSessionCoordinatorStartTests: XCTestCase {
    func testStartUsesRequiredOrderResetsBeforeStartAndDoesNotWaitForReady() async throws {
        var populated = SubtitleStateStore(direction: .englishToChinese)
        populated.apply(.committed("old", "old source", sequence: 1))
        populated.apply(.translated("old", "old translation", sequence: 2))
        let fixture = try SubtitleSessionFixture(
            direction: .chineseToEnglish,
            credentials: VoxBridgeAuthCredentials(
                username: "operator",
                password: "memory-only"
            ),
            initialStore: populated
        )
        let output = await fixture.recordOutputs()
        let coordinator = fixture.coordinator
        let resetProbe = ResetProbe()
        await fixture.client.setStartProbe {
            let snapshot = await coordinator.currentSubtitle
            await resetProbe.record(snapshot)
        }

        try await fixture.coordinator.start(fixture.configuration)

        XCTAssertEqual(fixture.calls.values, [
            "validate:endpoint",
            "validate:source",
            "permission:systemAudio",
            "connect",
            "client.start:zh2en",
            "audio.start:system-default-loopback"
        ])
        let resetValue = await resetProbe.value
        let state = await fixture.coordinator.state
        let receivedCredentials = await fixture.client.receivedCredentials
        let receivedDirection = await fixture.client.receivedDirection
        XCTAssertEqual(resetValue, .empty(for: .chineseToEnglish))
        XCTAssertEqual(state, .running)
        XCTAssertEqual(receivedCredentials?.username, "operator")
        XCTAssertEqual(receivedCredentials?.password, "memory-only")
        XCTAssertEqual(receivedDirection, .chineseToEnglish)
        let publishedRunning = await waitUntil {
            await output.recorder.states == [.starting, .running]
        }
        XCTAssertTrue(publishedRunning)
        output.task.cancel()
    }

    func testEndpointRevalidationFailureStopsBeforeSourceValidation() async throws {
        let fixture = try SubtitleSessionFixture(
            endpointError: VoxBridgeEndpointError.invalid
        )
        let output = await fixture.recordOutputs()

        await assertStartFails(fixture)

        XCTAssertEqual(fixture.calls.values, ["validate:endpoint"])
        await assertSingleFailureAndStopped(output.recorder, fixture: fixture)
        output.task.cancel()
    }

    func testSourceValidationFailurePublishesOneFailureAndAcquiresNothing() async throws {
        let fixture = try SubtitleSessionFixture(
            sourceError: FakeSessionFailure.operation("missing device private UID")
        )
        let output = await fixture.recordOutputs()

        await assertStartFails(fixture)

        XCTAssertEqual(fixture.calls.values, [
            "validate:endpoint", "validate:source"
        ])
        await assertSingleFailureAndStopped(output.recorder, fixture: fixture)
        output.task.cancel()
    }

    func testPermissionFailurePublishesOneFailureWithoutSocketCleanup() async throws {
        let microphone = AudioSource(
            id: "private-microphone-uid",
            name: "Private Studio Mic",
            kind: .hardwareInput
        )
        let fixture = try SubtitleSessionFixture(
            source: microphone,
            permissionError: AudioCaptureFailure.microphonePermissionDenied
        )
        let output = await fixture.recordOutputs()

        await assertStartFails(fixture)

        XCTAssertEqual(fixture.calls.values, [
            "validate:endpoint", "validate:source", "permission:hardwareInput"
        ])
        await assertSingleFailureAndStopped(output.recorder, fixture: fixture)
        output.task.cancel()
    }

    func testConnectFailureDoesNotDisconnectUnacquiredSocket() async throws {
        let fixture = try SubtitleSessionFixture(
            connectError: VoxBridgeAuthenticationError.rejected
        )
        let output = await fixture.recordOutputs()

        await assertStartFails(fixture)

        XCTAssertEqual(fixture.calls.values, [
            "validate:endpoint", "validate:source", "permission:systemAudio", "connect"
        ])
        let disconnectCount = await fixture.client.disconnectCount
        XCTAssertEqual(disconnectCount, 0)
        await assertSingleFailureAndStopped(output.recorder, fixture: fixture)
        let failures = await output.recorder.failures
        XCTAssertEqual(failures, ["VoxBridge authentication failed."])
        output.task.cancel()
    }

    func testStartSendFailureDisconnectsOnlyAcquiredSocket() async throws {
        let fixture = try SubtitleSessionFixture(
            clientStartError: VoxBridgeClientError.sendFailed
        )
        let output = await fixture.recordOutputs()

        await assertStartFails(fixture)

        XCTAssertEqual(fixture.calls.values, [
            "validate:endpoint", "validate:source", "permission:systemAudio", "connect",
            "client.start:zh2en", "disconnect"
        ])
        let stopCount = await fixture.audio.stopCount
        XCTAssertEqual(stopCount, 0)
        await assertSingleFailureAndStopped(output.recorder, fixture: fixture)
        output.task.cancel()
    }

    func testAudioStartupFailureRollsBackCaptureThenSocket() async throws {
        let fixture = try SubtitleSessionFixture(
            audioStartError: AudioCaptureFailure.unsupportedFormat
        )
        let output = await fixture.recordOutputs()

        await assertStartFails(fixture)

        XCTAssertEqual(fixture.calls.values, [
            "validate:endpoint", "validate:source", "permission:systemAudio", "connect",
            "client.start:zh2en", "audio.start:system-default-loopback",
            "audio.stop", "disconnect"
        ])
        let stopCount = await fixture.audio.stopCount
        let disconnectCount = await fixture.client.disconnectCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        await assertSingleFailureAndStopped(output.recorder, fixture: fixture)
        output.task.cancel()
    }

    func testSecondStartWhileRunningIsRejectedWithoutMutatingSession() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)

        do {
            try await fixture.coordinator.start(fixture.configuration)
            XCTFail("Expected active-session rejection")
        } catch {
            XCTAssertEqual(error as? SubtitleSessionError, .alreadyActive)
        }

        let connectCount = await fixture.client.connectCount
        let startCount = await fixture.audio.startCount
        let state = await fixture.coordinator.state
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(state, .running)
    }

    private func assertStartFails(
        _ fixture: SubtitleSessionFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await fixture.coordinator.start(fixture.configuration)
            XCTFail("Expected startup failure", file: file, line: line)
        } catch {
            XCTAssertNotEqual(error as? SubtitleSessionError, .alreadyActive,
                              file: file, line: line)
        }
    }

    private func assertSingleFailureAndStopped(
        _ recorder: SessionOutputRecorder,
        fixture: SubtitleSessionFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let publishedFailure = await waitUntil {
            let states = await recorder.states
            let failures = await recorder.failures
            return states.last == .stopped && failures.count == 1
        }
        let state = await fixture.coordinator.state
        let states = await recorder.states
        let failureCount = await recorder.failures.count
        let callsBeforeSafeStop = fixture.calls.values
        await fixture.coordinator.stop()
        XCTAssertTrue(publishedFailure, file: file, line: line)
        XCTAssertEqual(state, .stopped, file: file, line: line)
        XCTAssertEqual(states, [.starting, .stopped], file: file, line: line)
        XCTAssertEqual(failureCount, 1, file: file, line: line)
        XCTAssertEqual(fixture.calls.values, callsBeforeSafeStop,
                       file: file, line: line)
    }
}

private actor ResetProbe {
    private(set) var value: SubtitleDisplayModel?

    func record(_ value: SubtitleDisplayModel) {
        self.value = value
    }
}
