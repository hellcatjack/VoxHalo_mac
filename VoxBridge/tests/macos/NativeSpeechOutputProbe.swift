import Foundation
import AVFoundation
import Darwin
import Accelerate

/// Test-only native PCM versus the engine's software output. This does not
/// record the microphone, another app, a speaker, or the device/DAC pipeline.
/// Analysis and resampling run only after capture has stopped.
final class NativeSpeechOutputProbe: @unchecked Sendable {
    private struct TapPacket {
        let samples: [Float]
        let rate: Double
        let host: UInt64?
        let sample: Int64?
        let observedHost: UInt64
    }
    private struct Values {
        let referenceEnergy: Double
        let actualEnergy: Double
        let dot: Double
        var correlation: Double {
            let scale = sqrt(referenceEnergy * actualEnergy)
            return scale > 1e-20 ? dot / scale : 0
        }
        var gain: Double { referenceEnergy > 1e-20 ? dot / referenceEnergy : 0 }
    }

    private let lock = NSLock()
    private var chunks: [Int: NativeSpeechChunk] = [:]
    private var schedules: [Int: NativeSpeechScheduleProbe] = [:]
    private var packets: [TapPacket] = []

    func observePCM(_ chunk: NativeSpeechChunk) {
        lock.lock(); chunks[chunk.seq] = chunk; lock.unlock()
    }

    func observeSchedule(_ probe: NativeSpeechScheduleProbe) {
        lock.lock(); schedules[probe.sequence] = probe; lock.unlock()
    }

    func observeMixer(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let packet = TapPacket(samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            rate: buffer.format.sampleRate, host: time.isHostTimeValid ? time.hostTime : nil,
            sample: time.isSampleTimeValid ? time.sampleTime : nil, observedHost: mach_absolute_time())
        lock.lock(); packets.append(packet); lock.unlock()
    }

    private func snapshot() -> ([Int: NativeSpeechChunk], [Int: NativeSpeechScheduleProbe], [TapPacket]) {
        lock.lock(); defer { lock.unlock() }; return (chunks, schedules, packets)
    }

