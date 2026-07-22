import Foundation
import XCTest
@testable import VoxHaloKit

final class DiagnosticsLoggerTests: XCTestCase {
    func testDiagnosticsRemainOffUnlessEnvironmentValueIsExactlyOne() throws {
        for value in [nil, "", "true", "01", " 1"] as [String?] {
            let parent = try TemporaryDirectory()
            let logs = parent.url.appendingPathComponent("Logs", isDirectory: true)
            var environment: [String: String] = [:]
            environment["TRANSLATEPCCS_DIAGNOSTICS"] = value

            _ = try DiagnosticsLogger(environment: environment, logsDirectory: logs)

            XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path), value ?? "nil")
        }
    }

    func testEnabledLoggerCreatesPrivateJSONLinesLog() async throws {
        let parent = try TemporaryDirectory()
        let logs = parent.url.appendingPathComponent("Logs", isDirectory: true)
        let logger = try DiagnosticsLogger(
            environment: ["TRANSLATEPCCS_DIAGNOSTICS": "1"],
            logsDirectory: logs
        )

        await logger.record(.connection(category: "connected"))
        let object = try firstRecord(at: logger.fileURL)

        XCTAssertEqual(object["event"] as? String, "connection")
        XCTAssertEqual(object["category"] as? String, "connected")
        XCTAssertTrue(try XCTUnwrap(object["timestamp"] as? String).hasSuffix("Z"))
        XCTAssertEqual(try permissions(of: logs), 0o700)
        XCTAssertEqual(try permissions(of: logger.fileURL), 0o600)
    }

    func testSensitiveIdentityAndDeviceValuesAreAlwaysRedacted() async throws {
        let parent = try TemporaryDirectory()
        let logger = try DiagnosticsLogger(environment: [
            "TRANSLATEPCCS_DIAGNOSTICS": "1",
            "TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS": "1"
        ], logsDirectory: parent.url)

        await logger.record(.sessionStart(
            host: "example.test",
            port: 443,
            direction: .chineseToEnglish,
            username: "operator",
            hotwordCount: 2,
            hotwordCharacters: 17,
            deviceID: "uid-1",
            deviceName: "Studio Mic"
        ))
        let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
        let object = try firstRecord(at: logger.fileURL)

        XCTAssertTrue(text.contains("example.test"))
        for secret in ["operator", "uid-1", "Studio Mic"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertEqual(object["username"] as? String, "[REDACTED]")
        XCTAssertEqual(object["device_id"] as? String, "[REDACTED]")
        XCTAssertEqual(object["device_name"] as? String, "[REDACTED]")
        XCTAssertEqual(object["hotword_count"] as? Int, 2)
        XCTAssertEqual(object["hotword_chars"] as? Int, 17)
    }

    func testTranscriptBodiesDefaultToRedactedWhileMetadataRemains() async throws {
        let parent = try TemporaryDirectory()
        let logger = try DiagnosticsLogger(
            environment: ["TRANSLATEPCCS_DIAGNOSTICS": "1"],
            logsDirectory: parent.url
        )
        let stability = VoxBridgeStability(
            isStable: false,
            phase: "tentative",
            reason: "streaming",
            sentenceID: "sentence-private",
            segmentID: 7,
            sequence: 8,
            committedCount: 9,
            tentativeCharacters: 10,
            unstableCharacters: 11
        )

        await logger.record(.backend(
            type: "partial",
            sequence: 42,
            textLength: 14,
            translationLength: 12,
            asrContextActive: true,
            asrContextTermCount: 2,
            asrContextCharacters: 17,
            messageLength: 0,
            stability: stability,
            transcript: "private transcript",
            translation: "private translation"
        ))
        let object = try firstRecord(at: logger.fileURL)
        let metadata = try XCTUnwrap(object["stability"] as? [String: Any])
        let text = try String(contentsOf: logger.fileURL, encoding: .utf8)

        XCTAssertEqual(object["transcript"] as? String, "[REDACTED]")
        XCTAssertEqual(object["translation"] as? String, "[REDACTED]")
        XCTAssertEqual(object["text_length"] as? Int, 14)
        XCTAssertEqual(object["translation_length"] as? Int, 12)
        XCTAssertEqual(object["sequence"] as? Int, 42)
        XCTAssertEqual(object["asr_context_active"] as? Bool, true)
        XCTAssertEqual(object["asr_context_term_count"] as? Int, 2)
        XCTAssertEqual(object["asr_context_chars"] as? Int, 17)
        XCTAssertEqual(object["message_length"] as? Int, 0)
        XCTAssertEqual(metadata["is_stable"] as? Bool, false)
        XCTAssertEqual(metadata["phase"] as? String, "tentative")
        XCTAssertEqual(metadata["segment_id"] as? Int, 7)
        XCTAssertEqual(metadata["committed_count"] as? Int, 9)
        XCTAssertFalse(text.contains("private transcript"))
        XCTAssertFalse(text.contains("private translation"))
        XCTAssertFalse(text.contains("sentence-private"))
    }

    func testTranscriptBodiesAppearOnlyWithExplicitSecondOptIn() async throws {
        let parent = try TemporaryDirectory()
        let logger = try DiagnosticsLogger(environment: [
            "TRANSLATEPCCS_DIAGNOSTICS": "1",
            "TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS": "1"
        ], logsDirectory: parent.url)

        await logger.record(.backend(
            type: "sentence_translation",
            sequence: nil,
            textLength: 5,
            translationLength: 7,
            asrContextActive: nil,
            asrContextTermCount: nil,
            asrContextCharacters: nil,
            messageLength: 0,
            stability: nil,
            transcript: "hello",
            translation: "bonjour"
        ))
        let object = try firstRecord(at: logger.fileURL)

        XCTAssertEqual(object["transcript"] as? String, "hello")
        XCTAssertEqual(object["translation"] as? String, "bonjour")
    }

    func testCredentialShapedCategoriesAndEndpointShapedHostAreNeverWritten() async throws {
        let parent = try TemporaryDirectory()
        let logger = try DiagnosticsLogger(environment: [
            "TRANSLATEPCCS_DIAGNOSTICS": "1",
            "TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS": "1"
        ], logsDirectory: parent.url)
        let probes = [
            "password=hunter2",
            "Cookie: voxbridge_session=cookie-secret",
            "Authorization: Bearer authorization-secret"
        ]

        for probe in probes {
            await logger.record(.failure(category: probe))
        }
        await logger.record(.backend(
            type: "partial",
            sequence: nil,
            textLength: 1,
            translationLength: 1,
            asrContextActive: nil,
            asrContextTermCount: nil,
            asrContextCharacters: nil,
            messageLength: 0,
            stability: nil,
            transcript: "password=hunter2 Cookie: cookie-secret",
            translation: "Authorization: Bearer authorization-secret"
        ))
        await logger.record(.sessionStart(
            host: "name:pass@example.test?api_key=query-secret",
            port: 443,
            direction: .englishToChinese,
            username: nil,
            hotwordCount: 0,
            hotwordCharacters: 0,
            deviceID: "",
            deviceName: ""
        ))
        let text = try String(contentsOf: logger.fileURL, encoding: .utf8)

        for secret in [
            "hunter2", "cookie-secret", "authorization-secret", "name:pass",
            "query-secret"
        ] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testBackendErrorIsLoggedOnlyByLengthWithoutHotwordText() async throws {
        let parent = try TemporaryDirectory()
        let logger = try DiagnosticsLogger(environment: [
            "TRANSLATEPCCS_DIAGNOSTICS": "1",
            "TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS": "1"
        ], logsDirectory: parent.url)
        let privateMessage = "Context rejected for private-hotword"

        await logger.record(.backend(
            type: "error",
            sequence: nil,
            textLength: 0,
            translationLength: 0,
            asrContextActive: nil,
            asrContextTermCount: nil,
            asrContextCharacters: nil,
            messageLength: privateMessage.utf16.count,
            stability: nil,
            transcript: nil,
            translation: nil
        ))

        let object = try firstRecord(at: logger.fileURL)
        let text = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertEqual(object["message_length"] as? Int, privateMessage.utf16.count)
        XCTAssertFalse(text.contains(privateMessage))
        XCTAssertFalse(text.contains("private-hotword"))
    }

    func testStructuredCounterAndCategoryEventsAppendOneLineEach() async throws {
        let parent = try TemporaryDirectory()
        let logger = try DiagnosticsLogger(
            environment: ["TRANSLATEPCCS_DIAGNOSTICS": "1"],
            logsDirectory: parent.url
        )

        await logger.record(.audio(frameCount: 12, byteCount: 10_240))
        await logger.record(.capture(category: "started"))
        await logger.record(.failure(category: "parse_error"))
        let lines = try String(contentsOf: logger.fileURL, encoding: .utf8)
            .split(separator: "\n")

        XCTAssertEqual(lines.count, 3)
        let audio = try jsonObject(from: lines[0])
        XCTAssertEqual(audio["frame_count"] as? Int, 12)
        XCTAssertEqual(audio["byte_count"] as? Int, 10_240)
    }

    private func firstRecord(at url: URL) throws -> [String: Any] {
        let line = try XCTUnwrap(
            String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
        )
        return try jsonObject(from: line)
    }

    private func jsonObject(from line: Substring) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
