import AppKit
import CoreImage

private final class ConsoleDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var client: ServiceClient?
    private var snapshot: ServiceSnapshot?
    private let session = NativeSession()
    private var preferences = NativePreferences.load()
    private var subtitlePreferences = SubtitlePreferences.load()
    private let subtitleOverlay = SubtitleOverlayController()
    private lazy var subtitleSettings = SubtitleSettingsController(preferences: subtitlePreferences)
    private var polling = false
    private var choosingFolder = false
    private var operation: String?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var quitRequested = false
    private var canTerminate = false
    private var lastError: String?
    private var timer: Timer?
    private var desktopInstallation: DesktopInstallation?
    private var installationWindow: InstallationWindow?
    private var maintenanceWindowShown = false
    private var desktopReady: Bool { desktopInstallation?.isReady ?? true }
    private let stateLabel = NSTextField(labelWithString: "正在检查服务…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "Qwen ASR · HY-MT · Kokoro")
    private let sessionLabel = NSTextField(labelWithString: "选择设备后开始传译")
    private let ttsLabel = NSTextField(labelWithString: "本机朗读尚未开始")
    private let sourceLabel = NSTextField(wrappingLabelWithString: "原文将在这里显示")
    private let translationLabel = NSTextField(wrappingLabelWithString: "译文将在这里显示")
    private let addressLabel = NSTextField(wrappingLabelWithString: "正在获取局域网地址…")
    private let interfacePopup = NSPopUpButton()
    private let localizedViews = NativeLocalizedViews()
    private var displayedLocale = ""
    private let inputPopup = NSPopUpButton()
    private let outputPopup = NSPopUpButton()
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let termsField = NSTextField(string: "")
    private let meter = NSLevelIndicator()
    private let qrView = NSImageView()
    private let spinner = NSProgressIndicator()
    private var lastQR: String?
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var captureButton: NSButton!
    private var endButton: NSButton!
    private var pageButton: NSButton!
    private var listenerButton: NSButton!
    private var copyButton: NSButton!
    private var folderButton: NSButton!
    private var devicesButton: NSButton!
    private var startMenu: NSMenuItem!
    private var stopMenu: NSMenuItem!
    private var captureMenu: NSMenuItem!
    private var subtitleMenu: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktopInstallation = DesktopInstallation.bundled()
        buildMenu()
        if let installation = desktopInstallation {
            installationWindow = InstallationWindow(installation: installation)
            installationWindow?.onLanguageChange = { [weak self] in self?.refreshInstallationMenu() }
            installationWindow?.onWillStart = { [weak self] completion in self?.validateModelMaintenance(completion) }
            installationWindow?.onClosed = { [weak self] in
                guard let self else { return }
                if !installation.isRunning { self.maintenanceWindowShown = false; self.render() }
            }
            installation.onActivityChange = { [weak self] in self?.render() }
            installation.onReady = { [weak self] in
                guard let self, !self.quitRequested else { return }
                self.installationWindow?.close()
                if self.window == nil { self.launchConsole() }
                else { self.loadInstallation(); self.showWindow(); self.refresh(); self.render() }
            }
            if !installation.isReady {
                startMenu.isEnabled = false; stopMenu.isEnabled = false; captureMenu.isEnabled = false
                refreshInstallationMenu(); showWindow(); return
            }
        }
        launchConsole()
    }

    private func launchConsole() {
        guard desktopReady, window == nil else { return }
        loadInstallation(); buildWindow()
        subtitleOverlay.apply(preferences: subtitlePreferences)
        subtitleSettings.onChange = { [weak self] value in
            guard let self else { return }
            self.subtitlePreferences = value; self.subtitleOverlay.apply(preferences: value); self.render()
        }
        subtitleSettings.onPreview = { [weak self] value in self?.subtitleOverlay.setPreview(value) }
        session.onChange = { [weak self] in self?.render() }
        reloadDevices(); showWindow(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    private func refreshInstallationMenu() {
        if let menu = NSApp.mainMenu { localizedViews.capture(menu) }
        if let menu = statusItem.menu { localizedViews.capture(menu) }
        localizedViews.apply()
    }

    private func loadInstallation() {
        if let installation = desktopInstallation {
            client = installation.serviceRoot.map { ServiceClient(root: $0) }
            return
        }
        let saved = UserDefaults.standard.string(forKey: "serviceRoot")
        let resource = Bundle.main.url(forResource: "installation", withExtension: "json")
        let data = resource.flatMap { try? Data(contentsOf: $0) }
        let bundled = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["service_root"]
        if let path = saved ?? bundled { client = ServiceClient(root: URL(fileURLWithPath: path)) }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded; value.controlSize = .large
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        return value
    }

    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = spacing
        return stack
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }

    /// Native grouped surfaces keep controls aligned without reserving empty columns.
    private func surface(_ body: NSStackView, inset: CGFloat = 14) -> NSBox {
        let box = NSBox(); box.boxType = .custom
        box.borderWidth = 0.5; box.cornerRadius = 12
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor
        box.contentViewMargins = .zero
        let host = box.contentView!
        body.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset),
            body.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset)
        ])
        return box
    }

    private func iconButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let value = button("", action)
        value.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        value.imagePosition = .imageOnly; value.controlSize = .regular
        value.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        value.toolTip = title; value.setAccessibilityLabel(title)
        value.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return value
    }

    private func caption(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = .secondaryLabelColor
        return label
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "同声传译"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 740, height: 560)
        window.backgroundColor = .windowBackgroundColor
        let content = vertical([], spacing: 12); content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = ConsoleDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; window.contentView!.addSubview(scroll); document.addSubview(content)
        let minimumDocumentHeight = document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)
        ])
        func append(_ view: NSView) {
            content.addArrangedSubview(view)
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        func field(_ label: String, _ control: NSView) -> NSStackView {
            let column = vertical([caption(label), control], spacing: 5)
            control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            return column
        }
        let title = NSTextField(labelWithString: "同声传译")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "\(appVersion)（build \(buildNumber)）")
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor; versionLabel.isSelectable = true
        versionLabel.setAccessibilityLabel("应用版本")
        let heading = row([title, versionLabel], spacing: 10); heading.alignment = .firstBaseline
        let subtitle = NSTextField(wrappingLabelWithString: "独立采集 · 本机识别与翻译 · 本机及局域网朗读")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        let identity = vertical([heading, subtitle], spacing: 4)
        subtitle.widthAnchor.constraint(equalTo: identity.widthAnchor).isActive = true
        interfacePopup.addItem(withTitle: "Auto"); interfacePopup.lastItem?.representedObject = "auto"
        for (code, name) in zip(NativeLocalization.codes, NativeLocalization.autonyms) {
            interfacePopup.addItem(withTitle: name); interfacePopup.lastItem?.representedObject = code
        }
        interfacePopup.select(interfacePopup.itemArray.first { $0.representedObject as? String == NativeLocalization.preference() })
        interfacePopup.target = self; interfacePopup.action = #selector(interfaceLanguageChanged)
        let interface = field("界面语言", interfacePopup)
        interface.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let header = row([identity, NSView(), interface], spacing: 18); header.alignment = .centerY
        identity.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        append(header)

        stateLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let state = row([stateLabel, spinner], spacing: 6); state.alignment = .centerY
        modelLabel.font = .systemFont(ofSize: 10); modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingTail
        let status = vertical([state, modelLabel], spacing: 4)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelLabel.widthAnchor.constraint(equalTo: status.widthAnchor).isActive = true
        startButton = iconButton("启动服务", symbol: "power", action: #selector(startService))
        stopButton = iconButton("停止服务", symbol: "stop.circle", action: #selector(stopService))
        captureButton = button("开始传译", #selector(startInterpretation)); captureButton.keyEquivalent = "\r"
        endButton = button("结束传译", #selector(endInterpretation))
        let actions = row([startButton, stopButton, captureButton, endButton], spacing: 7)
        actions.setContentHuggingPriority(.required, for: .horizontal)
        let statusRow = row([status, NSView(), actions], spacing: 12); statusRow.alignment = .centerY
        append(statusRow)

        inputPopup.setAccessibilityLabel("输入来源"); outputPopup.setAccessibilityLabel("朗读输出")
        inputPopup.target = self; inputPopup.action = #selector(saveSelections)
        outputPopup.target = self; outputPopup.action = #selector(saveSelections)
        for language in NativeLanguage.all {
            sourcePopup.addItem(withTitle: language.name)
            sourcePopup.lastItem?.representedObject = language.code
        }
        sourcePopup.selectItem(withTitle: preferences.languagePair.sourceName)
        refreshTargetLanguages(preferred: preferences.languagePair.target.code)
        sourcePopup.setAccessibilityLabel("识别语言"); targetPopup.setAccessibilityLabel("翻译及朗读语言")
        sourcePopup.target = self; sourcePopup.action = #selector(sourceLanguageChanged)
        targetPopup.target = self; targetPopup.action = #selector(saveSelections)
        for popup in [sourcePopup, targetPopup] {
            popup.toolTip = "开始前选择语言；结束传译后可切换，无需重新加载 ASR 或翻译模型。"
        }
        for popup in [inputPopup, outputPopup, sourcePopup, targetPopup] {
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popup.cell?.lineBreakMode = .byTruncatingTail
        }
        let left = vertical([field("输入来源", inputPopup), field("识别语言", sourcePopup)], spacing: 12)
        let right = vertical([field("朗读输出", outputPopup), field("翻译及朗读语言", targetPopup)], spacing: 12)
        for column in [left, right] {
            for child in column.arrangedSubviews { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
        let devices = row([left, right], spacing: 20); devices.distribution = .fillEqually
        termsField.placeholderString = "ASR 提示词，以空格或逗号分隔（可选）"
        termsField.stringValue = preferences.contextTerms.joined(separator: "，")
        termsField.setAccessibilityLabel("ASR 提示词"); termsField.target = self; termsField.action = #selector(saveSelections)
        termsField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        devicesButton = iconButton("刷新设备", symbol: "arrow.clockwise", action: #selector(reloadDevices))
        meter.levelIndicatorStyle = .continuousCapacity; meter.minValue = 0; meter.maxValue = 1
        meter.warningValue = 0.75; meter.criticalValue = 0.95
        meter.widthAnchor.constraint(equalToConstant: 72).isActive = true
        meter.setAccessibilityLabel("输入来源")
        let terms = row([termsField, meter, devicesButton], spacing: 10); terms.alignment = .centerY
        let hint = NSTextField(wrappingLabelWithString: "“只听译音”在传译时关闭原声输出，结束后恢复。系统采集会排除本 App 的朗读。")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        let configuration = vertical([devices, terms, hint], spacing: 12)
        for view in [devices, terms, hint] { view.widthAnchor.constraint(equalTo: configuration.widthAnchor).isActive = true }
        append(surface(configuration))

        sessionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        ttsLabel.font = .systemFont(ofSize: 11); ttsLabel.textColor = .secondaryLabelColor
        sessionLabel.lineBreakMode = .byTruncatingTail; ttsLabel.lineBreakMode = .byTruncatingTail
        let transcript = vertical([sessionLabel, ttsLabel], spacing: 5)
        for label in [sessionLabel, ttsLabel] { label.widthAnchor.constraint(equalTo: transcript.widthAnchor).isActive = true }
        for label in [sourceLabel, translationLabel] {
            label.font = .systemFont(ofSize: 15); label.isSelectable = true; label.maximumNumberOfLines = 3
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        sourceLabel.textColor = .secondaryLabelColor
        translationLabel.font = .systemFont(ofSize: 16, weight: .medium); translationLabel.textColor = .labelColor
        let speech = row([sourceLabel, translationLabel], spacing: 24)
        speech.distribution = .fillEqually; speech.alignment = .top
        speech.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        speech.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        transcript.addArrangedSubview(speech)
        transcript.setCustomSpacing(12, after: ttsLabel)
        speech.widthAnchor.constraint(equalTo: transcript.widthAnchor).isActive = true
        let transcriptSurface = surface(transcript)
        append(transcriptSurface)
        transcriptSurface.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        transcript.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        addressLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); addressLabel.isSelectable = true
        addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageButton = button("打开监控页", #selector(openOperator)); pageButton.controlSize = .regular
        listenerButton = button("听众朗读页", #selector(openListener)); listenerButton.controlSize = .regular
        copyButton = iconButton("复制地址", symbol: "doc.on.doc", action: #selector(copyListener))
        let links = row([pageButton, listenerButton, copyButton], spacing: 8)
        let lanInfo = vertical([caption("局域网听众入口"), addressLabel, links], spacing: 6)
        addressLabel.widthAnchor.constraint(equalTo: lanInfo.widthAnchor).isActive = true
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.widthAnchor.constraint(equalToConstant: 76).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 76).isActive = true
        let lan = row([lanInfo, NSView(), qrView], spacing: 16); lan.alignment = .centerY
        append(lan)

        detailLabel.font = .systemFont(ofSize: 10); detailLabel.maximumNumberOfLines = 3
        detailLabel.textColor = .secondaryLabelColor
        folderButton = desktopInstallation == nil
            ? iconButton("选择服务文件夹…", symbol: "folder", action: #selector(chooseFolder))
            : iconButton("检查或修复模型", symbol: "shippingbox", action: #selector(manageModels))
        let utilities = row([button("字幕设置…", #selector(showSubtitleSettings)),
                             iconButton("查看日志", symbol: "doc.text.magnifyingglass", action: #selector(openLogs)), folderButton], spacing: 7)
        utilities.setContentHuggingPriority(.required, for: .horizontal)
        let footer = row([detailLabel, NSView(), utilities], spacing: 16); footer.alignment = .centerY
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        append(footer)
        refreshInterfaceText(); render()
        content.layoutSubtreeIfNeeded()
        let desired = content.fittingSize.height + 36
        let available = (NSScreen.main?.visibleFrame.height ?? 950) - 50
        window.setContentSize(NSSize(width: 820, height: min(desired, available)))
        minimumDocumentHeight.isActive = true
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        window.center(); render()
    }

    @objc private func interfaceLanguageChanged() {
        let value = interfacePopup.selectedItem?.representedObject as? String ?? "auto"
        NativeLocalization.save(value)
        refreshInterfaceText(); render()
    }

    private func refreshInterfaceText() {
        guard let content = window?.contentView else { return }
        displayedLocale = NativeLocalization.locale
        window.title = NativeLocalization.text("同声传译")
        localizedViews.capture(content, excluding: [stateLabel, modelLabel, sessionLabel, ttsLabel, sourceLabel, translationLabel, addressLabel, detailLabel, interfacePopup])
        if let menu = NSApp.mainMenu { localizedViews.capture(menu) }
        if let menu = statusItem.menu { localizedViews.capture(menu) }
        localizedViews.apply()
        interfacePopup.item(at: 0)?.title = NativeLocalization.text("跟随系统")
        interfacePopup.setAccessibilityLabel(NativeLocalization.text("界面语言"))
        subtitleSettings.refreshLocalization()
        subtitleOverlay.refreshLocalization()
    }

    private func separator(in content: NSStackView) {
        let rule = NSBox(); rule.boxType = .separator; content.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key); value.target = self; return value
    }

    private func buildMenu() {
        let main = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(item("显示控制面板", #selector(showWindow)))
        appMenu.addItem(item("字幕设置…", #selector(showSubtitleSettings))); appMenu.addItem(.separator())
        appMenu.addItem(item("停止服务并退出", #selector(quit), key: "q")); root.submenu = appMenu; main.addItem(root)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""), editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "同声传译")
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(item("显示控制面板", #selector(showWindow)))
        startMenu = item("启动服务", #selector(startService)); stopMenu = item("停止服务", #selector(stopService))
        captureMenu = item("开始传译", #selector(startInterpretation))
        menu.addItem(startMenu); menu.addItem(captureMenu); menu.addItem(stopMenu)
        subtitleMenu = item("显示翻译字幕", #selector(toggleSubtitles))
        menu.addItem(subtitleMenu); menu.addItem(item("字幕设置…", #selector(showSubtitleSettings)))
        menu.addItem(item("打开监控页", #selector(openOperator))); menu.addItem(.separator())
        menu.addItem(item("停止服务并退出", #selector(quit))); statusItem.menu = menu
    }

    @objc private func reloadDevices() {
        guard !session.isActive else { return }
        let input = inputPopup.selectedItem?.representedObject as? String ?? preferences.inputUID
        let output = outputPopup.selectedItem?.representedObject as? String ?? preferences.outputUID
        do {
            setDevices(inputPopup, base: [("系统播放声音", "system"), ("系统播放声音 · 只听译音", "system-muted"), ("系统默认输入", "default")], devices: try AudioDevices.inputs(), selected: input)
            setDevices(outputPopup, base: [("系统默认输出", "default"), ("本机不播放 · 保留局域网朗读", "none")], devices: try AudioDevices.outputs(), selected: output)
        } catch { lastError = error.localizedDescription }
        render()
    }

    private func setDevices(_ popup: NSPopUpButton, base: [(String, String)], devices: [AudioDevice], selected: String) {
        popup.removeAllItems()
        for (name, uid) in base + devices.map({ ($0.name, $0.uid) }) {
            popup.addItem(withTitle: name); popup.lastItem?.representedObject = uid
            if !base.contains(where: { $0.1 == uid }) { popup.lastItem?.identifier = NSUserInterfaceItemIdentifier("literal") }
        }
        if let selectedItem = popup.itemArray.first(where: { $0.representedObject as? String == selected }) {
            popup.select(selectedItem)
        } else {
            popup.addItem(withTitle: "已断开 · \(selected)"); popup.lastItem?.representedObject = selected
            popup.select(popup.lastItem)
        }
        localizedViews.capture(popup); localizedViews.apply()
    }

    private func selectedPreferences() throws -> NativePreferences {
        var value = NativePreferences()
        value.inputUID = inputPopup.selectedItem?.representedObject as? String ?? "system"
        value.outputUID = outputPopup.selectedItem?.representedObject as? String ?? "default"
        let source = sourcePopup.selectedItem?.representedObject as? String ?? "zh"
        let target = targetPopup.selectedItem?.representedObject as? String ?? "en"
        value.direction = "\(source)2\(target)"
        value.contextTerms = termsField.stringValue.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
        return try value.validated()
    }

    private func refreshTargetLanguages(preferred: String) {
        let source = sourcePopup.selectedItem?.representedObject as? String ?? "zh"
        targetPopup.removeAllItems()
        for language in NativeLanguage.all where language.code != source {
            targetPopup.addItem(withTitle: language.name)
            targetPopup.lastItem?.representedObject = language.code
        }
        let choice = targetPopup.itemArray.first { $0.representedObject as? String == preferred }
            ?? targetPopup.itemArray.first { $0.representedObject as? String == preferences.languagePair.source.code }
            ?? targetPopup.itemArray.first
        if let choice { targetPopup.select(choice) }
        if let menu = targetPopup.menu { localizedViews.capture(menu) }; localizedViews.apply()
    }

    @objc private func sourceLanguageChanged() {
        guard !session.isActive else { return }
        let previousTarget = targetPopup.selectedItem?.representedObject as? String ?? "en"
        refreshTargetLanguages(preferred: previousTarget)
        saveSelections()
    }

    @objc private func saveSelections() {
        guard !session.isActive else { return }
        do { preferences = try selectedPreferences(); try preferences.save() }
        catch { lastError = error.localizedDescription }
        render()
    }

    private func refresh() {
        guard desktopReady else { return }
        guard operation == nil, !polling, !choosingFolder else { return }
        guard let client, client.isInstalled else {
            lastError = "未找到本机安装。请选择包含 macos.sh 的 VoxBridge 文件夹。"; render(); return
        }
        polling = true
        if snapshot == nil { render() }
        client.snapshot { [weak self] result in
            guard let self else { return }; self.polling = false
            switch result { case .success(let value): self.snapshot = value
            case .failure(let error): self.snapshot = nil; self.lastError = error.localizedDescription }
            self.render()
        }
    }

    private func render() {
        guard startButton != nil else { return }
        if displayedLocale != NativeLocalization.locale { refreshInterfaceText() }
        let installed = desktopReady && client?.isInstalled == true, running = snapshot?.hasProcess == true, ready = snapshot?.isReady == true
        let busy = maintenanceWindowShown || !desktopReady || operation != nil || snapshot?.busy == true || choosingFolder
        let sessionBusy = session.isActive
        subtitleOverlay.setLiveText(session.subtitleText, identity: session.subtitleIdentity, synchronized: session.subtitleFollowsPlayback, active: !quitRequested && (session.phase == .running || session.phase == .stopping))
        subtitleSettings.setSessionActive(sessionBusy)
        subtitleMenu.state = subtitlePreferences.enabled ? .on : .off
        if let operation { stateLabel.stringValue = operation == "stop" ? "正在停止…" : "正在准备本机服务…" }
        else if ready { stateLabel.stringValue = "本机服务已就绪" }
        else if snapshot == nil && polling { stateLabel.stringValue = "正在检查服务…" }
        else { stateLabel.stringValue = running ? "服务尚未就绪" : "服务已停止" }
        stateLabel.stringValue = NativeLocalization.render(stateLabel.stringValue)
        stateLabel.textColor = ready && !busy ? .systemGreen : .labelColor
        modelLabel.stringValue = "Qwen ASR · \(serviceText("app"))   HY-MT · \(serviceText("translation"))   Kokoro · \(NativeLocalization.text("本机 CPU"))"
        modelLabel.toolTip = modelLabel.stringValue
        if busy || session.phase == .starting || session.phase == .stopping { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        startButton.isEnabled = installed && snapshot != nil && !busy && !ready && !sessionBusy
        stopButton.isEnabled = client?.isInstalled == true && (running || sessionBusy || startTask != nil) && stopTask == nil && !choosingFolder
        captureButton.isEnabled = installed && snapshot != nil && !busy && !sessionBusy
        endButton.isEnabled = (session.phase == .running || session.phase == .starting) && stopTask == nil
        for popup in [inputPopup, outputPopup, sourcePopup, targetPopup] { popup.isEnabled = !busy && !sessionBusy }
        termsField.isEnabled = !busy && !sessionBusy; devicesButton.isEnabled = !busy && !sessionBusy
        pageButton.isEnabled = ready; listenerButton.isEnabled = ready && snapshot?.listener_url != nil
        copyButton.isEnabled = snapshot?.listener_url != nil
        folderButton.isEnabled = !busy && !running && !sessionBusy && (snapshot != nil || !installed)
        startMenu.isEnabled = startButton.isEnabled; stopMenu.isEnabled = stopButton.isEnabled; captureMenu.isEnabled = captureButton.isEnabled
        sessionLabel.stringValue = NativeLocalization.render(session.message)
        sessionLabel.textColor = session.phase == .running ? .systemGreen : session.phase == .failed ? .systemRed : .labelColor
        meter.doubleValue = Double(min(1, session.level * 3))
        let pair = sessionBusy ? session.languagePair : preferences.languagePair
        let showTranscript = pair == session.languagePair
        ttsLabel.stringValue = session.isActive ? NativeLocalization.text("{0}朗读待输出 {1} 秒 · 合成语速 {2}× · 音频连接 {3}", pair.targetName, String(format: "%.1f", session.backlogSeconds), String(format: "%.2f", session.speed), String(session.listenerCount)) : NativeLocalization.text("识别{0} → 翻译并朗读{1} · 开始前可切换方向", pair.sourceName, pair.targetName)
        sourceLabel.stringValue = !showTranscript || session.sourceText.isEmpty ? NativeLocalization.text("{0}原文将在这里显示", pair.sourceName) : session.sourceText
        let displayedTranslation = session.subtitleFollowsPlayback ? session.subtitleText : session.translationText
        translationLabel.stringValue = !showTranscript || displayedTranslation.isEmpty ? NativeLocalization.text(session.subtitleFollowsPlayback ? "等待{0}朗读字幕" : "等待{0}译文", pair.targetName) : displayedTranslation
        addressLabel.stringValue = snapshot?.listener_url ?? snapshot?.lan_error ?? "连接局域网后自动显示地址"
        addressLabel.stringValue = NativeLocalization.render(addressLabel.stringValue)
        if lastQR != snapshot?.listener_url { lastQR = snapshot?.listener_url; updateQR(lastQR) }
        let error = lastError ?? session.lastError ?? snapshot?.service_error ?? session.ttsWarning
        detailLabel.stringValue = error.map { String(NativeLocalization.render($0).prefix(300)) } ?? "关闭窗口后传译继续运行，可从菜单栏返回。“停止服务并退出”会结束采集并释放模型。"
        detailLabel.stringValue = NativeLocalization.render(detailLabel.stringValue)
        detailLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed; detailLabel.toolTip = error.map { NativeLocalization.render($0) }
        statusItem.button?.toolTip = NativeLocalization.text("同声传译") + " · " + (sessionBusy ? NativeLocalization.render(session.message) : stateLabel.stringValue)
    }

    private func updateQR(_ address: String?) {
        guard let address, let filter = CIFilter(name: "CIQRCodeGenerator") else { qrView.image = nil; return }
        filter.setValue(Data(address.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)) else { return }
        let representation = NSCIImageRep(ciImage: image), result = NSImage(size: representation.size)
        result.addRepresentation(representation); qrView.image = result
    }

    private func serviceText(_ name: String) -> String {
        guard let value = snapshot?.services[name] else { return NativeLocalization.text("等待检查") }
        return NativeLocalization.text(value.ready ? "已就绪" : value.pid == nil ? "已停止" : "加载中")
    }

    @objc private func showSubtitleSettings() { guard desktopReady else { showWindow(); return }; subtitleSettings.show() }
    @objc private func toggleSubtitles() {
        guard desktopReady else { return }
        var selected = subtitlePreferences; selected.enabled.toggle()
        do {
            try selected.save(); subtitlePreferences = selected
            subtitleSettings.apply(preferences: selected); subtitleOverlay.apply(preferences: selected)
        } catch { lastError = error.localizedDescription }
        render()
    }

    @objc private func startService() { begin(capture: false) }
    @objc private func startInterpretation() { begin(capture: true) }
    private func begin(capture: Bool) {
        guard desktopReady && !maintenanceWindowShown else { installationWindow?.show(); return }
        guard startTask == nil, stopTask == nil, operation == nil, !session.isActive, !choosingFolder, let client else { return }
        let selected: NativePreferences
        do { selected = try selectedPreferences(); try selected.save(); preferences = selected }
        catch { lastError = error.localizedDescription; render(); return }
        operation = "start"; lastError = nil; render()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.runAsync("start")
                try Task.checkCancellation()
                if capture { try await self.session.start(preferences: selected, root: client.root) }
            } catch {
                if !Task.isCancelled { self.lastError = error.localizedDescription }
            }
            self.startTask = nil
            if self.stopTask == nil { self.operation = nil; self.refresh() }
            self.render()
        }
    }

    @objc private func endInterpretation() { stop(allServices: false) }
    @objc private func stopService() { stop(allServices: true) }
    private func stop(allServices: Bool) {
        guard stopTask == nil, !choosingFolder else { return }
        let pendingStart = startTask; pendingStart?.cancel()
        operation = "stop"; render()
        stopTask = Task { [weak self] in
            guard let self else { return }
            await self.session.stop(drain: !self.quitRequested)
            await pendingStart?.value
            // A service start may have completed while its audio start was cancelled.
            await self.session.stop(drain: false)
            do {
                if allServices || self.quitRequested, let client = self.client { _ = try await client.runAsync("stop") }
            } catch { self.lastError = error.localizedDescription }
            self.stopTask = nil; self.operation = nil
            if self.quitRequested {
                let succeeded = self.lastError == nil
                self.canTerminate = succeeded; self.quitRequested = false
                NSApp.reply(toApplicationShouldTerminate: succeeded)
                if !succeeded { self.showWindow() }
            }
            self.refresh(); self.render()
        }
    }

    @objc private func showWindow() {
        if !desktopReady { installationWindow?.show(); return }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openOperator() { guard desktopReady else { return }; openWeb("http://127.0.0.1:8024") }
    @objc private func openListener() { if let address = snapshot?.listener_url { openWeb(address) } }
    private func openWeb(_ address: String) { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
    @objc private func copyListener() {
        guard let address = snapshot?.listener_url else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
    }
    @objc private func openLogs() { if let client { NSWorkspace.shared.open(client.root.appendingPathComponent("logs", isDirectory: true)) } }

    @objc private func chooseFolder() {
        guard desktopInstallation == nil else { return }
        guard operation == nil, !choosingFolder, snapshot?.hasProcess != true, !session.isActive,
              snapshot != nil || client?.isInstalled != true else { return }
        choosingFolder = true; let originalClient = client; render()
        let panel = NSOpenPanel(); panel.title = NativeLocalization.text("选择 VoxBridge 服务文件夹")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let root = panel.url else { self.choosingFolder = false; self.refresh(); return }
            let candidate = ServiceClient(root: root)
            guard candidate.isInstalled else { self.choosingFolder = false; self.lastError = "未找到服务脚本或上一级 Python 环境。"; self.render(); return }
            let apply = {
                self.choosingFolder = false; self.client = candidate; self.snapshot = nil; self.lastError = nil
                UserDefaults.standard.set(root.path, forKey: "serviceRoot"); self.refresh()
            }
            guard let originalClient, originalClient.isInstalled else { apply(); return }
            originalClient.snapshot { result in
                guard self.client === originalClient, self.operation == nil else { self.choosingFolder = false; self.refresh(); return }
                switch result {
                case .success(let value) where !value.hasProcess && !value.busy: apply()
                case .success(let value): self.snapshot = value; self.choosingFolder = false; self.lastError = "原服务正在运行，请先停止服务。"; self.render()
                case .failure(let error): self.choosingFolder = false; self.lastError = error.localizedDescription; self.render()
                }
            }
        }
    }

    @objc private func manageModels() {
        guard let installation = desktopInstallation, !session.isActive, operation == nil,
              snapshot != nil, snapshot?.hasProcess != true, !choosingFolder, !installation.isRunning else { return }
        maintenanceWindowShown = true; render(); installationWindow?.show()
    }

    private func validateModelMaintenance(_ completion: @escaping (Bool) -> Void) {
        guard !session.isActive, operation == nil, startTask == nil, stopTask == nil, !choosingFolder else { completion(false); return }
        // First-run mode has never loaded a ServiceClient or started a backend.
        guard window != nil else { completion(true); return }
        guard maintenanceWindowShown, let client else { completion(false); return }
        client.snapshot { [weak self] result in
            guard let self else { completion(false); return }
            switch result {
            case .success(let value):
                self.snapshot = value
                completion(self.maintenanceWindowShown && !value.hasProcess && !value.busy &&
                    !self.session.isActive && self.operation == nil && self.startTask == nil && self.stopTask == nil)
            case .failure: completion(false)
            }
            self.render()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let installation = desktopInstallation, !installation.isReady {
            guard installation.isRunning else { return .terminateNow }
            quitRequested = true
            installation.onSettled = { NSApp.reply(toApplicationShouldTerminate: true) }
            installation.cancel()
            return .terminateLater
        }
        if choosingFolder { return .terminateCancel }
        if canTerminate { return .terminateNow }
        quitRequested = true; lastError = nil
        subtitleSettings.close(); subtitleOverlay.close()
        stop(allServices: true)
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
