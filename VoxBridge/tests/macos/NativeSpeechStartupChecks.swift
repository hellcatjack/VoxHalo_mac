import Foundation

@main struct NativeSpeechStartupChecks {
    static func main() throws {
        var attempts = 0, restarts = 0
        func recover(available: Bool = true, running: Bool = false, scheduled: Bool = false) throws {
            try NativeSpeechStartupRecovery.recover(deviceAvailable: available, isRunning: running,
                hasScheduledAudio: scheduled, attempts: &attempts) { restarts += 1 }
        }
        try recover()
        assert(attempts == 1 && restarts == 1, "an empty startup engine must recover")
        try recover(running: true, scheduled: true)
        assert(attempts == 1 && restarts == 1, "a late notification must leave healthy playback alone")
        do { try recover(scheduled: true); assertionFailure("scheduled speech must never be discarded by recovery") }
        catch {}
        assert(attempts == 1 && restarts == 1)
        do { try recover(available: false); assertionFailure("a disconnected or changed output must not be restarted") }
        catch {}
        assert(attempts == 1 && restarts == 1)
        try recover()
        do { try recover(); assertionFailure("unstable hardware must not cause an endless restart loop") }
        catch {}
        assert(attempts == 2 && restarts == 2)
        enum RestartFailure: Error { case rejected }
        attempts = 0
        do {
            try NativeSpeechStartupRecovery.recover(deviceAvailable: true, isRunning: false,
                hasScheduledAudio: false, attempts: &attempts) { throw RestartFailure.rejected }
            assertionFailure("restart failures must reach the session")
        } catch RestartFailure.rejected {}
        assert(attempts == 1)
        print("NativeSpeechStartupChecks passed")
    }
}
