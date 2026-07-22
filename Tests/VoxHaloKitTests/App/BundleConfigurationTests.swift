import Foundation
import XCTest

final class BundleConfigurationTests: XCTestCase {
    func testInfoPlistContainsRequiredIdentityAndPrivacyKeys() throws {
        let plist = try loadPlist("Config/Info.plist")

        XCTAssertEqual(plist["CFBundleName"] as? String, "VoxHalo")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "VoxHalo")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "VoxHalo")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.hellcatjack.voxhalo")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertEqual(plist["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertFalse(try XCTUnwrap(
            plist["NSMicrophoneUsageDescription"] as? String
        ).isEmpty)
        XCTAssertFalse(try XCTUnwrap(
            plist["NSAudioCaptureUsageDescription"] as? String
        ).isEmpty)
    }

    func testInfoPlistContainsApprovedATSException() throws {
        let plist = try loadPlist("Config/Info.plist")
        let ats = try XCTUnwrap(
            plist["NSAppTransportSecurity"] as? [String: Any]
        )

        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    func testEntitlementsAllowAudioInputWithoutAppSandbox() throws {
        let entitlements = try loadPlist("Config/VoxHalo.entitlements")

        XCTAssertEqual(
            entitlements["com.apple.security.device.audio-input"] as? Bool,
            true
        )
        XCTAssertNil(entitlements["com.apple.security.app-sandbox"])
        XCTAssertEqual(entitlements.count, 1)
    }

    private func loadPlist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent(relativePath))
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(value as? [String: Any])
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
