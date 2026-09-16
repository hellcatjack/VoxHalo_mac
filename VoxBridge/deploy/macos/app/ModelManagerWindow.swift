import AppKit

@MainActor final class ModelManagerWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let manager: ModelManager
    private var window: NSWindow!
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let location = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let activity = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let log = NSTextView()
    private let logScroll = NSScrollView()
    private let localized = NativeLocalizedViews()
    private var refreshButton: NSButton!, verifyButton: NSButton!, selectedButton: NSButton!, allButton: NSButton!, pauseButton: NSButton!
    private var revealButton: NSButton!, sourceButton: NSButton!
    private var timer: Timer?
    private var previousRows: [String] = []
    var onRefreshContext: (() -> Void)?

    init(manager: ModelManager) {
        self.manager = manager; super.init(); build()
        manager.onChange = { [weak self] in self?.render() }
        render()
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action); value.bezelStyle = .rounded
        value.setContentCompressionResistancePriority(.required, for: .horizontal); return value
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY; return stack
    }
    private func build() {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(900, available.width - 40), height: min(730, available.height - 70)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 720, height: 600)
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)
        ])
        func append(_ view: NSView) { content.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let title = NSTextField(labelWithString: "本机模型与下载"); title.font = .systemFont(ofSize: 21, weight: .semibold)
        append(title)
        let description = NSTextField(wrappingLabelWithString: "Qwen3-ASR 0.6B（本机 INT8）· HY-MT1.5 1.8B Q8_0 · Kokoro · Silero VAD")
        description.font = .systemFont(ofSize: 12); description.textColor = .secondaryLabelColor; append(description)
        summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); append(summary)
        location.font = .systemFont(ofSize: 11); location.textColor = .secondaryLabelColor
        location.isSelectable = true; location.maximumNumberOfLines = 2; append(location)
        refreshButton = button("刷新状态", action: #selector(refreshFiles))
        verifyButton = button("校验完整性", action: #selector(verifyFiles))
        append(row([refreshButton, verifyButton, NSView(), button("打开模型文件夹", action: #selector(revealModels))]))
        for (id, title, width) in [("file", "模型／文件", 420.0), ("size", "已保存／大小", 155.0), ("state", "文件状态", 205.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            column.minWidth = id == "file" ? 240 : 115; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 43; table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = true; table.style = .inset; table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("模型文件下载状态")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.hasHorizontalScroller = true
        list.borderType = .bezelBorder; list.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        list.setContentHuggingPriority(.defaultLow, for: .vertical); append(list)
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular); detail.isSelectable = true
        detail.maximumNumberOfLines = 5; detail.setContentCompressionResistancePriority(.required, for: .vertical); append(detail)
        revealButton = button("在 Finder 中显示", action: #selector(revealSelected))
        sourceButton = button("打开下载来源", action: #selector(openSource))
        selectedButton = button("下载／修复所选文件", action: #selector(repairSelected))
        append(row([revealButton, sourceButton, NSView(), selectedButton]))
        status.font = .systemFont(ofSize: 12, weight: .medium); status.maximumNumberOfLines = 2; append(status)
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progress.setAccessibilityLabel("模型下载进度"); append(progress)
        activity.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); activity.textColor = .secondaryLabelColor
        activity.maximumNumberOfLines = 2; append(activity)
        allButton = button("补齐／修复全部模型", action: #selector(repairAll))
        pauseButton = button("暂停下载", action: #selector(pause))
        append(row([button("下载详情", action: #selector(showDetails)), NSView(), pauseButton, allButton]))
        log.isEditable = false; log.isSelectable = true; log.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        log.autoresizingMask = [.width]; log.textContainer?.widthTracksTextView = true
        logScroll.documentView = log; logScroll.hasVerticalScroller = true; logScroll.borderType = .bezelBorder
        logScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true; append(logScroll); logScroll.isHidden = true
        localized.capture(content, excluding: [summary, location, detail, status, activity, table, log])
    }
    func show() {
        onRefreshContext?()
        render(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        manager.refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onRefreshContext?(); self?.manager.refresh() }
            }
        }
    }
    func refreshLocalization() { render() }
    func close() { window.close() }
    private var selected: ModelFile? { manager.files.indices.contains(table.selectedRow) ? manager.files[table.selectedRow] : nil }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func stateText(_ file: ModelFile) -> String {
        if let event = manager.activeEvent, event.asset == file.asset.path {
            if event.phase == "downloading" { return NativeLocalization.text("正在下载…") }
            if event.phase == "verifying" { return NativeLocalization.text("正在校验…") }
            if event.phase == "preparing" { return NativeLocalization.text("正在本机生成…") }
            if event.phase == "asset_ready" { return NativeLocalization.text("已校验") }
        }
        let names: [ModelFileState: String] = [.missing: "文件缺失", .partial: "部分下载，可继续", .saved: "已保存，未校验",
            .verified: "已校验", .corrupt: "文件损坏，可修复", .unavailable: "无法访问"]
        return NativeLocalization.text(names[file.state]!)
    }
    func render() {
        guard window != nil else { return }
        localized.apply(); window.title = NativeLocalization.text("模型管理")
        for (index, title) in ["模型／文件", "已保存／大小", "文件状态"].enumerated() { table.tableColumns[index].title = NativeLocalization.text(title) }
        table.setAccessibilityLabel(NativeLocalization.text("模型文件下载状态"))
        progress.setAccessibilityLabel(NativeLocalization.text("模型下载进度"))
        let stored = manager.files.reduce(Int64(0)) { $0 + $1.storedBytes }
        let expected = manager.inventory.assets.reduce(Int64(0)) { $0 + ($1.expectedBytes ?? 0) }
        let incomplete = manager.files.filter { [.missing, .partial, .corrupt, .unavailable].contains($0.state) }.count
        summary.stringValue = NativeLocalization.text("已保存 {0} / {1} · {2} 个文件 · {3} 个需处理", bytes(stored), bytes(expected), String(manager.files.count), String(incomplete))
        location.stringValue = NativeLocalization.text("模型保存位置：{0}", manager.inventory.modelDirectory.path)
        let rows = manager.files.map { "\($0.url.path)|\($0.storedBytes)|\($0.partialBytes)|\(stateText($0))|\(NativeLocalization.locale)" }
        if rows != previousRows {
            let index = max(0, table.selectedRow); previousRows = rows; table.reloadData()
            if !manager.files.isEmpty { table.selectRowIndexes(IndexSet(integer: min(index, manager.files.count - 1)), byExtendingSelection: false) }
        }
        renderSelection()
        let canRepair = manager.repairAvailable && !manager.isBusy
        allButton.isEnabled = canRepair && !manager.files.isEmpty
        pauseButton.isEnabled = manager.isRepairing && manager.state != .cancelling
        refreshButton.isEnabled = !manager.verifying; verifyButton.isEnabled = !manager.isBusy
        let event = manager.activeEvent
        let working = manager.isRepairing || manager.externalBusy || manager.verifying
        status.stringValue = NativeLocalization.text(manager.verifying ? "正在校验模型文件…" : manager.message)
        if manager.externalBusy { status.stringValue = NativeLocalization.text("首次安装正在进行，文件状态会自动更新。") }
        else if !manager.repairAvailable && !manager.isRepairing {
            status.stringValue = NativeLocalization.text(manager.initialInstallationRequired ? "请先在安装窗口完成首次模型安装。" : "可随时查看文件；请先结束传译并停止服务，再下载或修复。")
        }
        status.textColor = manager.state == .failed ? .systemRed : .labelColor
        if working, let event, let total = event.totalBytes, total > 0, let complete = event.completedBytes {
            let fraction = min(1, max(0, Double(complete) / Double(total)))
            progress.isIndeterminate = false; progress.stopAnimation(nil); progress.doubleValue = fraction
            activity.stringValue = (event.asset ?? "") + " · " + bytes(complete) + " / " + bytes(total) + String(format: " · %.1f%%", fraction * 100)
        } else {
            progress.isIndeterminate = working
            if working { progress.startAnimation(nil) } else { progress.stopAnimation(nil); progress.doubleValue = incomplete == 0 && !manager.files.isEmpty ? 1 : 0 }
            activity.stringValue = manager.checkingFile ?? event?.asset ?? NativeLocalization.text("有效文件会保留；损坏文件先备份再修复。关闭此窗口不暂停下载。")
        }
        if !logScroll.isHidden { log.string = manager.details; log.scrollToEndOfDocument(nil) }
    }
    private func renderSelection() {
        guard let file = selected else {
            detail.stringValue = NativeLocalization.text("选择文件查看保存位置、下载来源与校验值。")
            revealButton.isEnabled = false; sourceButton.isEnabled = false; selectedButton.isEnabled = false; return
        }
        detail.stringValue = NativeLocalization.text("保存位置：{0}\n下载来源：{1}\nSHA-256：{2}", file.url.path,
            file.asset.url ?? NativeLocalization.text("由已校验的中文原始模型在本机生成"), file.asset.sha256)
        detail.toolTip = detail.stringValue
        revealButton.isEnabled = true; sourceButton.isEnabled = file.asset.url != nil
        selectedButton.isEnabled = manager.repairAvailable && !manager.isBusy && file.state != .unavailable
    }
    func numberOfRows(in tableView: NSTableView) -> Int { manager.files.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard manager.files.indices.contains(row), let column else { return nil }
        let file = manager.files[row], identifier = column.identifier
        let label = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        label.identifier = identifier; label.font = .systemFont(ofSize: 11); label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        switch identifier.rawValue {
        case "file": label.stringValue = NativeLocalization.render(file.asset.modelName) + "\n" + file.url.lastPathComponent
        case "size": label.stringValue = bytes(file.storedBytes > 0 ? file.storedBytes : file.partialBytes) + " / " + (file.asset.expectedBytes.map(bytes) ?? "—")
        default: label.stringValue = stateText(file)
        }
        label.textColor = identifier.rawValue == "state" && [.corrupt, .unavailable, .missing].contains(file.state) ? .systemOrange : .labelColor
        label.toolTip = file.detail ?? file.url.path; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { renderSelection() }
    @objc private func refreshFiles() { manager.refresh() }
    @objc private func verifyFiles() { manager.refresh(verify: true) }
    @objc private func repairSelected() { if let selected { manager.repair(paths: [selected.asset.path]) } }
    @objc private func repairAll() { manager.repair(paths: nil) }
    @objc private func pause() { manager.cancel() }
    private func reveal(_ requested: URL) {
        var url = requested
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func revealSelected() { if let selected { reveal(selected.url) } }
    @objc private func revealModels() { reveal(manager.inventory.modelDirectory) }
    @objc private func openSource() {
        if let source = selected?.asset.url, let url = URL(string: source), url.scheme == "https" { NSWorkspace.shared.open(url) }
    }
    @objc private func showDetails() { logScroll.isHidden.toggle(); render() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}
