import Foundation
import AVFoundation

@main struct NativeSpeechPlayerChecks {
    @MainActor static func main() async throws {
        assert(NativeSpeechSchedule.start(previousEnd: 1000, rendered: 900, playing: true) == 1000)
        assert(NativeSpeechSchedule.start(previousEnd: 1000, rendered: 1100, playing: true) == 1580)
        func packet(_ seq: Int, index: Int = 0, count: Int = 1, order: Int = 0,
                    epoch: String = "epoch-a", pcm: Data = Data(repeating: 0, count: 4800)) throws -> NativeSpeechSnapshot {
            let value: [String: Any] = ["epoch": epoch, "cursor": seq, "chunks": [[
                "seq": seq, "sentence_id": "s\(order)", "revision": 1, "source_order": order,
                "index": index, "count": count, "sample_rate": 24000,
                "pcm": pcm.base64EncodedString(), "duration_ms": Double(pcm.count) / 48,
                "text": "A clause.", "created_at_ms": 1]]]
            return try JSONDecoder().decode(NativeSpeechSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        }
        var cursor = try NativeSpeechCursor(epoch: "epoch-a", cursor: 0)
        let first = try cursor.accept(packet(1,index:0,count:2)); assert(first.count == 1)
        let retry = try cursor.accept(packet(1,index:0,count:2)); assert(retry.isEmpty)
        do { _ = try cursor.accept(packet(3,index:1,count:2)); assertionFailure("missing sequence accepted") } catch {}
        assert(cursor.receivedSequence == 1)
        let second = try cursor.accept(packet(2,index:1,count:2)); assert(second.count == 1)
        do { _ = try cursor.accept(packet(3,order:1,epoch:"other")); assertionFailure("epoch mismatch accepted") } catch {}
        do { _ = try cursor.accept(packet(3,order:1,pcm:Data([1]))); assertionFailure("odd PCM accepted") } catch {}
        assert(cursor.receivedSequence == 2)
        let player = NativeSpeechPlayer()
        try player.start(outputUID:"default",epoch:"epoch-a",cursor:0)
        let silence = Data(repeating:0,count:96000)
        try player.accept(packet(1,pcm:silence))
        let before=player.bufferedMilliseconds
        try await Task.sleep(nanoseconds:250_000_000)
        assert(player.bufferedMilliseconds < before - 100, "rendered frames must reduce remaining audio")
        player.stop()
        let selectedUID = AudioDevices.defaultOutputUID()!
        try player.start(outputUID:selectedUID,epoch:"epoch-b",cursor:0)
        try player.accept(packet(1,epoch:"epoch-b",pcm:silence))
        try await Task.sleep(nanoseconds:250_000_000)
        assert(player.playedSequence == 0 && !player.drained, "old callback advanced restarted playback")
        try await Task.sleep(nanoseconds:2_100_000_000)
        assert(player.playedSequence == 1 && player.drained, "dataPlayedBack completion did not drain")
        player.stop()
        try player.start(outputUID:"default",epoch:"epoch-a",cursor:0)
        try player.accept(packet(1,index:0,count:2))
        try await Task.sleep(nanoseconds:300_000_000)
        assert(player.playedSequence == 1 && player.bufferedMilliseconds == 0)
        assert(!player.drained, "a truncated final sentence was reported as successfully drained")
        try player.accept(packet(2,index:1,count:2))
        try await Task.sleep(nanoseconds:300_000_000)
        assert(player.drained)
        player.stop()
        assert(player.bufferedMilliseconds == 0)
        assert(!player.isPlaying)
        print("NativeSpeechPlayerChecks passed: continuity, sequence, epoch, format, render progress, selected device, restart fencing and successful drain")
    }
}
