import Foundation

public enum DiagnosticEvent: Sendable {
    case sessionStart(
        host: String,
        port: Int,
        direction: TranslationDirection,
        username: String?,
        deviceID: String,
        deviceName: String
    )
    case backend(
        type: String,
        sequence: Int?,
        textLength: Int,
        translationLength: Int,
        stability: VoxBridgeStability?,
        transcript: String?,
        translation: String?
    )
    case connection(category: String)
    case audio(frameCount: UInt64, byteCount: Int)
    case capture(category: String)
    case failure(category: String)
}

public protocol DiagnosticsLogging: Sendable {
    func record(_ event: DiagnosticEvent) async
}

public actor DiagnosticsLogger: DiagnosticsLogging {
    public nonisolated let fileURL: URL

    private let isEnabled: Bool
    private let includesTranscripts: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logsDirectory: URL? = nil
    ) throws {
        isEnabled = environment["TRANSLATEPCCS_DIAGNOSTICS"] == "1"
        includesTranscripts = isEnabled
            && environment["TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS"] == "1"

        let directory = logsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VoxHalo", isDirectory: true)
        fileURL = directory.appendingPathComponent("client.log", isDirectory: false)

        guard isEnabled else { return }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func record(_ event: DiagnosticEvent) async {
        guard isEnabled else { return }

        var record: [String: JSONValue] = [
            "timestamp": .string(Self.timestamp()),
        ]

        switch event {
        case let .sessionStart(host, port, direction, _, _, _):
            record["event"] = .string("session_start")
            record["host"] = .string(Self.safeHost(host))
            record["port"] = .integer(Int64(port))
            record["direction"] = .string(direction.backendDirection)
            record["username"] = .string(Self.redacted)
            record["device_id"] = .string(Self.redacted)
            record["device_name"] = .string(Self.redacted)

        case let .backend(
            type,
            sequence,
            textLength,
            translationLength,
            stability,
            transcript,
            translation
        ):
            record["event"] = .string("backend")
            record["type"] = .string(Self.safeCategory(type))
            put(sequence, key: "sequence", in: &record)
            record["text_length"] = .integer(Int64(max(0, textLength)))
            record["translation_length"] = .integer(Int64(max(0, translationLength)))
            if let stability {
                record["stability"] = .object(Self.stabilityMetadata(stability))
            }
            if let transcript {
                record["transcript"] = .string(loggableBody(transcript))
            }
            if let translation {
                record["translation"] = .string(loggableBody(translation))
            }

        case let .connection(category):
            record["event"] = .string("connection")
            record["category"] = .string(Self.safeCategory(category))

        case let .audio(frameCount, byteCount):
            record["event"] = .string("audio")
            record["frame_count"] = .integer(Int64(clamping: frameCount))
            record["byte_count"] = .integer(Int64(max(0, byteCount)))

        case let .capture(category):
            record["event"] = .string("capture")
            record["category"] = .string(Self.safeCategory(category))

        case let .failure(category):
            record["event"] = .string("failure")
            record["category"] = .string(Self.safeCategory(category))
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(record)
            data.append(0x0A)

            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            // Diagnostics must never disrupt capture, translation, or shutdown.
        }
    }

    private func loggableBody(_ body: String) -> String {
        guard includesTranscripts, !Self.containsSensitiveMaterial(body) else {
            return Self.redacted
        }
        return body
    }

    private func put(
        _ value: Int?,
        key: String,
        in record: inout [String: JSONValue]
    ) {
        if let value {
            record[key] = .integer(Int64(value))
        }
    }

    private static func stabilityMetadata(
        _ stability: VoxBridgeStability
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        if let value = stability.isStable { metadata["is_stable"] = .bool(value) }
        if let value = stability.phase { metadata["phase"] = .string(safeCategory(value)) }
        if let value = stability.reason { metadata["reason"] = .string(safeCategory(value)) }
        if let value = stability.segmentID { metadata["segment_id"] = .integer(Int64(value)) }
        if let value = stability.sequence { metadata["sequence"] = .integer(Int64(value)) }
        if let value = stability.committedCount {
            metadata["committed_count"] = .integer(Int64(value))
        }
        if let value = stability.tentativeCharacters {
            metadata["tentative_characters"] = .integer(Int64(value))
        }
        if let value = stability.unstableCharacters {
            metadata["unstable_characters"] = .integer(Int64(value))
        }
        return metadata
    }

    private static func safeCategory(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "_" || scalar == "-" || scalar == "."
                  )
              }) else {
            return redacted
        }
        return value
    }

    private static func safeHost(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard !value.isEmpty, value.utf8.count <= 255,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            return redacted
        }
        return value
    }

    private static func containsSensitiveMaterial(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let markers = [
            "password", "passwd", "cookie", "authorization", "bearer ",
            "access_token", "refresh_token", "id_token", "session_token",
            "api_key", "apikey", "client_secret"
        ]
        if markers.contains(where: lowered.contains) {
            return true
        }
        return lowered.contains("://")
            && (lowered.contains("@") || lowered.contains("?") || lowered.contains("#"))
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    private static let redacted = "[REDACTED]"
}
