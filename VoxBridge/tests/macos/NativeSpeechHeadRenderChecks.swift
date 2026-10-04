import Foundation
import AVFoundation
import Darwin

/// Default mode uses manual/offline rendering and cannot reach a speaker.
/// --realtime explicitly enables native output. It uses synthetic PCM only:
/// no service, microphone, ASR, translation, or TTS producer is started.
@main struct NativeSpeechHeadRenderChecks {
    private final class Capture: @unchecked Sendable {
        struct Packet {
            let samples: [Float]
            let rate: Double
            let host: UInt64?
            let sample: Int64?
            let callbackHost: UInt64
        }
        private let lock = NSLock()
        private var values: [Packet] = []

        func append(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
            guard let data = buffer.floatChannelData else { return }
            // Copy on the audio callback; all analysis and JSON work happens
            // after the engine has stopped. Include the louder output channel.
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            var samples = [Float](repeating: 0, count: frames)
            for channel in 0..<channels {
                for frame in 0..<frames where abs(data[channel][frame]) > abs(samples[frame]) {
                    samples[frame] = data[channel][frame]
                }
            }
            let packet = Packet(samples: samples, rate: buffer.format.sampleRate,
                host: time.isHostTimeValid ? time.hostTime : nil,
                sample: time.isSampleTimeValid ? time.sampleTime : nil,
                callbackHost: mach_absolute_time())
            lock.lock(); values.append(packet); lock.unlock()
        }

        func snapshot() -> [Packet] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }

    private static let inputRate = 24_000.0
    private static let markerSeconds = 0.15
    private static let speechSeconds = 0.45

