import AVFAudio
import XCTest
@testable import VoxHaloKit

final class AUHALInputUnitTests: XCTestCase {
    func testPacketBecomesInterleavedPCMBufferWithoutChangingSourceFormat() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let samples: [Float] = [0.25, -0.25, 0.5, -0.5]
        let bytes = samples.withUnsafeBytes { Data($0) }
        let packet = RealtimeAudioPacket(
            bytes: bytes,
            frameCount: 2,
            callbackTimestamp: .init(nanosecondsSinceBoot: 99)
        )

        let captured = try AUHALInputUnit.makeCapturedAudio(
            packet: packet,
            format: format
        )

        XCTAssertEqual(captured.callbackTimestamp, packet.callbackTimestamp)
        XCTAssertEqual(captured.buffer.format, format)
        XCTAssertEqual(captured.buffer.frameLength, 2)
        let channel = try XCTUnwrap(captured.buffer.floatChannelData?[0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: 4)), samples)
    }

    func testPacketBecomesNoninterleavedPCMBufferInChannelOrder() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ))
        let left: [Float] = [0.1, 0.2, 0.3]
        let right: [Float] = [-0.1, -0.2, -0.3]
        let bytes = left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                Data(leftBytes) + Data(rightBytes)
            }
        }

        let captured = try AUHALInputUnit.makeCapturedAudio(
            packet: RealtimeAudioPacket(
                bytes: bytes,
                frameCount: 3,
                callbackTimestamp: .init(nanosecondsSinceBoot: 7)
            ),
            format: format
        )

        let channels = try XCTUnwrap(captured.buffer.floatChannelData)
        XCTAssertEqual(
            Array(UnsafeBufferPointer(start: channels[0], count: 3)),
            left
        )
        XCTAssertEqual(
            Array(UnsafeBufferPointer(start: channels[1], count: 3)),
            right
        )
    }

    func testMalformedPacketIsRejected() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let packet = RealtimeAudioPacket(
            bytes: Data(repeating: 0, count: 3),
            frameCount: 1,
            callbackTimestamp: .init(nanosecondsSinceBoot: 1)
        )

        XCTAssertThrowsError(try AUHALInputUnit.makeCapturedAudio(
            packet: packet,
            format: format
        )) { error in
            XCTAssertEqual(error as? AudioCaptureFailure, .unsupportedFormat)
        }
    }
}
