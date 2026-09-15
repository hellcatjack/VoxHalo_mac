import AppKit
import Carbon

@MainActor final class SubtitleHotKeyController {
    private static let signature: UInt32 = 0x56485343 // VHSC
    private var handler: EventHandlerRef?
    private var references: [SubtitleShortcutAction: EventHotKeyRef] = [:]
    private var gesture = SubtitleShortcutGesture()
    private var repeatTimer: Timer?
    private var active = false
    private var sleepObserver: NSObjectProtocol?
    private(set) var preferences = SubtitleShortcutPreferences.load()
    private(set) var failures: [SubtitleShortcutAction: OSStatus] = [:]
    var registeredActions: Set<SubtitleShortcutAction> { Set(references.keys) }
    var onAction: ((SubtitleShortcutAction) -> Void)?
    var onStatusChange: (() -> Void)?

    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                identifier.signature == 0x56485343,
                let action = SubtitleShortcutAction.allCases.first(where: { $0.id == identifier.id }) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<SubtitleHotKeyController>.fromOpaque(context).takeUnretainedValue()
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // Carbon delivers this handler on the main event loop. Queue the UI
            // work without activating any window or forwarding a raw key to PPT.
            DispatchQueue.main.async { [weak owner] in owner?.receive(action, down: down) }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stopRepeating() }
            }
    }
    deinit {
        repeatTimer?.invalidate()
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }
    func configure(_ value: SubtitleShortcutPreferences) {
        guard preferences != value else { return }
        unregister(); preferences = value; register()
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        unregister(); active = value; register()
    }
    private func unregister() {
        stopRepeating()
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll(); failures.removeAll()
    }
    private func register() {
        defer { onStatusChange?() }
        guard active, preferences.enabled else { return }
        let reserved = Self.systemReservedKeys()
        for action in SubtitleShortcutAction.allCases {
            guard handler != nil else { failures[action] = OSStatus(eventInternalErr); continue }
            let key = preferences.key(for: action)
            guard !reserved.contains(key) else { failures[action] = OSStatus(eventHotKeyExistsErr); continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key, SubtitleShortcutPreferences.modifiers,
                EventHotKeyID(signature: Self.signature, id: action.id), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference { references[action] = reference }
            else { failures[action] = status }
        }
    }
    private static func systemReservedKeys() -> Set<UInt32> {
        let symbols = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: [String: Any]] ?? [:]
        let mask = NSEvent.ModifierFlags([.control, .shift, .command, .option]).rawValue
        let expected = NSEvent.ModifierFlags([.control, .shift, .command]).rawValue
        return Set(symbols.values.compactMap { entry in
            guard entry["enabled"] as? Bool == true, let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3,
                  parameters[2].uintValue & mask == expected else { return nil }
            return parameters[1].uint32Value
        })
    }
    private func receive(_ action: SubtitleShortcutAction, down: Bool) {
        guard active, references[action] != nil else { return }
        if down {
            if let fired = gesture.press(action, at: ProcessInfo.processInfo.systemUptime) { onAction?(fired) }
            if gesture.repeating != nil && repeatTimer == nil {
                let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.repeatTick() }
                }
                repeatTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
        } else { gesture.release(action) }
        if gesture.repeating == nil { repeatTimer?.invalidate(); repeatTimer = nil }
    }
    private func repeatTick() {
        guard let action = gesture.repeating else { stopRepeating(); return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let relevant: CGEventFlags = [.maskControl, .maskShift, .maskCommand, .maskAlternate]
        let held = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(preferences.key(for: action)))
            && flags.intersection(relevant) == [.maskControl, .maskShift, .maskCommand]
        if let fired = gesture.repeatAction(at: ProcessInfo.processInfo.systemUptime, stillHeld: held) { onAction?(fired) }
        if !held { stopRepeating() }
    }
    private func stopRepeating() { gesture.reset(); repeatTimer?.invalidate(); repeatTimer = nil }
}