    private static func pcm(marker: Bool, silence: Bool = false) -> Data {
        let frames = Int(inputRate * speechSeconds)
        var data = Data(capacity: frames * 2)
        for i in 0..<frames {
            let amplitude = silence ? 0.0 : (marker && i < Int(inputRate * markerSeconds) ? 0.5 : 0.075)
            let frequency = marker && i < Int(inputRate * markerSeconds) ? 997.0 : 223.0
            let value = Int16((amplitude * sin(2 * .pi * frequency * Double(i) / inputRate) * 32767).rounded())
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    private static func snapshot(_ first: Int, count: Int = 1, silence: Bool = false) -> NativeSpeechSnapshot {
        NativeSpeechSnapshot(epoch: "head-render-probe", cursor: first + count - 1,
            chunks: (first..<(first + count)).map { seq in
                let bytes = pcm(marker: true, silence: silence)
                return NativeSpeechChunk(seq: seq, sentence_id: "probe-\(seq)", revision: 1,
                    source_order: seq, index: 0, count: 1, sample_rate: 24000,
                    pcm: bytes, duration_ms: Double(bytes.count) / 48,
                    text: "Head marker \(seq).", sentence_text: "Head marker \(seq).", created_at_ms: 0)
            })
    }

    private static func render(_ engine: AVAudioEngine, frames: Int) throws -> [Float] {
        let format = engine.manualRenderingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var result: [Float] = []
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(512, remaining))
            let status = try engine.renderOffline(count, to: buffer)
            guard status == .success else { throw ServiceError.message("Offline render status: \(status.rawValue)") }
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(count)))
            remaining -= Int(count)
        }
        return result
    }

    @MainActor private static func offlineCase(delta: Int64) throws -> [String: Any] {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        let input = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: input)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
        try engine.start()
        defer { node.stop(); engine.stop() }
        let silence = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 24_000)!
        silence.frameLength = 24_000
        for i in 0..<24_000 { silence.floatChannelData![0][i] = 0 }
        node.scheduleBuffer(silence, at: AVAudioTime(sampleTime: 0, atRate: inputRate))
        node.play()
        // Offline rendering can outrun the player's internal command queue in
        // an optimized tight loop. Let commands settle without moving its
        // sample timeline; this wait cannot produce device output.
        Thread.sleep(forTimeInterval: 0.01)
        _ = try render(engine, frames: 48_000)
        let nodeTime = node.lastRenderTime!
        let playerTime = node.playerTime(forNodeTime: nodeTime)!
        let start = playerTime.sampleTime + delta
        let marker = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 24_000)!
        marker.frameLength = 24_000
        // DC makes the offline prefix's sample conservation unambiguous. This
        // buffer is never used in realtime mode or sent to a device.
        for i in 0..<24_000 { marker.floatChannelData![0][i] = i < 2400 ? 0.8 : 0.2 }
        node.scheduleBuffer(marker, at: AVAudioTime(sampleTime: start, atRate: inputRate))
        Thread.sleep(forTimeInterval: 0.01)
        let rendered = try render(engine, frames: 48_000)
        let highFrames = rendered.filter { $0 > 0.5 }.count
        if delta >= 480, highFrames < 4700 {
            throw ServiceError.message("future marker lost its prefix: delta=\(delta), highFrames=\(highFrames)")
        }
        if delta <= -2400, highFrames >= 20 {
            throw ServiceError.message("past schedule unexpectedly preserved prefix: delta=\(delta), highFrames=\(highFrames)")
        }
        return ["delta_frames": delta, "chosen_player_frame": playerTime.sampleTime,
                "player_sample_rate": playerTime.sampleRate, "node_sample_rate": nodeTime.sampleRate,
                "start_frame": start, "high_prefix_frames": highFrames,
                "expected_high_prefix_frames": 4800,
                "prefix_ratio": Double(highFrames) / 4800,
                "first_nonzero_output_frame": rendered.firstIndex { abs($0) > 0.05 } ?? -1]
    }

    private static func probeJSON(_ probe: NativeSpeechScheduleProbe) -> [String: Any] {
        func clockJSON(_ clock: NativeSpeechRenderProbe) -> [String: Any] {
            ["observed_host_time": clock.observedHostTime,
             "render_host_time": clock.renderHostTime as Any? ?? NSNull(),
             "player_frame": clock.playerFrame as Any? ?? NSNull(),
             "player_sample_rate": clock.playerSampleRate as Any? ?? NSNull(),
             "render_age_ms": clock.renderAgeMilliseconds as Any? ?? NSNull()]
        }
        var value: [String: Any] = ["seq": probe.sequence, "start_frame": probe.startFrame,
            "end_frame": probe.endFrame, "was_playing": probe.playing,
            "chosen_clock": clockJSON(probe.chosen), "submitting_clock": clockJSON(probe.submitting),
            "submitted_host_time": probe.submittedHostTime,
            "presentation_latency_ms": probe.presentationLatency * 1000,
            "choose_to_submit_ms": AVAudioTime.seconds(forHostTime:
                probe.submittedHostTime - probe.chosen.observedHostTime) * 1000]
        if let frame = probe.submitting.playerFrame, let rate = probe.submitting.playerSampleRate,
           let age = probe.submitting.renderAgeMilliseconds {
            value["declared_margin_ms"] = Double(probe.startFrame - frame) / rate * 1000
            value["estimated_fresh_margin_ms"] = Double(probe.startFrame - frame) / rate * 1000 - age
        }
        return value
    }

    private static func expectedStartSeconds(_ probe: NativeSpeechScheduleProbe) -> Double? {
        guard let host = probe.chosen.renderHostTime, let frame = probe.chosen.playerFrame,
              let rate = probe.chosen.playerSampleRate, rate > 0 else { return nil }
        return AVAudioTime.seconds(forHostTime: host) + Double(probe.startFrame - frame) / rate
    }

    private static func markerMeasurements(_ packets: [Capture.Packet], probes: [NativeSpeechScheduleProbe]) -> [[String: Any]] {
        let peak = packets.reduce(Float(0)) { max($0, $1.samples.map { abs($0) }.max() ?? 0) }
        let threshold = peak * 0.5
        return probes.filter { $0.sequence > 1 }.map { probe in
            var result = probeJSON(probe)
            guard let target = expectedStartSeconds(probe) else {
                result["marker_error"] = "render clock has no host/sample anchor"; return result
            }
            var highSeconds = 0.0
            var firstHigh: Double?
            var lastHigh: Double?
            for packet in packets {
                guard let host = packet.host else { continue }
                let start = AVAudioTime.seconds(forHostTime: host)
                let end = start + Double(packet.samples.count) / packet.rate
                if end < target - 0.12 || start > target + 0.30 { continue }
                for (index, sample) in packet.samples.enumerated() {
                    let time = start + Double(index) / packet.rate
                    if time >= target - 0.12 && time < target + 0.30 && abs(sample) > threshold {
                        highSeconds += 1 / packet.rate
                        firstHigh = firstHigh.map { min($0, time) } ?? time
                        lastHigh = lastHigh.map { max($0, time) } ?? time
                    }
                }
            }
            // A sinusoidal head exceeds half its peak for two thirds of its
            // samples. Mixer gain therefore does not change this ratio.
            result["marker_ratio"] = highSeconds / (markerSeconds * 2 / 3)
            result["marker_peak"] = peak
            result["marker_threshold"] = threshold
            result["first_marker_offset_ms"] = firstHigh.map { ($0 - target) * 1000 } as Any? ?? NSNull()
            result["last_marker_offset_ms"] = lastHigh.map { ($0 - target) * 1000 } as Any? ?? NSNull()
            return result
        }
    }

    @MainActor private static func realtime(artifacts: URL?) async throws -> [String: Any] {
        let capture = Capture()
        let output = NativeSpeechOutputProbe()
        let player = NativeSpeechPlayer()
        var probes: [NativeSpeechScheduleProbe] = []
        var failures: [String] = []
        var device: [String: Any] = [:]
        var actorStalls: [[String: Any]] = []
        player.onMixerOutput = { buffer, time in capture.append(buffer, time); output.observeMixer(buffer, time) }
        player.onScheduleProbe = { probes.append($0); output.observeSchedule($0) }
        player.onPCMChunk = { output.observePCM($0) }
        player.onFailure = { failures.append($0) }
        defer { player.stop() }
        do {
            try player.start(outputUID: "default", epoch: "head-render-probe", cursor: 0)
            try await Task.sleep(nanoseconds: 250_000_000)
            device = player.outputDeviceProbe
            try player.accept(snapshot(1, silence: true))
            try await Task.sleep(nanoseconds: 800_000_000)
            // Native starvation resumes: only the production start policy
            // chooses anchors. No observer intervenes before enqueueing.
            for seq in 2...9 {
                try player.accept(snapshot(seq))
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            // Fully queued short sentences keep exact contiguous boundaries.
            try player.accept(snapshot(10, count: 4))
            try await Task.sleep(nanoseconds: 2_000_000_000)
            // Stress after enqueueing can delay UI observations but cannot
            // alter the already submitted PCM target.
            for seq in 14...19 {
                try player.accept(snapshot(seq))
                let began = mach_absolute_time()
                let until = ProcessInfo.processInfo.systemUptime + 0.080
                var work = 0.0
                while ProcessInfo.processInfo.systemUptime < until { work += sqrt(Double(Int(work) % 1000 + 1)) }
                actorStalls.append(["seq": seq, "duration_ms": AVAudioTime.seconds(forHostTime:
                    mach_absolute_time() - began) * 1000, "checksum": work])
                try await Task.sleep(nanoseconds: 620_000_000)
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        } catch { failures.append(error.localizedDescription) }
        let played = player.playedSequence
        let drained = player.drained
        player.stop()
        let packets = capture.snapshot()
        let measurements = markerMeasurements(packets, probes: probes)
        let contiguous = probes.filter { (10...13).contains($0.sequence) }
        let exact = contiguous.count == 4 && zip(contiguous, contiguous.dropFirst()).allSatisfy { $0.endFrame == $1.startFrame }
        let pcmReport = try artifacts.map { try output.writeArtifacts(to: $0) } ?? output.report()
        return ["mode": "native-realtime", "probe_only": true,
            "marker_measurement_scope": "mainMixerNode tap, before output device/DAC; synthetic marker, not phonetic word alignment",
            "output_device": device, "played_sequence": played, "drained": drained,
            "fully_queued_boundaries_exact": exact, "pcm_output_comparison": pcmReport,
            "failures": failures, "schedule_probes": probes.map(probeJSON),
            "marker_measurements": measurements, "main_actor_stalls": actorStalls,
            "tap_packets": packets.map { packet in
                ["rate": packet.rate, "frames": packet.samples.count,
                 "host_time": packet.host as Any? ?? NSNull(),
                 "sample_time": packet.sample as Any? ?? NSNull(),
                 "callback_host_time": packet.callbackHost] as [String: Any]
            }]
    }

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let path = args.firstIndex(of: "--output").flatMap { index in
            index + 1 < args.count ? URL(fileURLWithPath: args[index + 1]) : nil
        }
        let report: [String: Any]
        if args.contains("--realtime") {
            report = try await realtime(artifacts: path?.deletingLastPathComponent()
                .appendingPathComponent("synthetic-native-output", isDirectory: true))
        } else {
            report = ["mode": "offline-no-output", "probe_only": true,
                "cases": try [-12_000, -2400, 0, 480, 2400].map { try offlineCase(delta: $0) }]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path)
            print("Saved \(report["mode"]!) report: \(path.path)")
        } else { print(String(decoding: data, as: UTF8.self)) }
    }
}
