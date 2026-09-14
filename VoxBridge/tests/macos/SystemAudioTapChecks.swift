import Foundation
import CoreAudio

@main struct SystemAudioTapChecks {
    @MainActor static func main() async throws {
        let description = try SystemAudioTap.description(excluding: 42)
        assert(description.processes == [42] && description.isExclusive)
        assert(description.isMono && description.isMixdown && description.isPrivate)
        assert(description.muteBehavior == .mutedWhenTapped, "source must recover as soon as capture stops")
        do { _ = try SystemAudioTap.description(excluding: 0); assertionFailure("missing self-exclusion accepted") } catch {}
        let aggregate = SystemAudioTap.aggregateDescription(tapUID: "tap-test")
        assert(aggregate[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        assert(aggregate[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false, "paused YouTube must not block startup")
        let taps = aggregate[kAudioAggregateDeviceTapListKey] as! [[String: Any]]
        assert(taps.first?[kAudioSubTapUIDKey] as? String == "tap-test")
        var events: [String] = []
        let cleanup = AudioTapCleanup()
        cleanup.add { events.append("tap") }
        cleanup.add { events.append("aggregate") }
        cleanup.add { events.append("io") }
        cleanup.close(); cleanup.close()
        assert(events == ["io", "aggregate", "tap"], "stop reading before releasing the tap; cleanup must be idempotent")
        var preferences = NativePreferences(); preferences.inputUID = "system-muted"
        assert(preferences.usesSystemAudio, "virtual capture must not be mistaken for a disconnected microphone")
        preferences.inputUID = "microphone"; assert(!preferences.usesSystemAudio)
        for cancelTask in [false, true] { try await checkPendingStop(cancelTask: cancelTask) }
        let active = AudioTapLifecycle(), cleaned = DispatchSemaphore(value: 0)
        try await active.start { $0.add { cleaned.signal() } }
        await active.stop()
        assert(cleaned.wait(timeout: .now()) == .success, "active stop returned before cleanup")
        let failed = AudioTapLifecycle()
        do {
            try await failed.start { cleanup in
                cleanup.add { cleaned.signal() }
                throw NativeAudioError.message("partial HAL failure")
            }
            assertionFailure("partial startup error swallowed")
        } catch is NativeAudioError {}
        assert(cleaned.wait(timeout: .now()) == .success, "partial startup leaked resources")
        await failed.stop()
        print("PASS: tap configuration, self-exclusion, conditional mute, pending stop/task cancellation, late/active/partial-failure cleanup")
    }

    @MainActor static func checkPendingStop(cancelTask: Bool) async throws {
        let lifecycle = AudioTapLifecycle()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        var returned = false
        let starting = Task {
            defer { returned = true }
            try await lifecycle.start { cleanup in
                cleanup.add { cleaned.signal() }
                entered.signal()
                release.wait() // Models synchronous AudioDeviceStart waiting for macOS permission.
            }
        }
        func enteredStartup() -> Bool { entered.wait(timeout: .now()) == .success }
        while !enteredStartup() { await Task.yield() }
        if cancelTask { starting.cancel() }
        var stopped = false
        let stopping: Task<Void, Never>? = cancelTask ? nil : Task { await lifecycle.stop(); stopped = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        assert(cancelTask ? returned : stopped, "cancellation is blocked behind the macOS permission prompt")
        do { try await starting.value; assertionFailure("cancelled startup succeeded") } catch is CancellationError {}
        assert(cleaned.wait(timeout: .now()) == .timedOut, "HAL cleanup raced the pending OS call")
        release.signal()
        await stopping?.value
        assert(cleaned.wait(timeout: .now() + 2) == .success, "late startup was not cleaned up")
        await lifecycle.stop()
        assert(cleaned.wait(timeout: .now()) == .timedOut, "cleanup ran more than once")
    }
}
