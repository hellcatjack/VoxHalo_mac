import Foundation
import AVFoundation

@main struct NativeSpeechOutputProbeChecks {
    private static func fixture(silentPrefix: Bool, narrowPeak: Bool) -> Data {
        var state: UInt32 = 0x1f123bb5
        var data = Data()
        for i in 0..<19_200 {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let time = Double(i) / 24_000
            // A speech-range chirp plus reproducible nonperiodic noise makes
            // delayed body correlation identifiable, unlike a single tone.
            let chirp = sin(2 * Double.pi * (183 * time + 700 * time * time))
            let noise = (Double(state & 0xffff) / 65_535 - 0.5) * (narrowPeak ? 0.45 : 0.06)
            let envelope = narrowPeak ? 0.015 : 0.19 + 0.04 * sin(2 * .pi * 7.3 * time)
            let value = silentPrefix && i < 2400 ? 0 : Int16(((envelope * chirp + noise) * 32_767).rounded())
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits)); data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    private static func converted(_ pcm: Data, rate: Double) throws -> AVAudioPCMBuffer {
        let from = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let to = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(pcm.count / 2))!
        input.frameLength = input.frameCapacity
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<Int(input.frameLength) {
                input.floatChannelData![0][i] = Float(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8)) / 32_768
            }
        }
        let converter = AVAudioConverter(from: from, to: to)!
        converter.primeMethod = .none
        let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(rate * 0.8) + 1024)!
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return output
    }

    private static func measurement(rate: Double, lostPrefix: Double = 0, silentPrefix: Bool = false,
                                    gain: Float = 0.72, delayMilliseconds: Double = 2,
                                    narrowPeak: Bool = false) throws -> [String: Any] {
        let collector = NativeSpeechOutputProbe(), pcm = fixture(silentPrefix: silentPrefix, narrowPeak: narrowPeak)
        let converted = try converted(pcm, rate: rate)
        let format = converted.format
        let delay = Int(rate * delayMilliseconds / 1000)
        let mixer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: converted.frameLength + AVAudioFrameCount(delay + 2048))!
        mixer.frameLength = mixer.frameCapacity
        for i in 0..<Int(mixer.frameLength) { mixer.floatChannelData![0][i] = 0 }
        for i in 0..<Int(converted.frameLength) where i >= Int(rate * lostPrefix) {
            mixer.floatChannelData![0][i + delay] = converted.floatChannelData![0][i] * gain
        }
        let host = AVAudioTime.hostTime(forSeconds: 10)
        let clock = NativeSpeechRenderProbe(observedHostTime: AVAudioTime.hostTime(forSeconds: 9.98),
            renderHostTime: host, playerFrame: 0, playerSampleRate: 24_000)
        precondition(abs(clock.renderAgeMilliseconds! + 20) < 0.001)
        collector.observeSchedule(NativeSpeechScheduleProbe(sequence: 1, startFrame: 0, endFrame: 19_200,
            playing: true, chosen: clock, submitting: clock, submittedHostTime: clock.observedHostTime,
            presentationLatency: 0))
        collector.observePCM(NativeSpeechChunk(seq: 1, sentence_id: "chirp", revision: 1, source_order: 1,
            index: 0, count: 1, sample_rate: 24_000, pcm: pcm, duration_ms: 800,
            text: "A unique phonetic-range chirp.", sentence_text: nil, created_at_ms: 0))
        collector.observeMixer(mixer, AVAudioTime(hostTime: host, sampleTime: 0, atRate: rate))
        return (try collector.report()["head_comparisons"] as! [[String: Any]])[0]
    }

    static func main() throws {
        for rate in [44_100.0, 48_000.0] {
            let intact = try measurement(rate: rate)
            precondition(intact["comparison_confident"] as? Bool == true)
            precondition((intact["head_correlation"] as! Double) > 0.99)
            precondition(abs((intact["head_energy_ratio"] as! Double) - 1) < 0.02)
            precondition((intact["head_voiced_low_energy_ms"] as! Double) == 0)
            precondition(abs((intact["alignment_offset_ms"] as! Double) - 2) < 0.05)
            let missing = try measurement(rate: rate, lostPrefix: 0.1)
            precondition(missing["comparison_confident"] as? Bool == true)
            precondition((missing["body_correlation"] as! Double) > 0.99)
            precondition((missing["head_voiced_low_energy_ms"] as! Double) >= 80)
            precondition((missing["head_energy_ratio"] as! Double) < 0.8)
            let silence = try measurement(rate: rate, silentPrefix: true)
            precondition(silence["comparison_confident"] as? Bool == true)
            precondition((silence["head_voiced_low_energy_ms"] as! Double) == 0)
            let narrow = try measurement(rate: rate, delayMilliseconds: 2.23, narrowPeak: true)
            precondition(narrow["exhaustive_body_search"] as? Bool == true,
                         "An off-grid narrow nonperiodic peak must invoke exhaustive fallback")
            precondition(narrow["comparison_confident"] as? Bool == true)
            precondition((narrow["body_correlation"] as! Double) > 0.99)
            precondition((narrow["head_correlation"] as! Double) > 0.99)
            precondition(abs((narrow["head_energy_ratio"] as! Double) - 1) < 0.02)
            precondition((narrow["head_voiced_low_energy_ms"] as! Double) == 0)
            precondition(abs((narrow["alignment_offset_ms"] as! Double) - Double(Int(rate * 0.00223)) / rate * 1000) < 0.05)
        }
        print("NativeSpeechOutputProbeChecks passed: nonperiodic voice-range chirp, 24→44.1/48 kHz SRC, gain/delay calibration, preserved head, 100ms missing head, natural silent prefix and signed future render age")
    }
}
