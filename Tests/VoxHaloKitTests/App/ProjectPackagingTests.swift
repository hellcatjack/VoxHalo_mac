import Foundation
import XCTest

final class ProjectPackagingTests: XCTestCase {
    func testPackageAndPlistUseFixedMacOSProductIdentity() throws {
        let package = try text("Package.swift")
        let plist = try propertyList("Config/Info.plist")

        XCTAssertTrue(package.contains("name: \"VoxHalo\""))
        XCTAssertTrue(package.contains(".executable(name: \"VoxHalo\""))
        XCTAssertTrue(package.contains(".macOS(\"26.0\")"))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.hellcatjack.voxhalo")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "VoxHalo")
    }

    func testReleaseScriptBuildsFixedArm64AppPathAndSignsWithEntitlements() throws {
        let script = try text("scripts/build-app.sh")

        XCTAssertTrue(
            script.contains(
                "swift build -c release --arch arm64 --product VoxHalo"
            ))
        XCTAssertTrue(script.contains("dist/VoxHalo.app/Contents/MacOS/VoxHalo"))
        XCTAssertTrue(script.contains("install -m 0755"))
        XCTAssertTrue(script.contains("Config/Info.plist"))
        XCTAssertTrue(script.contains("--options runtime"))
        XCTAssertTrue(script.contains("Config/VoxHalo.entitlements"))
        XCTAssertTrue(script.contains("scripts/verify-app.sh"))
    }

    func testBuildScriptNeverCopiesPrivateRuntimeOrDevelopmentMaterial() throws {
        let script = try text("scripts/build-app.sh")

        for forbidden in [
            "cp -R Sources",
            "cp -R Tests",
            "settings.json",
            "client.log",
            ".build/debug",
            "Package.swift dist",
        ] {
            XCTAssertFalse(script.contains(forbidden), forbidden)
        }
    }

    func testRunHelperBuildsThenOpensANewFixedBundle() throws {
        let script = try text("scripts/run-app.sh")

        XCTAssertTrue(script.contains("scripts/build-app.sh"))
        XCTAssertTrue(script.contains("open -n dist/VoxHalo.app"))
    }

    func testVerifierChecksMetadataArchitectureSignaturePrivacyAndWindowsArtifacts() throws {
        let script = try text("scripts/verify-app.sh")

        for required in [
            "plutil -lint",
            "com.hellcatjack.voxhalo",
            "LSMinimumSystemVersion",
            "26.0",
            "arm64",
            "Security.framework",
            "codesign --verify --deep --strict",
            "runtime",
            "com.apple.security.device.audio-input",
            "com.apple.security.app-sandbox",
            "settings.json",
            "client.log",
            "AuthPassword",
            ".exe",
            ".dll",
            ".pdb",
        ] {
            XCTAssertTrue(script.contains(required), required)
        }
    }

    func testScriptsUseFailFastShellAndAreExecutable() throws {
        for path in [
            "scripts/build-app.sh",
            "scripts/run-app.sh",
            "scripts/verify-app.sh",
        ] {
            let script = try text(path)
            XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"), path)
            XCTAssertTrue(script.contains("set -euo pipefail"), path)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: packageRoot.appendingPathComponent(path).path
            )
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
                .intValue
            XCTAssertNotEqual(mode & 0o111, 0, path)
        }
    }

    func testRepositoryIgnoresNineSensitiveLocalPathPatterns() throws {
        let rules = Set(
            try text(".gitignore")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") })

        for expected in [
            "/.tools/",
            "/.tools8/",
            "/artifacts/",
            "/youtube-playwright-state.png",
            ".env",
            ".env.*",
            "*.key",
            "*.pem",
            "*.pfx",
        ] {
            XCTAssertTrue(rules.contains(expected), expected)
        }
    }

    func testRepositoryContainsSevenOperatorDeveloperAndSecurityDocuments() {
        for path in [
            "README.md",
            "docs/user-guide.md",
            "docs/configuration.md",
            "docs/development.md",
            "docs/architecture.md",
            "docs/security-and-privacy.md",
            "docs/manual-test-checklist.md",
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: packageRoot.appendingPathComponent(path).path
                ), path)
        }
    }

    func testPackageHasNoThirdPartyPinsAndUsesOnlyNativeMacOSKeychainAPI() throws {
        let resolvedURL = packageRoot.appendingPathComponent("Package.resolved")
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            let object =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: resolvedURL)
                ) as? [String: Any]
            let pins =
                (object?["pins"] as? [Any])
                ?? ((object?["object"] as? [String: Any])?["pins"] as? [Any])
                ?? []
            XCTAssertTrue(pins.isEmpty)
        }

        let package = try text("Package.swift")
        XCTAssertTrue(package.contains(".linkedFramework(\"Security\")"))

        let sources = try swiftSourceText(in: "Sources")
        for required in [
            "import Security",
            "SecItemAdd",
            "SecItemCopyMatching",
            "SecItemUpdate",
            "SecItemDelete",
            "kSecClass",
        ] {
            XCTAssertTrue(sources.contains(required), required)
        }
        XCTAssertFalse(sources.contains("AuthPassword"))
    }

    func testReleaseBundleBuildAndVerificationWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["VOXHALO_RUN_PACKAGING_TESTS"] == "1" else {
            throw XCTSkip("Set VOXHALO_RUN_PACKAGING_TESTS=1 for the release bundle gate.")
        }

        let result = try run("scripts/build-app.sh")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath:
                    packageRoot
                    .appendingPathComponent("dist/VoxHalo.app/Contents/MacOS/VoxHalo")
                    .path
            ))

        let verification = try run("scripts/verify-app.sh", "dist/VoxHalo.app")
        XCTAssertEqual(verification.status, 0, verification.output)
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func propertyList(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any])
    }

    private func swiftSourceText(in relativeDirectory: String) throws -> String {
        let directory = packageRoot.appendingPathComponent(relativeDirectory)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        var result = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result += try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    private func run(_ arguments: String...) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        process.currentDirectoryURL = packageRoot
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output =
            String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        return (process.terminationStatus, output)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
