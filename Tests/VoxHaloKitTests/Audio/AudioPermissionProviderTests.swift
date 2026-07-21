import XCTest
@testable import VoxHaloKit

final class AudioPermissionProviderTests: XCTestCase {
    func testSystemAudioDoesNotPreflightMicrophonePermission() async throws {
        let client = FakeMicrophonePermissionClient(status: .denied)
        let provider = AudioPermissionProvider(microphone: client)

        try await provider.authorize(.systemAudio)

        let counts = await client.counts()
        XCTAssertEqual(counts.status, 0)
        XCTAssertEqual(counts.request, 0)
    }

    func testAuthorizedHardwareInputDoesNotPrompt() async throws {
        let client = FakeMicrophonePermissionClient(status: .authorized)
        let provider = AudioPermissionProvider(microphone: client)
        let source = AudioSource(id: "mic", name: "Mic", kind: .hardwareInput)

        try await provider.authorize(source)

        let counts = await client.counts()
        XCTAssertEqual(counts.status, 1)
        XCTAssertEqual(counts.request, 0)
    }

    func testDeniedAndRestrictedHardwareInputMapToPermissionFailure() async {
        for status in [MicrophonePermissionStatus.denied, .restricted] {
            let client = FakeMicrophonePermissionClient(status: status)
            let provider = AudioPermissionProvider(microphone: client)
            let source = AudioSource(id: "mic", name: "Mic", kind: .hardwareInput)

            do {
                try await provider.authorize(source)
                XCTFail("Expected denial for \(status)")
            } catch {
                XCTAssertEqual(error as? AudioCaptureFailure,
                               .microphonePermissionDenied)
            }
            let counts = await client.counts()
            XCTAssertEqual(counts.request, 0)
        }
    }

    func testNotDeterminedRequestsOnceAndMapsResult() async throws {
        let granted = FakeMicrophonePermissionClient(
            status: .notDetermined,
            requestResult: true
        )
        let source = AudioSource(id: "mic", name: "Mic", kind: .hardwareInput)
        try await AudioPermissionProvider(microphone: granted).authorize(source)
        let grantedCounts = await granted.counts()
        XCTAssertEqual(grantedCounts.request, 1)

        let denied = FakeMicrophonePermissionClient(
            status: .notDetermined,
            requestResult: false
        )
        do {
            try await AudioPermissionProvider(microphone: denied).authorize(source)
            XCTFail("Expected denied prompt")
        } catch {
            XCTAssertEqual(error as? AudioCaptureFailure, .microphonePermissionDenied)
        }
        let deniedCounts = await denied.counts()
        XCTAssertEqual(deniedCounts.request, 1)
    }
}
