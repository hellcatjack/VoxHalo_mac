import Foundation
import AVFoundation

@main struct AudioCaptureChecks {
    static func samples(_ blocks: [Data]) -> [Int16] {
        blocks.flatMap { data in stride(from: 0, to: data.count, by: 2).map { index in
            Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
        } }
    }
    static func encode(_ channels: [[Float]], rate: Double, splits: [Int]) throws -> [Data] {
        let encoder = try PCM16Encoder(sampleRate: rate)
        var result: [Data] = []
        var offset = 0
        for count in splits {
            result += try encoder.append(channels: channels.map { Array($0[offset..<offset + count]) })
            offset += count
        }
        result += try encoder.finish()
        return result
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--devices") {
            for item in try AudioDevices.inputs() { print("INPUT \(item.uid): \(item.name)") }
            for item in try AudioDevices.outputs() { print("OUTPUT \(item.uid): \(item.name)") }
            print("Default input: \(AudioDevices.defaultInputUID() ?? "none")")
            print("Default output: \(AudioDevices.defaultOutputUID() ?? "none")")
            return
        }
        let oneSecond = try encode([Array(repeating: 0.25, count: 48000)], rate: 48000, splits: [48000])
        precondition(oneSecond.count == 10 && oneSecond.allSatisfy { $0.count == 3200 }, "48k →16k duration and blocks")
        let stereo = samples(try encode([Array(repeating: 0.75, count: 1600), Array(repeating: -0.25, count: 1600)], rate: 16000, splits: [1600]))
        precondition(stereo.count == 1600 && stereo.allSatisfy { abs(Int($0) - 8192) <= 1 }, "stereo averaging")
        let clipped = samples(try encode([[2, -2, 0, 0.5, -0.5]], rate: 16000, splits: [2, 3]))
        precondition(clipped == [32767, -32768, 0, 16384, -16384], "clipping and final partial block")
        let waveform = (0..<48013).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.6 }
        let whole = samples(try encode([waveform], rate: 48000, splits: [48013]))
        let split = samples(try encode([waveform], rate: 48000, splits: [1, 127, 4096, 73, 8192, 35524]))
        precondition(whole.count == split.count && abs(whole.count - 16004) <= 1, "partial duration")
        precondition(zip(whole, split).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "conversion state across callbacks")
        try checkRateDurations()
        try await checkQueue()
        try await checkCopiedOrder()
        print("PASS: exact duration/blocks, stereo averaging, clipping, final partial, split-callback conversion, bounded queue, and stop drain")
    }
}

private final class AudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var failures = 0
    private var first = true
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func pcm(_ data: Data) {
        lock.lock(); bytes += data.count; let shouldWait = first; first = false; lock.unlock()
        if shouldWait { entered.signal(); release.wait() }
    }
    func failed() { lock.lock(); failures += 1; lock.unlock() }
    func snapshot() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (bytes, failures) }
}

extension AudioCaptureChecks {
    static func checkQueue() async throws {
        let probe = AudioProbe()
        let run = AudioCaptureRun(pcm: { probe.pcm($0) }, level: { _ in }, failure: { _ in probe.failed() })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        buffer.frameLength = 8192
        buffer.floatChannelData![0].initialize(repeating: 0.2, count: 8192)
        run.submit(buffer)
        precondition(probe.entered.wait(timeout: .now() + 5) == .success, "PCM callback delivered off submit path")
        for _ in 0..<9 { run.submit(buffer) }
        precondition(probe.snapshot().1 == 1, "overflow reports once")
        probe.release.signal()
        await run.finish()
        precondition(probe.snapshot().0 == 8 * 8192 * 2, "bounded queue drains all eight accepted buffers")
        run.submit(buffer)
        await run.finish()
        precondition(probe.snapshot().0 == 8 * 8192 * 2, "stopped queue rejects late callbacks and finish is idempotent")
        let empty = try PCM16Encoder(sampleRate: 48000)
        let emptyBlocks = try empty.finish()
        precondition(emptyBlocks.isEmpty, "empty finish")
    }
}

extension AudioCaptureChecks {
    static func checkRateDurations() throws {
        for rate in [16000.0, 44100.0, 48000.0, 96000.0] {
            for count in [1, 2, 3, 7, 100, 480, 1600, 48013] {
                let encoder = try PCM16Encoder(sampleRate: rate)
                var frames = 0
                for _ in 0..<count {
                    frames += try encoder.append(channels: [[0.2]]).reduce(0) { $0 + $1.count / 2 }
                }
                frames += try encoder.finish().reduce(0) { $0 + $1.count / 2 }
                precondition(frames == Int((Double(count) * 16000 / rate).rounded(.down)), "single-frame callbacks at \(rate) Hz, input count \(count)")
            }
        }
    }
}

private final class AudioSequenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ block: Data) { lock.lock(); data.append(block); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

extension AudioCaptureChecks {
    static func checkCopiedOrder() async throws {
        let probe = AudioSequenceProbe()
        let run = AudioCaptureRun(pcm: { probe.append($0) }, level: { _ in }, failure: { message in preconditionFailure(message) })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 1600)
        run.submit(buffer)
        buffer.floatChannelData![0].update(repeating: 0.5, count: 1600)
        run.submit(buffer)
        buffer.floatChannelData![0].update(repeating: -1, count: 1600)
        await run.finish()
        let output = samples([probe.snapshot()])
        precondition(output.count == 3200, "ordered copied duration")
        precondition(output.prefix(1600).allSatisfy { $0 == 8192 } && output.suffix(1600).allSatisfy { $0 == 16384 }, "input buffers are copied and delivered in order")
    }
}