    private static func resample(_ pcm: Data, rate: Double) throws -> [Float] {
        let from = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let to = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = pcm.count / 2
        let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(frames))!
        input.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<frames {
                let word = UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8
                input.floatChannelData![0][i] = Float(Int16(bitPattern: word)) / 32768
            }
        }
        if rate == 24_000 { return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: frames)) }
        let converter = AVAudioConverter(from: from, to: to)!
        converter.primeMethod = .none
        let capacity = AVAudioFrameCount(ceil(Double(frames) * rate / 24_000)) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    private static func interpolated(_ samples: [Float], at position: Double) -> Double {
        let i = Int(floor(position))
        guard i >= 0, i + 1 < samples.count else { return 0 }
        let fraction = position - Double(i)
        return Double(samples[i]) * (1 - fraction) + Double(samples[i + 1]) * fraction
    }

    private static func compare(_ reference: [Float], _ actual: [Float], start: Double,
                                range: Range<Int>, stride step: Int = 1) -> Values {
        var expected = 0.0, observed = 0.0, dot = 0.0
        for i in stride(from: range.lowerBound, to: min(range.upperBound, reference.count), by: step) {
            let x = Double(reference[i]), y = interpolated(actual, at: start + Double(i))
            expected += x * x; observed += y * y; dot += x * y
        }
        return Values(referenceEnergy: expected, actualEnergy: observed, dot: dot)
    }

    /// A coarse time grid can entirely miss a narrow speech/noise correlation
    /// peak. Use every output sample over +/-120ms when coarse confidence fails.
    /// FFT convolution keeps this fallback bounded even for a one-second body.
    private static func exhaustiveBodyCorrelations(_ reference: [Float], _ actual: [Float],
                                                   start: Double, body: Range<Int>, search: Int) throws -> [Double] {
        let length = min(body.upperBound, reference.count) - body.lowerBound
        guard length > 0 else { return [] }
        let observedLength = length + search * 2
        var fftLength = 1, log2Length = vDSP_Length(0)
        while fftLength < length + observedLength - 1 { fftLength *= 2; log2Length += 1 }
        guard let setup = vDSP_create_fftsetupD(log2Length, FFTRadix(kFFTRadix2)) else {
            throw ServiceError.message("Unable to allocate test-only FFT correlation")
        }
        defer { vDSP_destroy_fftsetupD(setup) }
        var referenceReal = [Double](repeating: 0, count: fftLength)
        var referenceImaginary = [Double](repeating: 0, count: fftLength)
        var actualReal = [Double](repeating: 0, count: fftLength)
        var actualImaginary = [Double](repeating: 0, count: fftLength)
        var referenceEnergy = 0.0
        for i in 0..<length {
            let value = Double(reference[body.lowerBound + i])
            referenceReal[length - 1 - i] = value
            referenceEnergy += value * value
        }
        var cumulative = [Double](repeating: 0, count: observedLength + 1)
        for i in 0..<observedLength {
            let value = interpolated(actual, at: start + Double(body.lowerBound - search + i))
            actualReal[i] = value; cumulative[i + 1] = cumulative[i] + value * value
        }
        referenceReal.withUnsafeMutableBufferPointer { realX in
            referenceImaginary.withUnsafeMutableBufferPointer { imaginaryX in
                actualReal.withUnsafeMutableBufferPointer { realY in
                    actualImaginary.withUnsafeMutableBufferPointer { imaginaryY in
                        var x = DSPDoubleSplitComplex(realp: realX.baseAddress!, imagp: imaginaryX.baseAddress!)
                        var y = DSPDoubleSplitComplex(realp: realY.baseAddress!, imagp: imaginaryY.baseAddress!)
                        vDSP_fft_zipD(setup, &x, 1, log2Length, FFTDirection(FFT_FORWARD))
                        vDSP_fft_zipD(setup, &y, 1, log2Length, FFTDirection(FFT_FORWARD))
                        for i in 0..<fftLength {
                            let real = realY[i] * realX[i] - imaginaryY[i] * imaginaryX[i]
                            let imaginary = realY[i] * imaginaryX[i] + imaginaryY[i] * realX[i]
                            realY[i] = real; imaginaryY[i] = imaginary
                        }
                        vDSP_fft_zipD(setup, &y, 1, log2Length, FFTDirection(FFT_INVERSE))
                    }
                }
            }
        }
        return (0...(search * 2)).map { offset in
            let energy = max(0, cumulative[offset + length] - cumulative[offset])
            let scale = sqrt(referenceEnergy * energy)
            return scale > 1e-20 ? actualReal[offset + length - 1] / Double(fftLength) / scale : 0
        }
    }

    private static func hostAnchor(_ probe: NativeSpeechScheduleProbe) -> Double? {
        guard let host = probe.chosen.renderHostTime, let frame = probe.chosen.playerFrame,
              let rate = probe.chosen.playerSampleRate, rate > 0 else { return nil }
        return AVAudioTime.seconds(forHostTime: host) - Double(frame) / rate
    }

    private static func clockJSON(_ clock: NativeSpeechRenderProbe) -> [String: Any] {
        ["observed_host_time": clock.observedHostTime,
         "render_host_time": clock.renderHostTime as Any? ?? NSNull(),
         "player_frame": clock.playerFrame as Any? ?? NSNull(),
         "sample_rate": clock.playerSampleRate as Any? ?? NSNull(),
         "render_age_ms": clock.renderAgeMilliseconds as Any? ?? NSNull()]
    }

    private static func scheduleJSON(_ probe: NativeSpeechScheduleProbe) -> [String: Any] {
        var value: [String: Any] = ["seq": probe.sequence, "start_frame": probe.startFrame,
            "end_frame": probe.endFrame, "was_playing": probe.playing,
            "chosen_clock": clockJSON(probe.chosen), "submitting_clock": clockJSON(probe.submitting),
            "submitted_host_time": probe.submittedHostTime,
            "choose_to_submit_ms": AVAudioTime.seconds(forHostTime:
                probe.submittedHostTime - probe.chosen.observedHostTime) * 1000,
            "presentation_latency_ms": probe.presentationLatency * 1000]
        if let frame = probe.submitting.playerFrame, let rate = probe.submitting.playerSampleRate,
           rate > 0, let age = probe.submitting.renderAgeMilliseconds {
            value["declared_margin_ms"] = Double(probe.startFrame - frame) / rate * 1000
            value["estimated_fresh_margin_ms"] = Double(probe.startFrame - frame) / rate * 1000 - age
        }
        return value
    }

    private static func report(chunks: [Int: NativeSpeechChunk], schedules: [Int: NativeSpeechScheduleProbe],
                               packets: [TapPacket]) throws -> [String: Any] {
        var report: [String: Any] = ["scope": "accepted PCM versus mainMixerNode channel 0; before device/DAC, no phonetic word-alignment claim",
            "expected_resampling": "AVAudioConverter 24000 Hz mono to observed mixer rate, primeMethod none; body alignment removes converter phase delay",
            "schedule_probes": schedules.keys.sorted().compactMap { schedules[$0].map(scheduleJSON) },
            "tap_count": packets.count, "chunk_count": chunks.count,
            "tap_packets": packets.map { packet in
                ["sample_rate": packet.rate, "frames": packet.samples.count,
                 "host_time": packet.host as Any? ?? NSNull(), "sample_time": packet.sample as Any? ?? NSNull(),
                 "observed_host_time": packet.observedHost] as [String: Any]
            }]
        guard let first = packets.first(where: { $0.host != nil && $0.sample != nil }),
              let firstSample = first.sample, let firstHost = first.host else {
            report["error"] = "No mixer tap with a host/sample anchor"; return report
        }
        let rate = first.rate
        guard rate > 0, packets.allSatisfy({ $0.rate == rate }) else {
            report["error"] = "Mixer rate changed during recording"; return report
        }
        var observed: [Float] = []
        var anchors: [Double] = []
        for packet in packets {
            guard let sample = packet.sample, let host = packet.host else { continue }
            let index = Int(sample - firstSample)
            guard index >= 0, index < Int(rate * 1800) else { continue }
            let required = index + packet.samples.count
            if required > observed.count { observed.append(contentsOf: repeatElement(0, count: required - observed.count)) }
            observed.replaceSubrange(index..<required, with: packet.samples)
            anchors.append(AVAudioTime.seconds(forHostTime: host) - Double(sample) / rate)
        }
        anchors.sort()
        let mixerAnchor = anchors.isEmpty ? AVAudioTime.seconds(forHostTime: firstHost) - Double(firstSample) / rate : anchors[anchors.count / 2]
        let playerAnchors = schedules.values.compactMap(hostAnchor).sorted()
        guard !playerAnchors.isEmpty else { report["error"] = "No player host/sample anchor"; return report }
        let playerAnchor = playerAnchors[playerAnchors.count / 2]
        report["mixer_sample_rate"] = rate
        report["mixer_anchor_jitter_ms"] = (anchors.last! - anchors.first!) * 1000
        report["player_anchor_jitter_ms"] = (playerAnchors.last! - playerAnchors.first!) * 1000
        report["mixer_duration_seconds"] = Double(observed.count) / rate
        var results: [[String: Any]] = []
        for seq in chunks.keys.sorted() {
            guard let chunk = chunks[seq], let probe = schedules[seq] else { continue }
            var result = scheduleJSON(probe)
            result["sentence_id"] = chunk.sentence_id; result["index"] = chunk.index; result["count"] = chunk.count
            result["text"] = chunk.text; result["duration_ms"] = chunk.duration_ms
            let reference = try resample(chunk.pcm, rate: rate)
            let target = (hostAnchor(probe) ?? playerAnchor) + Double(probe.startFrame) / 24_000
            let start = (target - mixerAnchor) * rate - Double(firstSample)
            let length = reference.count
            if length < Int(rate * 0.020) { result["comparison_error"] = "Chunk shorter than 20 ms"; results.append(result); continue }
            let bodyLower = length > Int(rate * 0.45) ? Int(rate * 0.30) : length / 3
            let bodyUpper = min(length, Int(rate))
            let body = bodyLower..<max(bodyLower + 1, bodyUpper)
            let comparisonStride = max(1, Int(rate / 6000))
            var lag = 0, best = -Double.infinity, bestBody = -Double.infinity
            let headLength = min(length, Int(rate * 0.3))
            // Host/sample anchors already align the engine clocks. Prefer a
            // nearby SRC phase correction; search farther only when that body
            // match fails. A head tie-break resolves periodic body aliases.
            func consider(_ candidate: Int) {
                let value = compare(reference, observed, start: start + Double(candidate), range: body, stride: comparisonStride)
                let head = compare(reference, observed, start: start + Double(candidate), range: 0..<headLength, stride: comparisonStride)
                let score = value.correlation + 0.002 * head.correlation - abs(Double(candidate) / rate) * 0.00001
                if score > best { best = score; bestBody = value.correlation; lag = candidate }
            }
            let near = Int(rate * 0.012), coarse = max(1, Int(rate * 0.0005))
            for candidate in stride(from: -near, through: near, by: coarse) { consider(candidate) }
            if bestBody < 0.90 {
                let search = Int(rate * 0.12), broad = max(1, Int(rate * 0.005))
                for candidate in stride(from: -search, through: search, by: broad) { consider(candidate) }
            }
            let center = lag, fine = max(1, Int(rate / 48_000))
            for candidate in stride(from: center - coarse, through: center + coarse, by: fine) {
                consider(candidate)
            }
            let usedExhaustiveSearch = bestBody < 0.90
            if usedExhaustiveSearch {
                let search = Int(rate * 0.12)
                let correlations = try exhaustiveBodyCorrelations(reference, observed, start: start, body: body, search: search)
                if let maximum = correlations.max(), maximum > 0 {
                    // Only evaluate head ties near the best full-rate body peak.
                    // This also prevents periodic body aliases choosing a false
                    // head while retaining a high body confidence value.
                    best = -Double.infinity
                    for (index, correlation) in correlations.enumerated() where correlation >= maximum - 0.001 {
                        let candidate = index - search
                        let head = compare(reference, observed, start: start + Double(candidate),
                            range: 0..<headLength, stride: comparisonStride)
                        let score = correlation + 0.002 * head.correlation - abs(Double(candidate) / rate) * 0.00001
                        if score > best { best = score; lag = candidate; bestBody = correlation }
                    }
                }
            }
            let aligned = start + Double(lag)
            let bodyValues = compare(reference, observed, start: aligned, range: body)
            let gain = bodyValues.gain
            let head = compare(reference, observed, start: aligned, range: 0..<headLength)
            result["alignment_offset_ms"] = Double(lag) / rate * 1000
            result["exhaustive_body_search"] = usedExhaustiveSearch
            result["body_correlation"] = bodyValues.correlation
            result["body_gain"] = gain
            result["head_correlation"] = head.correlation
            result["head_reference_rms"] = sqrt(head.referenceEnergy / Double(headLength))
            result["head_duration_ms"] = Double(headLength) / rate * 1000
            let normalization = head.referenceEnergy * gain * gain
            result["head_energy_ratio"] = normalization > 1e-20 ? head.actualEnergy / normalization : NSNull()
            let window = max(1, Int(rate * 0.020))
            var windows: [[String: Any]] = []
            var lowEnergy = 0.0
            for lo in stride(from: 0, to: headLength, by: window) {
                let hi = min(headLength, lo + window)
                let values = compare(reference, observed, start: aligned, range: lo..<hi)
                let denominator = values.referenceEnergy * gain * gain
                let ratio = denominator > 1e-20 ? values.actualEnergy / denominator : nil
                let referenceRMS = sqrt(values.referenceEnergy / Double(hi - lo))
                if referenceRMS > 0.001, let ratio, ratio < 0.10 {
                    lowEnergy += Double(hi - lo) / rate * 1000
                }
                windows.append(["start_ms": Double(lo) / rate * 1000,
                    "end_ms": Double(hi) / rate * 1000, "reference_rms": referenceRMS,
                    "correlation": values.correlation, "energy_ratio": ratio as Any? ?? NSNull()])
            }
            result["head_voiced_low_energy_ms"] = lowEnergy
            result["head_windows"] = windows
            result["comparison_confident"] = bodyValues.correlation >= 0.90 && gain > 0.05 && gain < 4
            results.append(result)
        }
        report["head_comparisons"] = results
        return report
    }

    func report() throws -> [String: Any] {
        let (chunks, schedules, packets) = snapshot()
        return try Self.report(chunks: chunks, schedules: schedules, packets: packets)
    }

    /// Called only after the player's stop/drain. Saves the original English
    /// PCM as well as the tap for independent reanalysis of ambiguous heads.
    func writeArtifacts(to directory: URL) throws -> [String: Any] {
        let (chunks, schedules, packets) = snapshot()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = directory.appendingPathComponent("accepted-pcm", isDirectory: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        for seq in chunks.keys.sorted() {
            try chunks[seq]!.pcm.write(to: expected.appendingPathComponent(String(format: "seq-%05d.pcm16le", seq)))
        }
        var mixer = Data()
        for packet in packets { packet.samples.withUnsafeBytes { mixer.append(contentsOf: $0) } }
        try mixer.write(to: directory.appendingPathComponent("main-mixer-channel0.float32le"))
        var result = try Self.report(chunks: chunks, schedules: schedules, packets: packets)
        result["accepted_pcm_directory"] = expected.path
        result["mixer_pcm_path"] = directory.appendingPathComponent("main-mixer-channel0.float32le").path
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("native-output-report.json"))
        return result
    }
}
