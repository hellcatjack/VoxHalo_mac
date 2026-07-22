import Darwin
import Foundation

public protocol AppSettingsStoring: Sendable {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

public struct SettingsStore: Sendable {
    public let settingsURL: URL

    public init(baseDirectory: URL? = nil) {
        let directory = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VoxHalo", isDirectory: true)
        settingsURL = directory.appendingPathComponent("settings.json", isDirectory: false)
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .defaults
        }

        let root = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(contentsOf: settingsURL)
        )
        let knownNames = Set(Field.allCases.map { $0.rawValue.lowercased() })
        let unknown = root.filter { key, _ in
            let name = key.lowercased()
            return !knownNames.contains(name) && name != "authpassword"
        }

        let backendURL = value(for: .backendURL, in: root)?.stringValue
            .flatMap(URL.init(string:)) ?? AppSettings.publicEndpoint
        let direction = value(for: .direction, in: root)?.intValue
            .flatMap(TranslationDirection.init(rawValue:)) ?? .chineseToEnglish

        let settings = AppSettings(
            backendURL: backendURL,
            direction: direction,
            preferredAudioDeviceID: value(for: .preferredAudioDeviceID, in: root)?.stringValue,
            preferredDisplayUUID: value(for: .preferredDisplayUUID, in: root)?.stringValue,
            targetAreaHeight: value(for: .targetAreaHeight, in: root)?.doubleValue ?? 264,
            targetFontSize: value(for: .targetFontSize, in: root)?.doubleValue ?? 36,
            targetTopOffset: value(for: .targetTopOffset, in: root)?.doubleValue ?? 0,
            targetColor: value(for: .targetColor, in: root)?.stringValue ?? "#FFFFFF",
            authUsername: value(for: .authUsername, in: root)?.stringValue ?? "admin",
            referenceAreaHeight: value(for: .referenceAreaHeight, in: root)?.doubleValue ?? 96,
            referenceFontSize: value(for: .referenceFontSize, in: root)?.doubleValue ?? 24,
            referenceBottomOffset: value(for: .referenceBottomOffset, in: root)?.doubleValue ?? 0,
            referenceColor: value(for: .referenceColor, in: root)?.stringValue ?? "#F4F4F4",
            asrContextTermsText: value(
                for: .asrContextTermsText,
                in: root
            )?.stringValue ?? "",
            unknownFields: unknown
        ).normalized()

        try save(settings)
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let settings = settings.normalized()
        let knownNames = Set(Field.allCases.map { $0.rawValue.lowercased() })
        var root = settings.unknownFields.filter { key, _ in
            let name = key.lowercased()
            return !knownNames.contains(name) && name != "authpassword"
        }

        root[Field.backendURL.rawValue] = .string(settings.backendURL.absoluteString)
        root[Field.direction.rawValue] = .integer(Int64(settings.direction.rawValue))
        put(settings.preferredAudioDeviceID, as: .preferredAudioDeviceID, in: &root)
        put(settings.preferredDisplayUUID, as: .preferredDisplayUUID, in: &root)
        root[Field.targetAreaHeight.rawValue] = .number(settings.targetAreaHeight)
        root[Field.targetFontSize.rawValue] = .number(settings.targetFontSize)
        root[Field.targetTopOffset.rawValue] = .number(settings.targetTopOffset)
        root[Field.targetColor.rawValue] = .string(settings.targetColor)
        root[Field.authUsername.rawValue] = .string(settings.authUsername)
        root[Field.referenceAreaHeight.rawValue] = .number(settings.referenceAreaHeight)
        root[Field.referenceFontSize.rawValue] = .number(settings.referenceFontSize)
        root[Field.referenceBottomOffset.rawValue] = .number(settings.referenceBottomOffset)
        root[Field.referenceColor.rawValue] = .string(settings.referenceColor)
        root[Field.asrContextTermsText.rawValue] = .string(
            settings.asrContextTermsText
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(root)
        data.append(0x0A)
        try writePrivatelyAndAtomically(data)
    }

    private func value(for field: Field, in root: [String: JSONValue]) -> JSONValue? {
        if let canonical = root[field.rawValue] {
            return canonical
        }
        return root.keys.sorted().first {
            $0.caseInsensitiveCompare(field.rawValue) == .orderedSame
        }.flatMap { root[$0] }
    }

    private func put(
        _ value: String?,
        as field: Field,
        in root: inout [String: JSONValue]
    ) {
        if let value {
            root[field.rawValue] = .string(value)
        }
    }

    private func writePrivatelyAndAtomically(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = settingsURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let temporaryURL = directory.appendingPathComponent(
            ".settings-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )

            let result = temporaryURL.path.withCString { source in
                settingsURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private enum Field: String, CaseIterable {
        case backendURL = "BackendUrl"
        case direction = "Direction"
        case preferredAudioDeviceID = "PreferredAudioDeviceId"
        case preferredDisplayUUID = "PreferredDisplayUUID"
        case targetAreaHeight = "TopTranslationAreaHeight"
        case targetFontSize = "TopTranslationFontSize"
        case targetTopOffset = "TopTranslationTopOffset"
        case targetColor = "TopTranslationColor"
        case authUsername = "AuthUsername"
        case referenceAreaHeight = "RecognitionSubtitleAreaHeight"
        case referenceFontSize = "RecognitionSubtitleFontSize"
        case referenceBottomOffset = "RecognitionSubtitleBottomOffset"
        case referenceColor = "RecognitionSubtitleColor"
        case asrContextTermsText = "AsrContextTermsText"
    }
}

extension SettingsStore: AppSettingsStoring {}
