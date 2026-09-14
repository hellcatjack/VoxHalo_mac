import Foundation

@MainActor final class QuietCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var holdStart = false
    var startEntered = false
    var stopped = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    func start(inputUID: String) async throws {
        startEntered = true
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
    }
    func stop() async { stopped = true; startWaiter?.resume(); startWaiter = nil }
}

@main struct LifecycleChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let http = URLSession(configuration: .ephemeral)
        func verifyReleased() async throws {
            let (data, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let tts = state["tts"] as! [String: Any]
            assert(tts["listener_count"] as? Int == 0)
            // WebSocket disconnect accounting is asynchronous in the server.
            for _ in 0..<20 {
                let (next, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
                let value = try JSONSerialization.jsonObject(with: next) as! [String: Any]
                if (value["tts"] as! [String: Any])["producer_active"] as? Bool == false { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            assertionFailure("producer remains active after stop")
        }
        // Stop during listener preparation or pending capture. A late transport
        // request must not recreate the listener after stop deletes it.
        var playbackPreferences = NativePreferences(); playbackPreferences.outputUID = "default"
        let bootstrapPreferences = playbackPreferences
        for cancelStartTask in [false, true] {
            let bootstrapCapture = QuietCapture()
            bootstrapCapture.holdStart = true
            let bootstrap = NativeSession(capture: bootstrapCapture)
            let booting = Task { try await bootstrap.start(preferences: bootstrapPreferences, root: root) }
            let bootstrapDeadline = Date().addingTimeInterval(8)
            var leasePresent = false
            while Date() < bootstrapDeadline {
                let (data, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
                let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                leasePresent = (state["tts"] as! [String: Any])["listener_count"] as? Int == 1
                if leasePresent { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            assert(leasePresent, "did not exercise pending startup with an active listener")
            if cancelStartTask { booting.cancel() }
            await bootstrap.stop(drain: false)
            do { try await booting.value; assertionFailure("bootstrap resumed after stop") } catch is CancellationError {} catch { throw error }
            try await verifyReleased()
        }

        // Healthy status polling must not hide a missing explicitly selected output.
        var outputs = try AudioDevices.outputs()
        let selectedOutput = outputs.first!
        let source = QuietCapture()
        let native = NativeSession(capture: source, outputDevices: { outputs })
        var pref = NativePreferences(); pref.outputUID = selectedOutput.uid
        try await native.start(preferences: pref, root: root)
        outputs = []
        let deadline = Date().addingTimeInterval(6)
        while native.isActive && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        assert(native.phase == .failed && source.stopped, "selected-device loss did not stop capture")
        assert(native.lastError?.contains("输出设备已断开") == true)
        try await verifyReleased()

        // Stop while capture awaits startup, and ensure the pending start cannot revive it.
        let held = QuietCapture(); held.holdStart = true
        let pending = NativeSession(capture: held)
        pref.outputUID = "none"
        let starting = Task { try await pending.start(preferences: pref, root: root) }
        while !held.startEntered { try await Task.sleep(nanoseconds: 20_000_000) }
        // macOS permission can stay open beyond the backend's 30-second idle
        // deadline. A capture that has not produced PCM must remain connected.
        try await Task.sleep(nanoseconds: 35_000_000_000)
        assert(pending.phase == .starting, "pending audio permission lost its idle WebSocket")
        await pending.stop(drain: false)
        do { try await starting.value; assertionFailure("late start succeeded after stop") } catch is CancellationError {} catch { throw error }
        assert(pending.phase == .idle && held.stopped)
        try await verifyReleased()

        // Concurrent callers of stop must both wait for the same cleanup.
        let running = NativeSession(capture: QuietCapture())
        try await running.start(preferences: pref, root: root)
        let first = Task { await running.stop() }
        while running.phase != .stopping { await Task.yield() }
        await running.stop()
        assert(!running.isActive)
        await first.value
        try await verifyReleased()
        print("Transport startup cancellation / device loss / pending capture cancellation / concurrent stop checks passed")
    }
}
