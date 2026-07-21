import Foundation
import XCTest
@testable import VoxHaloKit

final class SettingsStoreTests: XCTestCase {
    func testMissingSettingsReturnsWindowsCompatibleDefaults() throws {
        let directory = try TemporaryDirectory()
        let settings = try SettingsStore(baseDirectory: directory.url).load()

        XCTAssertEqual(settings.backendURL.absoluteString,
                       "wss://ushome.amycat.com:18024/ws")
        XCTAssertEqual(settings.direction, .chineseToEnglish)
        XCTAssertNil(settings.preferredAudioDeviceID)
        XCTAssertNil(settings.preferredDisplayUUID)
        XCTAssertEqual(settings.targetAreaHeight, 264)
        XCTAssertEqual(settings.targetFontSize, 36)
        XCTAssertEqual(settings.targetTopOffset, 0)
        XCTAssertEqual(settings.targetColor, "#FFFFFF")
        XCTAssertEqual(settings.referenceAreaHeight, 96)
        XCTAssertEqual(settings.referenceFontSize, 24)
        XCTAssertEqual(settings.referenceBottomOffset, 0)
        XCTAssertEqual(settings.referenceColor, "#F4F4F4")
        XCTAssertEqual(settings.authUsername, "admin")
    }

    func testSaveLoadsSafeFieldsWithoutAnyPasswordProperty() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(baseDirectory: directory.url)
        var settings = AppSettings.defaults
        settings.backendURL = URL(string: "ws://example.test/ws")!
        settings.direction = .englishToChinese
        settings.preferredAudioDeviceID = "usb-line-in"
        settings.preferredDisplayUUID = "DISPLAY-UUID"
        settings.targetFontSize = 30
        settings.targetColor = "#ffd966"
        settings.authUsername = " operator "

        try store.save(settings)
        let loaded = try store.load()
        let json = try jsonObject(at: store.settingsURL)

