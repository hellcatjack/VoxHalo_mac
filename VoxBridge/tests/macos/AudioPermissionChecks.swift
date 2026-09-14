import Foundation

@main struct AudioPermissionChecks {
    @MainActor static func main() async throws {
        let granted = AudioPermissionWaiter()
        let yes = try await granted.wait { reply in reply(true) }
        assert(yes)
        let denied = AudioPermissionWaiter()
        let no = try await denied.wait { reply in reply(false) }
        assert(!no)

        let stopped = AudioPermissionWaiter()
        var callback: (@Sendable (Bool) -> Void)?
        let pending = Task { try await stopped.wait { callback = $0 } }
        while callback == nil { await Task.yield() }
        stopped.cancel()
        do { _ = try await pending.value; assertionFailure("stop must release a pending OS permission wait") } catch is CancellationError {}
        callback?(true) // The user's late response must not resume the old continuation twice.
        await Task.yield()

        let cancelled = AudioPermissionWaiter()
        var entered = false
        let task = Task { try await cancelled.wait { _ in entered = true } }
        while !entered { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; assertionFailure("task cancellation must not depend on answering the OS dialog") } catch is CancellationError {}

        let beforeStart = AudioPermissionWaiter(); beforeStart.cancel()
        do { _ = try await beforeStart.wait { _ in assertionFailure("cancelled wait must not request access") }; assertionFailure() } catch is CancellationError {}
        let restarted = AudioPermissionWaiter()
        let again = try await restarted.wait { reply in reply(true) }
        assert(again)
        print("PASS: grant, denial, stop, task cancellation, late reply and fresh permission request")
    }
}
