import AppKit

@MainActor final class InstallationWindow: NSObject, NSWindowDelegate {
    let installation: DesktopInstallation
    private var window: NSWindow!
    private let localizedViews = NativeLocalizedViews()
    private let language = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progressText = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let accept = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let eligible = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var install: NSButton!
    private var cancel: NSButton!
    private var detailsButton: NSButton!
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var content: NSStackView!
    private let sizeLabel = NSTextField(wrappingLabelWithString: "")
    var onLanguageChange: (() -> Void)?
    var onWillStart: ((@escaping (Bool) -> Void) -> Void)?
    var onClosed: (() -> Void)?
    private var validationID: UUID?
    private var startError: String?

    init(installation: DesktopInstallation) {
        self.installation = installation; super.init(); build()
        installation.onChange = { [weak self] in self?.render() }
        render()
    }
    private func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = spacing; return stack
    }
    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal
        stack.alignment = .centerY; stack.spacing = spacing; return stack
    }
    private func label(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text)
        value.font = .systemFont(ofSize: size); value.textColor = secondary ? .secondaryLabelColor : .labelColor
        return value
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        return value
    }
    private func consentRow(_ checkbox: NSButton, text: String) -> NSStackView {
        checkbox.target = self; checkbox.action = #selector(consentChanged)
        checkbox.setAccessibilityLabel(text)
        let caption = label(text)
        let stack = row([checkbox, caption], spacing: 7); stack.alignment = .top
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }
    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = InstallationDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; window.contentView!.addSubview(scroll)
        content = column([], spacing: 16); content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ])
        func append(_ view: NSView) {
            content.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let title = label("准备本机模型", size: 22); title.font = .systemFont(ofSize: 22, weight: .semibold)
        language.addItem(withTitle: "Auto"); language.lastItem?.representedObject = "auto"
        for (code, name) in zip(NativeLocalization.codes, NativeLocalization.autonyms) {
            language.addItem(withTitle: name); language.lastItem?.representedObject = code
        }
        language.select(language.itemArray.first { $0.representedObject as? String == NativeLocalization.preference() })
        language.target = self; language.action = #selector(languageChanged)
        language.widthAnchor.constraint(equalToConstant: 150).isActive = true
        append(row([title, NSView(), language], spacing: 16))
        sizeLabel.font = .systemFont(ofSize: 13)
        append(sizeLabel)
        append(label("需要 Apple Silicon、macOS 14.2+、16 GB 内存和至少 20 GB 可用磁盘空间。", secondary: true))
        let models = label("Qwen3-ASR · HY-MT · Kokoro", size: 12, secondary: true)
        append(models)

        let licenses = column([
            label("安装仅在下载时需要联网。之后的识别、翻译和朗读均在本机运行。", secondary: true),
            row([button("HY-MT 许可证", #selector(openHYLicense)), button("全部许可证", #selector(openLicenses))]),
            consentRow(accept, text: "我已阅读并接受所包含模型与组件的许可证。"),
            consentRow(eligible, text: "我确认符合 HY-MT 地区许可要求：不在欧盟、英国或韩国使用本模型。")
        ], spacing: 11)
        for view in licenses.arrangedSubviews { view.widthAnchor.constraint(equalTo: licenses.widthAnchor).isActive = true }
        append(licenses)
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.setAccessibilityLabel("安装状态")
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progress.setAccessibilityLabel("安装进度")
        progressText.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressText.textColor = .secondaryLabelColor
        let activity = column([status, progress, progressText], spacing: 7)
        for view in activity.arrangedSubviews { view.widthAnchor.constraint(equalTo: activity.widthAnchor).isActive = true }
        append(activity)
        install = button("同意并安装", #selector(start)); install.keyEquivalent = "\r"
        cancel = button("取消安装", #selector(cancelInstallation))
        detailsButton = button("安装详情", #selector(toggleDetails))
        append(row([detailsButton, NSView(), cancel, install], spacing: 10))
        logView.isEditable = false; logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textContainerInset = NSSize(width: 7, height: 7)
        logView.autoresizingMask = [.width]; logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false; logView.textContainer?.widthTracksTextView = true
        logScroll.documentView = logView; logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder; logScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        append(logScroll); logScroll.isHidden = true
        append(row([button("显示本机数据", #selector(revealData)), button("打开安装日志", #selector(openLog))]))
        localizedViews.capture(content, excluding: [language, sizeLabel, status, progressText, install, cancel, detailsButton, logView])
    }
    func show() {
        render(); fitWindow(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func close() { window.close() }
    private func fitWindow() {
        window.contentView?.layoutSubtreeIfNeeded()
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        window.setContentSize(NSSize(width: 680, height: min(content.fittingSize.height + 44, available - 65)))
    }
    private func render() {
        localizedViews.apply()
        window.title = NativeLocalization.text("安装本机模型")
        language.item(at: 0)?.title = NativeLocalization.text("跟随系统")
        language.setAccessibilityLabel(NativeLocalization.text("界面语言"))
        let size = ByteCountFormatter.string(fromByteCount: installation.metadata?.modelBytes ?? 4_600_000_000, countStyle: .file)
        sizeLabel.stringValue = NativeLocalization.text("下载约 {0} 模型，安装后可离线传译。", size)
        let busy = installation.isRunning || validationID != nil
        let phases = ["checking": "正在检查安装条件…", "downloading": "正在下载本机模型…", "verifying": "正在校验下载文件…",
                      "preparing": "正在准备本机运行环境…", "ready": "本机模型已就绪。", "error": "安装未完成。请查看安装详情后重试。"]
        let cancelling = installation.message == "正在取消安装…"
        status.stringValue = NativeLocalization.render(busy && !cancelling ? phases[installation.phase] ?? "正在准备本机运行环境…" : installation.message)
        if validationID != nil { status.stringValue = NativeLocalization.text("正在检查服务状态…") }
        else if let startError { status.stringValue = NativeLocalization.text(startError) }
        status.setAccessibilityLabel(NativeLocalization.text("安装状态"))
        status.textColor = installation.state == .failed ? .systemRed : .labelColor
        if busy, let event = installation.event, let total = event.totalBytes, total > 0, let completed = event.completedBytes {
            progress.isIndeterminate = false; progress.stopAnimation(nil)
            progress.doubleValue = min(1, max(0, Double(completed) / Double(total)))
            progressText.stringValue = (event.asset.map { $0 + " · " } ?? "")
                + ByteCountFormatter.string(fromByteCount: completed, countStyle: .file) + " / "
                + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        } else {
            progress.isIndeterminate = busy
            if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil); progress.doubleValue = installation.isReady ? 1 : 0 }
            progressText.stringValue = busy ? installation.event?.asset ?? "" : NativeLocalization.text("下载中断后可重试，已下载的数据会保留。")
        }
        let action = installation.needsRepair ? "保留损坏文件并重新下载" : installation.isReady ? "检查模型" :
            installation.state == .cancelled || installation.state == .failed ? "重试安装" : "同意并安装"
        install.title = NativeLocalization.text(action)
        install.isEnabled = !busy && installation.metadata != nil && accept.state == .on && eligible.state == .on
        accept.isEnabled = !busy; eligible.isEnabled = !busy
        cancel.title = NativeLocalization.text("取消安装"); cancel.isEnabled = busy && !cancelling
        detailsButton.title = NativeLocalization.text(logScroll.isHidden ? "安装详情" : "收起详情")
        if !logScroll.isHidden { logView.string = installation.details; logView.scrollToEndOfDocument(nil) }
    }
    @objc private func consentChanged() { render() }
    @objc private func start() {
        guard validationID == nil else { return }
        let id = UUID(); validationID = id; startError = nil; render()
        let proceed: (Bool) -> Void = { [weak self] allowed in
            guard let self, self.validationID == id else { return }
            self.validationID = nil
            if allowed {
                self.installation.start(acceptedLicenses: self.accept.state == .on, territoryEligible: self.eligible.state == .on,
                                        repairCorrupt: self.installation.needsRepair)
            } else { self.startError = "请先结束传译并停止服务，再检查模型。" }
            self.render()
        }
        if let onWillStart { onWillStart(proceed) } else { proceed(true) }
    }
    @objc private func cancelInstallation() {
        if validationID != nil { validationID = nil; render() }
        else { installation.cancel() }
    }
    @objc private func languageChanged() {
        NativeLocalization.save(language.selectedItem?.representedObject as? String ?? "auto")
        render(); fitWindow(); onLanguageChange?()
    }
    @objc private func toggleDetails() { logScroll.isHidden.toggle(); render(); fitWindow() }
    @objc private func openHYLicense() {
        NSWorkspace.shared.open(installation.resources.appendingPathComponent("licenses/HY-MT-LICENSE.txt"))
    }
    @objc private func openLicenses() { NSWorkspace.shared.open(installation.resources.appendingPathComponent("licenses", isDirectory: true)) }
    @objc private func revealData() { NSWorkspace.shared.activateFileViewerSelecting([installation.dataHome]) }
    @objc private func openLog() {
        if !installation.isRunning && FileManager.default.fileExists(atPath: installation.logURL.path) { NSWorkspace.shared.open(installation.logURL) }
        else { logScroll.isHidden = false; render(); fitWindow() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { validationID = nil; installation.cancel(); return true }
    func windowWillClose(_ notification: Notification) { onClosed?() }
}

private final class InstallationDocumentView: NSView {
    override var isFlipped: Bool { true }
}