        XCTAssertEqual(loaded.direction, .englishToChinese)
        XCTAssertEqual(loaded.preferredAudioDeviceID, "usb-line-in")
        XCTAssertEqual(loaded.preferredDisplayUUID, "DISPLAY-UUID")
        XCTAssertEqual(loaded.targetColor, "#FFD966")
        XCTAssertEqual(loaded.authUsername, "operator")
        XCTAssertFalse(json.keys.contains {
            $0.caseInsensitiveCompare("AuthPassword") == .orderedSame
        })
    }

    func testLegacyPasswordIsRemovedAndUnknownFieldsSurviveRewrite() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(baseDirectory: directory.url)
        let legacy = #"{"BackendUrl":"wss://ushome.amycat.com:18024/ws","Direction":1,"AuthUsername":"operator","AuthPassword":"legacy-secret","authPassword":"secondary-secret","DisplayMode":1,"PreferredMonitorDeviceName":"DISPLAY1","FutureSetting":{"Enabled":true,"Mode":"preserve-me"}}"#
        try Data(legacy.utf8).write(to: store.settingsURL)

        let loaded = try store.load()
        let persisted = try String(contentsOf: store.settingsURL, encoding: .utf8)
        let json = try jsonObject(at: store.settingsURL)

        XCTAssertEqual(loaded.direction, .englishToChinese)
        XCTAssertEqual(loaded.authUsername, "operator")
        XCTAssertFalse(persisted.contains("legacy-secret"))
        XCTAssertFalse(persisted.contains("secondary-secret"))
        XCTAssertEqual((json["FutureSetting"] as? [String: Any])?["Mode"] as? String,
                       "preserve-me")
        XCTAssertEqual(json["DisplayMode"] as? Int, 1)
        XCTAssertEqual(json["PreferredMonitorDeviceName"] as? String, "DISPLAY1")
    }

    func testURLSanitizerRemovesUserInfoFragmentAndSensitiveQueries() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(baseDirectory: directory.url)
        var settings = AppSettings.defaults
        settings.backendURL = URL(string:
            "ws://name:pass@example.test/ws?room=7&API%5FKEY=x&mode=live#token=fragment")!

        try store.save(settings)
        let text = try String(contentsOf: store.settingsURL, encoding: .utf8)
        let loaded = try store.load()

        XCTAssertEqual(loaded.backendURL.absoluteString,
                       "ws://example.test/ws?room=7&mode=live")
        for secret in ["name:pass", "API_KEY", "fragment"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testAllSensitiveQueryNamesAreRemovedCaseInsensitivelyAfterDecoding() {
        let names = [
            "token", "access_token", "refresh_token", "id_token", "session_token",
            "api_key", "apikey", "password", "passwd", "secret", "client_secret",
            "authorization"
        ]
        for name in names {
            let encoded = name.replacingOccurrences(of: "_", with: "%5F").uppercased()
            let input = URL(string: "wss://example.test/ws?keep=yes&\(encoded)=private")!
            XCTAssertEqual(AppSettings.sanitizedEndpoint(input).absoluteString,
                           "wss://example.test/ws?keep=yes", name)
        }
    }

    func testInvalidAndLegacyEndpointsFallBackToPublicDefault() throws {
        XCTAssertEqual(
            AppSettings.sanitizedEndpoint(URL(string: "https://example.test/ws")!),
            AppSettings.publicEndpoint
        )
        XCTAssertEqual(
            AppSettings.sanitizedEndpoint(URL(string: "ws://192.168.1.31:8024/ws")!),
            AppSettings.publicEndpoint
        )
    }

    func testDuplicateBackendCaseVariantsAreDroppedWithCredentialMaterial() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(baseDirectory: directory.url)
        let legacy = #"{"BackendUrl":"wss://example.test/ws?mode=live","backendUrl":"wss://variant:password@example.test/ws#token=private","Direction":0,"FutureSetting":"preserve-me"}"#
        try Data(legacy.utf8).write(to: store.settingsURL)

        let loaded = try store.load()
        let persisted = try String(contentsOf: store.settingsURL, encoding: .utf8)
        let json = try jsonObject(at: store.settingsURL)

        XCTAssertEqual(loaded.backendURL.absoluteString,
                       "wss://example.test/ws?mode=live")
        XCTAssertFalse(persisted.contains("variant"))
        XCTAssertFalse(persisted.contains("password"))
        XCTAssertFalse(persisted.contains("private"))
        XCTAssertEqual(json.keys.filter {
            $0.caseInsensitiveCompare("BackendUrl") == .orderedSame
        }.count, 1)
        XCTAssertEqual(json["FutureSetting"] as? String, "preserve-me")
    }

    func testNumericValuesNormalizeLikeWindowsAndValidCustomColorsSurvive() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(baseDirectory: directory.url)
        let legacy = ##"{"BackendUrl":"wss://example.test/ws","Direction":0,"TopTranslationAreaHeight":9000,"TopTranslationFontSize":2,"TopTranslationTopOffset":9000,"TopTranslationColor":"#12abEF","RecognitionSubtitleAreaHeight":-4,"RecognitionSubtitleFontSize":9000,"RecognitionSubtitleBottomOffset":9000,"RecognitionSubtitleColor":"not-a-color"}"##
        try Data(legacy.utf8).write(to: store.settingsURL)

        let settings = try store.load()

        XCTAssertEqual(settings.targetAreaHeight, 640)
        XCTAssertEqual(settings.targetFontSize, 18)
        XCTAssertEqual(settings.targetTopOffset, 900)
        XCTAssertEqual(settings.targetColor, "#12ABEF")
        XCTAssertEqual(settings.referenceAreaHeight, 96)
        XCTAssertEqual(settings.referenceFontSize, 42)
        XCTAssertEqual(settings.referenceBottomOffset, 900)
        XCTAssertEqual(settings.referenceColor, "#F4F4F4")
    }

    func testWritesUsePrivateDirectoryAndFilePermissions() throws {
        let parent = try TemporaryDirectory()
        let directory = parent.url.appendingPathComponent("VoxHalo", isDirectory: true)
        let store = SettingsStore(baseDirectory: directory)
        try store.save(.defaults)

        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: store.settingsURL), 0o600)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
