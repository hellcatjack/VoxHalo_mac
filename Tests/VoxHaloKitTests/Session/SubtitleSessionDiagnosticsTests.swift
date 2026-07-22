import XCTest
@testable import VoxHaloKit

final class SubtitleSessionDiagnosticsTests: XCTestCase {
    func testSessionStartDiagnosticContainsShapeForPermanentLoggerRedaction() async throws {
        let credentials = VoxBridgeAuthCredentials(
            username: "private-operator",
            password: "private-password"
        )
        let source = AudioSource(
            id: "private-device-uid",
            name: "Private Device Name",
            kind: .hardwareInput
        )
        let fixture = try SubtitleSessionFixture(
            direction: .englishToChinese,
            asrContextTerms: ["private-hotword", "𠮷"],
            source: source,
            credentials: credentials
        )

        try await fixture.coordinator.start(fixture.configuration)

        let event = try await waitForDiagnostic(in: fixture.diagnostics) {
            if case .sessionStart = $0 { true } else { false }
        }
        guard case let .sessionStart(
            host,
            port,
            direction,
            username,
            hotwordCount,
            hotwordCharacters,
            deviceID,
            deviceName
        ) = event else {
            return XCTFail("Expected session start diagnostic")
        }
        XCTAssertEqual(host, "example.test")
        XCTAssertEqual(port, 18_024)
        XCTAssertEqual(direction, .englishToChinese)
        XCTAssertEqual(username, "private-operator")
        XCTAssertEqual(hotwordCount, 2)
        XCTAssertEqual(hotwordCharacters, 17)
        XCTAssertEqual(deviceID, "private-device-uid")
        XCTAssertEqual(deviceName, "Private Device Name")
    }

