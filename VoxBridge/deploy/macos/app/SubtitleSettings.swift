import AppKit

@MainActor final class SubtitleSettingsController: NSObject, NSWindowDelegate {
    var onChange: ((SubtitlePreferences) -> Void)?
    var onPreview: ((Bool) -> Void)?
    private(set) var preferences: SubtitlePreferences
    private var window: NSWindow?
    private var active = false
    private var syncing = false
    private let enabled = NSButton(checkboxWithTitle: "显示翻译字幕", target: nil, action: nil)
    private let preview = NSButton(checkboxWithTitle: "预览字幕样式（仅在未传译时可用）", target: nil, action: nil)
    private let font = NSPopUpButton()
    private let displays = NSPopUpButton()
    private let position = NSPopUpButton()
    private let color = NSColorWell()
    private let colorHex = NSTextField(string: "")
    private let shadowColor = NSColorWell()
    private let shadowHex = NSTextField(string: "")
    private let shadow = NSButton(checkboxWithTitle: "启用文字阴影", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var sliders: [String: NSSlider] = [:]
    private var values: [String: NSTextField] = [:]

    init(preferences: SubtitlePreferences) { self.preferences = preferences.normalized(); super.init() }
    func show() {
        if window == nil { build() }
        reloadDisplays(); sync()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func setSessionActive(_ value: Bool) {
        guard value != active else { return }
        active = value; preview.isEnabled = !value
        if value { preview.state = .off; onPreview?(false) }
    }
    func apply(preferences: SubtitlePreferences) {
        self.preferences = preferences.normalized()
        if window != nil { sync() }
    }
    func close() { window?.close(); preview.state = .off; onPreview?(false) }
    func windowWillClose(_ notification: Notification) { preview.state = .off; onPreview?(false) }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10
        return stack
    }
    private func build() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 670),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "字幕设置"; panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center(); window = panel
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 13
        body.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = NSView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; panel.contentView!.addSubview(scroll); document.addSubview(body)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ])
        let intro = NSTextField(wrappingLabelWithString: "透明置顶，鼠标穿透。只显示已完成的译文；设置即时生效并自动保存。")
        intro.textColor = .secondaryLabelColor; intro.font = .systemFont(ofSize: 12)
        body.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        body.addArrangedSubview(enabled)
        func add(_ name: String, _ view: NSView) {
            let label = NSTextField(labelWithString: name); label.widthAnchor.constraint(equalToConstant: 86).isActive = true
            let line = row([label, view]); body.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            view.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        for name in NSFontManager.shared.availableFonts.sorted(by: {
            (NSFont(name: $0, size: 12)?.displayName ?? $0).localizedStandardCompare(NSFont(name: $1, size: 12)?.displayName ?? $1) == .orderedAscending
        }) {
            font.addItem(withTitle: NSFont(name: name, size: 12)?.displayName ?? name)
            font.lastItem?.representedObject = name
        }
        font.setAccessibilityLabel("字幕字体"); add("字体", font)
        addSlider("fontSize", label: "字号", range: 12...144, to: add)
        configureColor(color, hex: colorHex, label: "字幕颜色")
        add("文字颜色", row([color, colorHex]))
        body.addArrangedSubview(shadow)
        configureColor(shadowColor, hex: shadowHex, label: "阴影颜色")
        add("阴影颜色", row([shadowColor, shadowHex]))
        addSlider("shadowOpacity", label: "阴影浓度", range: 0...1, to: add)
        addSlider("shadowBlur", label: "阴影模糊", range: 0...30, to: add)
        addSlider("shadowOffset", label: "阴影距离", range: 0...20, to: add)
        displays.setAccessibilityLabel("字幕显示器"); add("显示器", displays)
        position.addItems(withTitles: ["顶部居中", "屏幕居中", "底部居中", "自定义位置"])
        position.setAccessibilityLabel("字幕位置预设"); add("位置预设", position)
        addSlider("horizontalPosition", label: "水平位置", range: 0...1, to: add)
        addSlider("verticalPosition", label: "垂直位置", range: 0...1, to: add)
        addSlider("widthFraction", label: "字幕宽度", range: 0.25...1, to: add)
        body.addArrangedSubview(preview)
        let hint = NSTextField(wrappingLabelWithString: "垂直 100% 可覆盖 Dock。字幕跟随本机实际朗读，语音段整段显示，空间不足时自动缩小；本机不播放时显示最新完整译文。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        body.addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        body.addArrangedSubview(errorLabel)
        let reset = NSButton(title: "恢复默认样式", target: self, action: #selector(resetStyle))
        reset.bezelStyle = .rounded
        let refresh = NSButton(title: "刷新显示器", target: self, action: #selector(refreshDisplays))
        refresh.bezelStyle = .rounded
        body.addArrangedSubview(row([reset, refresh]))
        for control in [enabled, shadow, font, displays, position, color, shadowColor, colorHex, shadowHex] as [NSControl] {
            control.target = self; control.action = #selector(changed(_:))
        }
        preview.target = self; preview.action = #selector(previewChanged); preview.isEnabled = !active
        body.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 590, height: min(body.fittingSize.height + 44, (NSScreen.main?.visibleFrame.height ?? 760) - 70)))
        panel.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.center()
        sync()
    }
    private func configureColor(_ well: NSColorWell, hex: NSTextField, label: String) {
        well.widthAnchor.constraint(equalToConstant: 54).isActive = true
        well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        well.setAccessibilityLabel(label)
        hex.widthAnchor.constraint(equalToConstant: 125).isActive = true
        hex.placeholderString = "#RRGGBB"; hex.setAccessibilityLabel(label + "十六进制")
    }
    private func addSlider(_ key: String, label: String, range: ClosedRange<Double>, to add: (String, NSView) -> Void) {
        let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: #selector(changed(_:)))
        slider.isContinuous = true; slider.setAccessibilityLabel(label)
        slider.widthAnchor.constraint(equalToConstant: 305).isActive = true
        let value = NSTextField(labelWithString: ""); value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 80).isActive = true
        sliders[key] = slider; values[key] = value; add(label, row([slider, value]))
    }
    @objc private func refreshDisplays() { reloadDisplays(); sync() }
    private func reloadDisplays() {
        displays.removeAllItems(); displays.addItem(withTitle: "主显示器（自动）"); displays.lastItem?.representedObject = ""
        for screen in NSScreen.screens {
            displays.addItem(withTitle: screen.localizedName)
            displays.lastItem?.representedObject = SubtitleDisplays.id(screen)
        }
        if !preferences.screenID.isEmpty && !displays.itemArray.contains(where: { $0.representedObject as? String == preferences.screenID }) {
            displays.addItem(withTitle: "所选显示器已断开 · 暂用主显示器")
            displays.lastItem?.representedObject = preferences.screenID
        }
    }
    private func sync() {
        syncing = true; defer { syncing = false }
        let p = preferences
        enabled.state = p.enabled ? .on : .off; shadow.state = p.shadowEnabled ? .on : .off
        if !font.itemArray.contains(where: { $0.representedObject as? String == p.fontName }) {
            font.addItem(withTitle: "\(p.fontName)（未安装，使用系统字体）"); font.lastItem?.representedObject = p.fontName
        }
        font.select(font.itemArray.first(where: { $0.representedObject as? String == p.fontName }))
        displays.select(displays.itemArray.first(where: { $0.representedObject as? String == p.screenID }))
        color.color = NSColor(subtitleHex: p.textColorHex); colorHex.stringValue = p.textColorHex
        shadowColor.color = NSColor(subtitleHex: p.shadowColorHex); shadowHex.stringValue = p.shadowColorHex
        for (key, number) in ["fontSize": p.fontSize, "shadowOpacity": p.shadowOpacity, "shadowBlur": p.shadowBlur,
                              "shadowOffset": p.shadowOffset, "horizontalPosition": p.horizontalPosition,
                              "verticalPosition": p.verticalPosition, "widthFraction": p.widthFraction] {
            sliders[key]?.doubleValue = number
            let percent = ["shadowOpacity", "horizontalPosition", "verticalPosition", "widthFraction"].contains(key)
            values[key]?.stringValue = percent ? String(format: "%.0f%%", number * 100) : String(format: "%.0f pt", number)
        }
        let selected: Int
        if abs(p.horizontalPosition - 0.5) > 0.001 { selected = 3 }
        else if abs(p.verticalPosition - 0.1) < 0.001 { selected = 0 }
        else if abs(p.verticalPosition - 0.5) < 0.001 { selected = 1 }
        else if abs(p.verticalPosition - 1) < 0.001 { selected = 2 }
        else { selected = 3 }
        position.selectItem(at: selected)
        for view in [shadowColor, shadowHex, sliders["shadowOpacity"]!, sliders["shadowBlur"]!, sliders["shadowOffset"]!] as [NSControl] {
            view.isEnabled = p.shadowEnabled
        }
    }
    @objc private func changed(_ sender: NSControl) {
        guard !syncing else { return }
        var p = preferences
        p.enabled = enabled.state == .on; p.shadowEnabled = shadow.state == .on
        p.fontName = font.selectedItem?.representedObject as? String ?? p.fontName
        p.screenID = displays.selectedItem?.representedObject as? String ?? ""
        p.textColorHex = sender === color ? color.color.subtitleHex : colorHex.stringValue
        p.shadowColorHex = sender === shadowColor ? shadowColor.color.subtitleHex : shadowHex.stringValue
        for hex in [p.textColorHex, p.shadowColorHex] {
            guard hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                errorLabel.stringValue = "颜色请填写 #RRGGBB，例如 #FFFFFF。"; return
            }
        }
        p.fontSize = sliders["fontSize"]!.doubleValue.rounded()
        p.shadowOpacity = sliders["shadowOpacity"]!.doubleValue
        p.shadowBlur = sliders["shadowBlur"]!.doubleValue.rounded()
        p.shadowOffset = sliders["shadowOffset"]!.doubleValue.rounded()
        p.horizontalPosition = sliders["horizontalPosition"]!.doubleValue
        p.verticalPosition = sliders["verticalPosition"]!.doubleValue
        p.widthFraction = sliders["widthFraction"]!.doubleValue
        if sender === position && (0..<3).contains(position.indexOfSelectedItem) {
            p.horizontalPosition = 0.5; p.verticalPosition = [0.1, 0.5, 1.0][position.indexOfSelectedItem]
        }
        save(p)
    }
    private func save(_ value: SubtitlePreferences) {
        do {
            let p = value.normalized(); try p.save(); preferences = p
            errorLabel.stringValue = ""; sync(); onChange?(p)
        } catch { errorLabel.stringValue = "无法保存字幕设置：\(error.localizedDescription)" }
    }
    @objc private func resetStyle() { save(SubtitlePreferences()) }
    @objc private func previewChanged() { onPreview?(preview.state == .on && !active) }
}
