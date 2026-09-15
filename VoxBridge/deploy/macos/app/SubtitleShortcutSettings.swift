import AppKit
import Carbon

@MainActor final class SubtitleShortcutSettingsView: NSStackView {
    var onChange: ((SubtitleShortcutPreferences) -> Void)?
    private(set) var preferences = SubtitleShortcutPreferences.load()
    private let enabled = NSButton(checkboxWithTitle: "传译时启用全局快捷键", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let reset = NSButton(title: "恢复默认快捷键", target: nil, action: nil)
    private var labels: [SubtitleShortcutAction: NSTextField] = [:]
    private var popups: [SubtitleShortcutAction: NSPopUpButton] = [:]
    private var failures: [SubtitleShortcutAction: OSStatus] = [:]
    private var active = false
    private var error = ""
    private var layoutObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        enabled.target = self; enabled.action = #selector(enabledChanged)
        addArrangedSubview(enabled)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let choices = SubtitleShortcutPreferences.keyNames.keys.sorted {
            SubtitleShortcutPreferences.keyNames[$0]! < SubtitleShortcutPreferences.keyNames[$1]!
        }
        for action in SubtitleShortcutAction.allCases {
            let label = NSTextField(labelWithString: "")
            label.widthAnchor.constraint(equalToConstant: 210).isActive = true
            let popup = NSPopUpButton(); popup.tag = Int(action.id)
            popup.target = self; popup.action = #selector(keyChanged(_:)); popup.menu?.autoenablesItems = false
            for key in choices {
                popup.addItem(withTitle: SubtitleShortcutPreferences.label(for: key))
                popup.lastItem?.representedObject = NSNumber(value: key)
                popup.lastItem?.identifier = NSUserInterfaceItemIdentifier("literal")
            }
            popup.widthAnchor.constraint(equalToConstant: 180).isActive = true
            labels[action] = label; popups[action] = popup
            let row = NSStackView(views: [label, popup]); row.spacing = 10
            addArrangedSubview(row)
        }
        status.font = .systemFont(ofSize: 11)
        addArrangedSubview(status); status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        reset.target = self; reset.action = #selector(restoreDefaults); reset.bezelStyle = .rounded
        addArrangedSubview(reset); sync()
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshLocalization() }
            }
    }
    deinit { if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setStatus(failures: [SubtitleShortcutAction: OSStatus], active: Bool) {
        self.failures = failures; self.active = active; refreshLocalization()
    }
    func refreshLocalization() {
        enabled.title = NativeLocalization.text("传译时启用全局快捷键")
        hint.stringValue = NativeLocalization.text("固定使用 Control + Shift + Command；可修改末尾按键。短按移动 8 点，长按连续移动。")
        reset.title = NativeLocalization.text("恢复默认快捷键")
        for action in SubtitleShortcutAction.allCases {
            labels[action]?.stringValue = NativeLocalization.text(action.title)
            popups[action]?.setAccessibilityLabel(NativeLocalization.text(action.title))
            for item in popups[action]?.itemArray ?? [] {
                if let key = item.representedObject as? NSNumber { item.title = SubtitleShortcutPreferences.label(for: key.uint32Value) }
            }
        }
        if !error.isEmpty { status.stringValue = NativeLocalization.render(error); status.textColor = .systemRed }
        else if !failures.isEmpty {
            let names = SubtitleShortcutAction.allCases.filter { failures[$0] != nil }
                .map { NativeLocalization.text($0.title) + " (" + preferences.label(for: $0) + ")" }.joined(separator: ", ")
            status.stringValue = NativeLocalization.text("快捷键不可用或已被占用：{0}。请更换按键，或关闭占用程序后重新开始传译。", names)
            status.textColor = .systemOrange
        } else {
            status.stringValue = NativeLocalization.text(!preferences.enabled ? "全局快捷键已关闭" : active ? "快捷键已生效 · 不影响放映和朗读" : "开始传译后生效；停止传译后释放快捷键。")
            status.textColor = .secondaryLabelColor
        }
    }
    private func sync() {
        enabled.state = preferences.enabled ? .on : .off
        for action in SubtitleShortcutAction.allCases {
            guard let popup = popups[action] else { continue }
            popup.isEnabled = preferences.enabled
            for item in popup.itemArray {
                let key = (item.representedObject as! NSNumber).uint32Value
                item.isEnabled = !SubtitleShortcutAction.allCases.contains { $0 != action && preferences.key(for: $0) == key }
                if key == preferences.key(for: action) { popup.select(item) }
            }
        }
        refreshLocalization()
    }
    private func save(_ value: SubtitleShortcutPreferences) {
        do { try value.save(); preferences = value; error = ""; onChange?(value) }
        catch { self.error = "无法保存字幕设置：\(error.localizedDescription)" }
        sync()
    }
    @objc private func enabledChanged() {
        var value = preferences; value.enabled = enabled.state == .on; save(value)
    }
    @objc private func keyChanged(_ sender: NSPopUpButton) {
        guard let action = SubtitleShortcutAction.allCases.first(where: { Int($0.id) == sender.tag }),
              let key = sender.selectedItem?.representedObject as? NSNumber else { return }
        var value = preferences
        guard value.assign(key.uint32Value, to: action) else {
            error = "该按键已用于另一个字幕操作。"; sync(); return
        }
        save(value)
    }
    @objc private func restoreDefaults() { save(SubtitleShortcutPreferences()) }
}