    func testBackendDiagnosticRecordsOnlyStructuredShapeAndOptionalBodies() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)
        let stability = VoxBridgeStability(
            isStable: false,
            phase: "tentative",
            sequence: 7,
            committedCount: 2
        )
        let backend = VoxBridgeEvent(
            type: .partial,
            rawType: "partial",
            text: "private transcript",
            translation: "private translation",
            sequence: 42,
            asrContextActive: true,
            asrContextTermCount: 2,
            asrContextCharacters: 17,
            stability: stability
        )

        await fixture.client.emit(.event(backend))

        let event = try await waitForDiagnostic(in: fixture.diagnostics) {
            if case .backend = $0 { true } else { false }
        }
        guard case let .backend(
            type,
            sequence,
            textLength,
            translationLength,
            asrContextActive,
            asrContextTermCount,
            asrContextCharacters,
            messageLength,
            recordedStability,
            transcript,
            translation
        ) = event else {
            return XCTFail("Expected backend diagnostic")
        }
        XCTAssertEqual(type, "partial")
        XCTAssertEqual(sequence, 42)
        XCTAssertEqual(textLength, "private transcript".count)
        XCTAssertEqual(translationLength, "private translation".count)
        XCTAssertEqual(asrContextActive, true)
        XCTAssertEqual(asrContextTermCount, 2)
        XCTAssertEqual(asrContextCharacters, 17)
        XCTAssertEqual(messageLength, 0)
        XCTAssertEqual(recordedStability, stability)
        XCTAssertEqual(transcript, "private transcript")
        XCTAssertEqual(translation, "private translation")
    }

    func testConnectionParseAndAudioDiagnosticsUseSafeCategoriesAndCounters() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.emit(.connection(.parseError))
        await fixture.audio.emit(sessionFrame(7))

        let recorded = await waitUntil {
            let events = await fixture.diagnostics.events
            let hasConnection = events.contains {
                if case .connection(category: "connected") = $0 { true } else { false }
            }
            let hasParse = events.contains {
                if case .failure(category: "parse_error") = $0 { true } else { false }
            }
            let hasAudio = events.contains {
                if case .audio(frameCount: 1, byteCount: 10_240) = $0 {
                    true
                } else {
                    false
                }
            }
            return hasConnection && hasParse && hasAudio
        }
        XCTAssertTrue(recorded)
    }

    func testSessionStartDiagnosticUsesDefaultSecurePort() async throws {
        let fixture = try SubtitleSessionFixture(
            endpointURL: URL(string: "wss://default-port.example/ws")!
        )

        try await fixture.coordinator.start(fixture.configuration)

        let event = try await waitForDiagnostic(in: fixture.diagnostics) {
            if case .sessionStart = $0 { true } else { false }
        }
        guard case let .sessionStart(_, port, _, _, _, _, _, _) = event else {
            return XCTFail("Expected session start diagnostic")
        }
        XCTAssertEqual(port, 443)
    }

    func testBackendErrorDiagnosticRetainsOnlyMessageLength() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)
        let privateMessage = "Context rejected for private-hotword"

        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .error,
            rawType: "error",
            message: privateMessage
        )))

        let event = try await waitForDiagnostic(in: fixture.diagnostics) {
            guard case let .backend(type, _, _, _, _, _, _, _, _, _, _) = $0 else {
                return false
            }
            return type == "error"
        }
        guard case let .backend(
            _, _, _, _, _, _, _, messageLength, _, transcript, translation
        ) = event else {
            return XCTFail("Expected backend diagnostic")
        }
        XCTAssertEqual(messageLength, privateMessage.utf16.count)
        XCTAssertNil(transcript)
        XCTAssertNil(translation)
    }

    func testAudioDiagnosticsAreThrottledAfterFirstThreeFrames() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)

        for value in 1 ... 50 {
            await fixture.audio.emit(sessionFrame(UInt8(value)))
            let sent = await waitUntil {
                await fixture.client.audioFrames.count == value
            }
            XCTAssertTrue(sent, "frame \(value)")
        }

        let recorded = await waitUntil {
            let events = await fixture.diagnostics.events
            return events.contains {
                if case .audio(frameCount: 50, byteCount: 10_240) = $0 {
                    true
                } else {
                    false
                }
            }
        }
        let events = await fixture.diagnostics.events
        let frameCounts: [UInt64] = events.compactMap { event in
            guard case let .audio(frameCount, _) = event else { return nil }
            return frameCount
        }
        XCTAssertTrue(recorded)
        XCTAssertEqual(frameCounts, [1, 2, 3, 50])
    }

    func testDisabledDiagnosticsSkipBackendShapeWorkAndPipelineContinues() async throws {
        let diagnostics = DisabledRecordingDiagnosticsLogger()
        let fixture = try SubtitleSessionFixture(
            diagnosticsOverride: diagnostics
        )
        try await fixture.coordinator.start(fixture.configuration)

        for sequence in 0 ..< 1_000 {
            await fixture.client.emit(.event(VoxBridgeEvent(
                type: .unknown,
                rawType: "future_event",
                text: "private transcript \(sequence)",
                translation: "private translation \(sequence)",
                sequence: sequence
            )))
        }
        await fixture.client.emit(.event(.committed("s1", "你好", sequence: 1_001)))
        await fixture.client.emit(.event(.translated("s1", "Hello", sequence: 1_002)))

        let continued = await waitUntil {
            await fixture.coordinator.currentSubtitle.primaryText == "Hello"
        }
        let events = await diagnostics.events
        let backendEvents = events.filter {
            if case .backend = $0 { true } else { false }
        }
        XCTAssertTrue(continued)
        XCTAssertTrue(backendEvents.isEmpty)
    }

    private func waitForDiagnostic(
        in logger: RecordingDiagnosticsLogger,
        matching predicate: @escaping @Sendable (DiagnosticEvent) -> Bool
    ) async throws -> DiagnosticEvent {
        for _ in 0 ..< 1_000 {
            if let event = await logger.events.first(where: predicate) {
                return event
            }
            await Task.yield()
        }
        let event = await logger.events.first(where: predicate)
        return try XCTUnwrap(event)
    }
}
