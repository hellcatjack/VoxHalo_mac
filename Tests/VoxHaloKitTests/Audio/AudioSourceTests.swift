import XCTest
@testable import VoxHaloKit

final class AudioSourceTests: XCTestCase {
    func testSystemAudioIdentityMatchesWindowsSelectionContract() {
        XCTAssertEqual(AudioSource.systemAudio.id, "system-default-loopback")
        XCTAssertEqual(AudioSource.systemAudio.name, "System Audio")
        XCTAssertEqual(AudioSource.systemAudio.kind, .systemAudio)
    }

    func testPreferredSelectionUsesSavedUIDOrFallsBackToSystemAudio() {
        let microphone = AudioSource(id: "mic-uid", name: "USB Mic", kind: .hardwareInput)
        let sources = [.systemAudio, microphone]

        XCTAssertEqual(
            AudioSourceSelection.preferred(from: sources, savedID: "mic-uid"),
            microphone
        )
        XCTAssertEqual(
            AudioSourceSelection.preferred(from: sources, savedID: "missing"),
            .systemAudio
        )
        XCTAssertEqual(
            AudioSourceSelection.preferred(from: sources, savedID: nil),
            .systemAudio
        )
    }

    func testPreferredSelectionUsesFirstAvailableWhenSyntheticSourceIsAbsent() {
        let microphone = AudioSource(id: "mic", name: "Mic", kind: .hardwareInput)

        XCTAssertEqual(
            AudioSourceSelection.preferred(from: [microphone], savedID: nil),
            microphone
        )
        XCTAssertNil(AudioSourceSelection.preferred(from: [], savedID: nil))
    }
}
