import AVFAudio
import AudioToolbox
import Foundation

public final class PCM16MonoConverter: @unchecked Sendable {
    public let sourceFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter
    private var reusableOutput: AVAudioPCMBuffer?

    public init(sourceFormat: AVAudioFormat) throws {
        guard sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: VoxBridgePCMFormat.sampleRate,
                  channels: VoxBridgePCMFormat.channelCount,
                  interleaved: false
              ),
              let converter = AVAudioConverter(
                  from: sourceFormat,
                  to: outputFormat
              ) else {
            throw AudioCaptureFailure.unsupportedFormat
        }
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.converter = converter
        converter.primeMethod = .none
        converter.downmix = true
        converter.sampleRateConverterQuality = Int(kAudioConverterQuality_Max)
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.format == sourceFormat else {
            throw AudioCaptureFailure.unsupportedFormat
        }
        guard input.frameLength > 0 else { return Data() }

        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let estimatedFrames = max(
            256,
            Int(ceil(Double(input.frameLength) * ratio)) + 64
        )
        let output = try outputBuffer(capacity: AVAudioFrameCount(estimatedFrames))
        output.frameLength = 0

        let provider = ConverterInputProvider(input)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            provider.next(status: inputStatus)
        }

        guard conversionError == nil, status != .error,
              let channel = output.floatChannelData?[0] else {
            throw AudioCaptureFailure.unsupportedFormat
        }

        let sampleCount = Int(output.frameLength)
        var pcm = Data(count: sampleCount * MemoryLayout<Int16>.size)
        pcm.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            for index in 0 ..< sampleCount {
                let value = Self.quantize(channel[index])
                let bits = UInt16(bitPattern: value.littleEndian)
                bytes[index * 2] = UInt8(bits & 0xFF)
                bytes[index * 2 + 1] = UInt8(bits >> 8)
            }
        }
        return pcm
    }

    private func outputBuffer(
        capacity: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        if let reusableOutput, reusableOutput.frameCapacity >= capacity {
            return reusableOutput
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw AudioCaptureFailure.unsupportedFormat
        }
        reusableOutput = buffer
        return buffer
    }

    private static func quantize(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        let clipped = min(max(sample, -1), 1)
        if clipped >= 0 {
            return Int16((clipped * Float(Int16.max)).rounded())
        }
        return Int16((clipped * 32_768).rounded())
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private let lock = NSLock()
    private var wasSupplied = false

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if wasSupplied {
            status.pointee = .noDataNow
            return nil
        }
        wasSupplied = true
        status.pointee = .haveData
        return input
    }
}
