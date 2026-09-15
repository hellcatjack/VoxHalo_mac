import AppKit
import CoreImage

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
    private let stateLabel = NSTextField(labelWithString: "正在检查服务…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "Qwen ASR · HY-MT · Kokoro")
    private let sessionLabel = NSTextField(labelWithString: "选择设备后开始传译")
    private let ttsLabel = NSTextField(labelWithString: "本机朗读尚未开始")
    private let sourceLabel = NSTextField(wrappingLabelWithString: "原文将在这里显示")
    private let translationLabel = NSTextField(wrappingLabelWithString: "译文将在这里显示")
    private let addressLabel = NSTextField(wrappingLabelWithString: "正在获取局域网地址…")
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
        loadInstallation(); buildMenu(); buildWindow()
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

    private func loadInstallation() {
        let saved = UserDefaults.standard.string(forKey: "serviceRoot")
        let resource = Bundle.main.url(forResource: "installation", withExtension: "json")
        let data = resource.flatMap { try? Data(contentsOf: $0) }
        let bundled = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["service_root"]
        if let path = saved ?? bundled { client = ServiceClient(root: URL(fileURLWithPath: path)) }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded; value.controlSize = .large
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

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 750),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "同声传译"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 700, height: 680); window.center()
        let content = vertical([], spacing: 14); content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let title = NSTextField(labelWithString: "同声传译")
        title.font = .systemFont(ofSize: 25, weight: .bold)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "\(appVersion)（build \(buildNumber)）")
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor; versionLabel.isSelectable = true
        versionLabel.setAccessibilityLabel("应用版本")
        let heading = row([title, versionLabel], spacing: 12)
        heading.alignment = .firstBaseline
        let subtitle = NSTextField(labelWithString: "独立采集 · 本机识别与翻译 · 本机及局域网朗读")
        subtitle.textColor = .secondaryLabelColor
        content.addArrangedSubview(vertical([heading, subtitle], spacing: 4))
        stateLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        content.addArrangedSubview(row([spinner, stateLabel]))
        modelLabel.font = .systemFont(ofSize: 12); modelLabel.textColor = .secondaryLabelColor
        content.addArrangedSubview(modelLabel)

        startButton = button("启动服务", #selector(startService))
        stopButton = button("停止服务", #selector(stopService))
        captureButton = button("开始传译", #selector(startInterpretation)); captureButton.keyEquivalent = "\r"
        endButton = button("结束传译", #selector(endInterpretation))
        content.addArrangedSubview(row([startButton, stopButton, captureButton, endButton]))
        separator(in: content)

        let inputs = NSTextField(labelWithString: "输入来源")
        let outputs = NSTextField(labelWithString: "朗读输出")
        inputPopup.setAccessibilityLabel("输入来源"); outputPopup.setAccessibilityLabel("朗读输出")
        inputPopup.target = self; inputPopup.action = #selector(saveSelections)
        outputPopup.target = self; outputPopup.action = #selector(saveSelections)
        let deviceRow = row([vertical([inputs, inputPopup]), vertical([outputs, outputPopup])], spacing: 18)
        deviceRow.distribution = .fillEqually; content.addArrangedSubview(deviceRow)
        deviceRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        for popup in [inputPopup, outputPopup] { popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 295).isActive = true }

        for language in NativeLanguage.all {
            sourcePopup.addItem(withTitle: language.name)
            sourcePopup.lastItem?.representedObject = language.code
        }
        sourcePopup.selectItem(withTitle: preferences.languagePair.sourceName)
        refreshTargetLanguages(preferred: preferences.languagePair.target.code)
        sourcePopup.setAccessibilityLabel("识别语言")
        targetPopup.setAccessibilityLabel("翻译及朗读语言")
        sourcePopup.target = self; sourcePopup.action = #selector(sourceLanguageChanged)
        targetPopup.target = self; targetPopup.action = #selector(saveSelections)
        for popup in [sourcePopup, targetPopup] {
            popup.toolTip = "开始前选择语言；结束传译后可切换，无需重新加载 ASR 或翻译模型。"
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        devicesButton = button("刷新设备", #selector(reloadDevices))
        meter.levelIndicatorStyle = .continuousCapacity; meter.minValue = 0; meter.maxValue = 1
        meter.warningValue = 0.75; meter.criticalValue = 0.95
        meter.widthAnchor.constraint(equalToConstant: 110).isActive = true
        content.addArrangedSubview(row([NSTextField(labelWithString: "识别"), sourcePopup, NSTextField(labelWithString: "→ 译音"), targetPopup, devicesButton, meter]))
        termsField.placeholderString = "ASR 提示词，以空格或逗号分隔（可选）"
        termsField.stringValue = preferences.contextTerms.joined(separator: "，")
        termsField.setAccessibilityLabel("ASR 提示词"); termsField.target = self; termsField.action = #selector(saveSelections)
        content.addArrangedSubview(termsField); termsField.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let hint = NSTextField(labelWithString: "“只听译音”在传译时关闭原声输出，结束后恢复。系统采集会排除本 App 的朗读。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; content.addArrangedSubview(hint)

        sessionLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        ttsLabel.font = .systemFont(ofSize: 12); ttsLabel.textColor = .secondaryLabelColor
        content.addArrangedSubview(vertical([sessionLabel, ttsLabel], spacing: 5))
        for label in [sourceLabel, translationLabel] {
            label.font = .systemFont(ofSize: 15); label.isSelectable = true; label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail; content.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 35).isActive = true
        }
        translationLabel.textColor = .systemBlue
        separator(in: content)

        addressLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular); addressLabel.isSelectable = true
        pageButton = button("打开监控页", #selector(openOperator))
        listenerButton = button("听众朗读页", #selector(openListener))
        copyButton = button("复制地址", #selector(copyListener))
        let lanTitle = NSTextField(labelWithString: "局域网听众入口")
        lanTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.widthAnchor.constraint(equalToConstant: 84).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 84).isActive = true
        let lan = row([vertical([lanTitle, addressLabel, row([pageButton, listenerButton, copyButton])]), qrView], spacing: 20)
        content.addArrangedSubview(lan)
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.maximumNumberOfLines = 3
        content.addArrangedSubview(detailLabel)
        detailLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        folderButton = button("选择服务文件夹…", #selector(chooseFolder))
        content.addArrangedSubview(row([button("查看日志", #selector(openLogs)), button("字幕设置…", #selector(showSubtitleSettings)), folderButton]))
        content.layoutSubtreeIfNeeded()
        let desired = content.fittingSize.height + 44
        let available = (NSScreen.main?.visibleFrame.height ?? 950) - 40
        window.setContentSize(NSSize(width: 750, height: min(max(710, desired), available)))
        render()
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
        }
        if let selectedItem = popup.itemArray.first(where: { $0.representedObject as? String == selected }) {
            popup.select(selectedItem)
        } else {
            popup.addItem(withTitle: "已断开 · \(selected)"); popup.lastItem?.representedObject = selected
            popup.select(popup.lastItem)
        }
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
        let installed = client?.isInstalled == true, running = snapshot?.hasProcess == true, ready = snapshot?.isReady == true
        let busy = operation != nil || snapshot?.busy == true || choosingFolder
        let sessionBusy = session.isActive
        subtitleOverlay.setLiveText(session.subtitleText, identity: session.subtitleIdentity, synchronized: session.subtitleFollowsPlayback, active: !quitRequested && (session.phase == .running || session.phase == .stopping))
        subtitleSettings.setSessionActive(sessionBusy)
        subtitleMenu.state = subtitlePreferences.enabled ? .on : .off
        if let operation { stateLabel.stringValue = operation == "stop" ? "正在停止…" : "正在准备本机服务…" }
        else if ready { stateLabel.stringValue = "本机服务已就绪" }
        else if snapshot == nil && polling { stateLabel.stringValue = "正在检查服务…" }
        else { stateLabel.stringValue = running ? "服务尚未就绪" : "服务已停止" }
        stateLabel.textColor = ready && !busy ? .systemGreen : .labelColor
        modelLabel.stringValue = "Qwen ASR · \(serviceText("app"))   HY-MT · \(serviceText("translation"))   Kokoro · 本机 CPU"
        if busy || session.phase == .starting || session.phase == .stopping { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        startButton.isEnabled = installed && snapshot != nil && !busy && !ready && !sessionBusy
        stopButton.isEnabled = installed && (running || sessionBusy || startTask != nil) && stopTask == nil && !choosingFolder
        captureButton.isEnabled = installed && snapshot != nil && !busy && !sessionBusy
        endButton.isEnabled = (session.phase == .running || session.phase == .starting) && stopTask == nil
        for popup in [inputPopup, outputPopup, sourcePopup, targetPopup] { popup.isEnabled = !busy && !sessionBusy }
        termsField.isEnabled = !busy && !sessionBusy; devicesButton.isEnabled = !busy && !sessionBusy
        pageButton.isEnabled = ready; listenerButton.isEnabled = ready && snapshot?.listener_url != nil
        copyButton.isEnabled = snapshot?.listener_url != nil
        folderButton.isEnabled = !busy && !running && !sessionBusy && (snapshot != nil || !installed)
        startMenu.isEnabled = startButton.isEnabled; stopMenu.isEnabled = stopButton.isEnabled; captureMenu.isEnabled = captureButton.isEnabled
        sessionLabel.stringValue = session.message
        sessionLabel.textColor = session.phase == .running ? .systemGreen : session.phase == .failed ? .systemRed : .labelColor
        meter.doubleValue = Double(min(1, session.level * 3))
        let pair = sessionBusy ? session.languagePair : preferences.languagePair
        let showTranscript = pair == session.languagePair
        ttsLabel.stringValue = session.isActive ? String(format: "\(pair.targetName)朗读待输出 %.1f 秒 · 合成语速 %.2f× · 音频连接 %d", session.backlogSeconds, session.speed, session.listenerCount) : "识别\(pair.sourceName) → 翻译并朗读\(pair.targetName) · 开始前可切换方向"
        sourceLabel.stringValue = !showTranscript || session.sourceText.isEmpty ? "\(pair.sourceName)原文将在这里显示" : session.sourceText
        let displayedTranslation = session.subtitleFollowsPlayback ? session.subtitleText : session.translationText
        translationLabel.stringValue = !showTranscript || displayedTranslation.isEmpty ? "等待\(pair.targetName)\(session.subtitleFollowsPlayback ? "朗读字幕" : "译文")" : displayedTranslation
        addressLabel.stringValue = snapshot?.listener_url ?? snapshot?.lan_error ?? "连接局域网后自动显示地址"
        if lastQR != snapshot?.listener_url { lastQR = snapshot?.listener_url; updateQR(lastQR) }
        let error = lastError ?? session.lastError ?? snapshot?.service_error ?? session.ttsWarning
        detailLabel.stringValue = error.map { String($0.prefix(300)) } ?? "关闭窗口后传译继续运行，可从菜单栏返回。“停止服务并退出”会结束采集并释放模型。"
        detailLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed; detailLabel.toolTip = error
        statusItem.button?.toolTip = "同声传译 · " + (sessionBusy ? session.message : stateLabel.stringValue)
    }

    private func updateQR(_ address: String?) {
        guard let address, let filter = CIFilter(name: "CIQRCodeGenerator") else { qrView.image = nil; return }
        filter.setValue(Data(address.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)) else { return }
        let representation = NSCIImageRep(ciImage: image), result = NSImage(size: representation.size)
        result.addRepresentation(representation); qrView.image = result
    }

    private func serviceText(_ name: String) -> String {
        guard let value = snapshot?.services[name] else { return "等待检查" }
        return value.ready ? "已就绪" : value.pid == nil ? "已停止" : "加载中"
    }

    @objc private func showSubtitleSettings() { subtitleSettings.show() }
    @objc private func toggleSubtitles() {
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

    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func openOperator() { openWeb("http://127.0.0.1:8024") }
    @objc private func openListener() { if let address = snapshot?.listener_url { openWeb(address) } }
    private func openWeb(_ address: String) { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
    @objc private func copyListener() {
        guard let address = snapshot?.listener_url else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
    }
    @objc private func openLogs() { if let client { NSWorkspace.shared.open(client.root.appendingPathComponent("logs", isDirectory: true)) } }

    @objc private func chooseFolder() {
        guard operation == nil, !choosingFolder, snapshot?.hasProcess != true, !session.isActive,
              snapshot != nil || client?.isInstalled != true else { return }
        choosingFolder = true; let originalClient = client; render()
        let panel = NSOpenPanel(); panel.title = "选择 VoxBridge 服务文件夹"
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

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
