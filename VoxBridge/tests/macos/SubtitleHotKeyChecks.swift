import AppKit
import Carbon

@main struct SubtitleHotKeyChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var foreign: EventHotKeyRef?
        let registered = RegisterEventHotKey(1, SubtitleShortcutPreferences.modifiers,
            EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), 0, &foreign)
        assert(registered == noErr)
        let controller = SubtitleHotKeyController()
        controller.configure(SubtitleShortcutPreferences())
        controller.setActive(true)
        assert(controller.failures[.toggle] != nil, "already occupied hotkeys must report failure instead of silently replacing another app")
        assert(controller.failures[.up] == nil && controller.failures[.down] == nil)
        controller.setActive(false)
        if let foreign { UnregisterEventHotKey(foreign) }
        controller.setActive(true)
        assert(controller.failures.isEmpty, "restarting interpretation should retry released shortcuts")
        var fired: [SubtitleShortcutAction] = []
        controller.onAction = { fired.append($0) }
        func send(_ kind: Int, id: UInt32) {
            var event: EventRef?
            assert(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), 0, 0, &event) == noErr)
            var identifier = EventHotKeyID(signature: 0x56485343, id: id)
            assert(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
            assert(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        }
        send(kEventHotKeyPressed, id: 1); send(kEventHotKeyPressed, id: 1)
        try await Task.sleep(nanoseconds: 30_000_000)
        assert(fired == [.toggle], "Carbon events must reach the production handler exactly once per press")
        send(kEventHotKeyReleased, id: 1); send(kEventHotKeyPressed, id: 1)
        try await Task.sleep(nanoseconds: 30_000_000)
        assert(fired == [.toggle, .toggle])
        send(kEventHotKeyReleased, id: 1)
        var probe: EventHotKeyRef?
        assert(RegisterEventHotKey(126, SubtitleShortcutPreferences.modifiers,
            EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &probe) != noErr)
        controller.setActive(false)
        assert(RegisterEventHotKey(126, SubtitleShortcutPreferences.modifiers,
            EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &probe) == noErr,
               "idle applications must release their global shortcuts")
        if let probe { UnregisterEventHotKey(probe) }
        var disabled = SubtitleShortcutPreferences(); disabled.enabled = false
        controller.configure(disabled); controller.setActive(true)
        assert(controller.registeredActions.isEmpty)
        controller.setActive(false)
        print("PASS: real Carbon registration, occupied-key detection and idle/disabled cleanup")
    }
}
