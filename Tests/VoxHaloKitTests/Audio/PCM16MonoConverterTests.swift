import AVFAudio
import AudioToolbox
import XCTest
@testable import VoxHaloKit

final class PCM16MonoConverterTests: XCTestCase {
    func testFloatStereoDownmixAndLittleEndianPCM() throws {
        let buffer = try makeFloatBuffer(
            sampleRate: 16_000,
            channels: [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5]],
            interleaved: false
        )

        let pcm = try PCM16MonoConverter(sourceFormat: buffer.format).convert(buffer)

        for sample in samples(in: pcm) {
            XCTAssertEqual(sample, 16_384, accuracy: 2)
        }
        XCTAssertEqual(Array(pcm.prefix(2)), [0xFF, 0x3F])
    }

    func testInterleavedFloatChannelsAverageAndOppositesCancel() throws {
        let averaged = try makeFloatBuffer(
            sampleRate: 16_000,
            channels: [[1, 0.5], [0, 0.5]],
            interleaved: true
        )
        let cancelled = try makeFloatBuffer(
            sampleRate: 16_000,
            channels: [[1, -0.75], [-1, 0.75]],
            interleaved: true
        )

        let averagedSamples = samples(in:
            try PCM16MonoConverter(sourceFormat: averaged.format).convert(averaged))
        for sample in averagedSamples {
            XCTAssertEqual(sample, 16_384, accuracy: 2)
        }
        XCTAssertEqual(
            samples(in: try PCM16MonoConverter(sourceFormat: cancelled.format).convert(cancelled)),
            [0, 0]
        )
    }

    func testInt16AndInt32InputFormatsConvertToSamePCMScale() throws {
        let int16 = try makeIntegerBuffer(
            format: .pcmFormatInt16,
            values: [[16_384, -16_384]],
            interleaved: false
        )
        let int32 = try makeIntegerBuffer(
            format: .pcmFormatInt32,
            values: [[1_073_741_824, -1_073_741_824]],
            interleaved: true
        )

        XCTAssertEqual(
            samples(in: try PCM16MonoConverter(sourceFormat: int16.format).convert(int16)),
            [16_384, -16_384]
        )
        XCTAssertEqual(
            samples(in: try PCM16MonoConverter(sourceFormat: int32.format).convert(int32)),
            [16_384, -16_384]
        )
    }

    func testPackedInt24InputIsSupported() throws {
        let buffer = try makePackedInt24Buffer(values: [4_194_304, -4_194_304])

        let pcm = try PCM16MonoConverter(sourceFormat: buffer.format).convert(buffer)

        XCTAssertEqual(samples(in: pcm), [16_384, -16_384])
    }

    func testClippingNaNAndInfinityAreSafeAndSymmetric() throws {
        let buffer = try makeFloatBuffer(
            sampleRate: 16_000,
            channels: [[2, -2, .nan, .infinity, -.infinity]],
            interleaved: false
        )

        let pcm = try PCM16MonoConverter(sourceFormat: buffer.format).convert(buffer)

        XCTAssertEqual(samples(in: pcm), [32_767, -32_768, 0, 0, 0])
    }

    func testStatefulResamplingKeepsAccurateSampleCountsAcrossIrregularChunks() throws {
        for sourceRate in [44_100.0, 48_000.0] {
            let lengths = irregularLengths(total: Int(sourceRate))
            let first = try makeFloatBuffer(
                sampleRate: sourceRate,
                channels: [Array(repeating: 0.25, count: lengths[0])],
                interleaved: false
            )
            let converter = try PCM16MonoConverter(sourceFormat: first.format)
            var outputSamples = try converter.convert(first).count / 2

            for length in lengths.dropFirst() {
                let buffer = try makeFloatBuffer(
                    sampleRate: sourceRate,
                    channels: [Array(repeating: 0.25, count: length)],
                    interleaved: false
                )
                outputSamples += try converter.convert(buffer).count / 2
            }

            XCTAssertEqual(outputSamples, 16_000, accuracy: 1, "\(sourceRate) Hz")
        }
    }

    func testConverterRejectsMismatchedCallbackFormat() throws {
        let source = try makeFloatBuffer(
            sampleRate: 48_000,
            channels: [[0, 0]],
            interleaved: false
        )
        let mismatched = try makeFloatBuffer(
            sampleRate: 44_100,
            channels: [[0, 0]],
            interleaved: false
        )
        let converter = try PCM16MonoConverter(sourceFormat: source.format)

        XCTAssertThrowsError(try converter.convert(mismatched)) { error in
            XCTAssertEqual(error as? AudioCaptureFailure, .unsupportedFormat)
        }
    }

    private func makeFloatBuffer(
        sampleRate: Double,
        channels: [[Float]],
        interleaved: Bool
    ) throws -> AVAudioPCMBuffer {
        let frameCount = try XCTUnwrap(channels.first?.count)
        XCTAssertTrue(channels.allSatisfy { $0.count == frameCount })
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: interleaved
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0 ..< frameCount {
            for channel in channels.indices {
                if interleaved {
                    data[0][frame * channels.count + channel] = channels[channel][frame]
                } else {
                    data[channel][frame] = channels[channel][frame]
                }
            }
        }
        return buffer
    }

    private func makeIntegerBuffer(
        format commonFormat: AVAudioCommonFormat,
        values: [[Int32]],
        interleaved: Bool
    ) throws -> AVAudioPCMBuffer {
        let frameCount = try XCTUnwrap(values.first?.count)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: 16_000,
            channels: AVAudioChannelCount(values.count),
            interleaved: interleaved
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0 ..< frameCount {
            for channel in values.indices {
                let index = interleaved ? frame * values.count + channel : frame
                if commonFormat == .pcmFormatInt16 {
                    try XCTUnwrap(buffer.int16ChannelData)[interleaved ? 0 : channel][index]
                        = Int16(values[channel][frame])
                } else {
                    try XCTUnwrap(buffer.int32ChannelData)[interleaved ? 0 : channel][index]
                        = values[channel][frame]
                }
            }
        }
        return buffer
    }

    private func makePackedInt24Buffer(values: [Int32]) throws -> AVAudioPCMBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: 3,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(values.count)
        ))
        buffer.frameLength = AVAudioFrameCount(values.count)
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        let bytes = try XCTUnwrap(audioBuffer.mData?.assumingMemoryBound(to: UInt8.self))
        for (index, value) in values.enumerated() {
            let bits = UInt32(bitPattern: value)
            bytes[index * 3] = UInt8(bits & 0xFF)
            bytes[index * 3 + 1] = UInt8((bits >> 8) & 0xFF)
            bytes[index * 3 + 2] = UInt8((bits >> 16) & 0xFF)
        }
        return buffer
    }

    private func samples(in data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            let bits = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            return Int16(bitPattern: bits)
        }
    }

    private func irregularLengths(total: Int) -> [Int] {
        let pattern = [137, 911, 2_047, 333, 4_096, 1_003]
        var remaining = total
        var result: [Int] = []
        var index = 0
        while remaining > 0 {
            let count = min(pattern[index % pattern.count], remaining)
            result.append(count)
            remaining -= count
            index += 1
        }
        return result
    }
}
