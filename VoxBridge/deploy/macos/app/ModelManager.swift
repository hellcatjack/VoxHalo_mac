import Foundation

@MainActor final class ModelManager {
    enum State { case idle, validating, repairing, cancelling, ready, paused, failed }
    let inventory: ModelInventory
    let resources: URL
    private(set) var files: [ModelFile] = []
    private(set) var state: State = .idle
    private(set) var scanning = false
    private(set) var verifying = false
    private(set) var checkingFile: String?
    private(set) var event: DesktopInstallEvent?
    private(set) var details = ""
    private(set) var message = "模型文件保存在本机，下载完成后可离线使用。"
    var repairAvailable = false
    var initialInstallationRequired = false
    var externalBusy = false
    var externalEvent: DesktopInstallEvent?
    var onChange: (() -> Void)?
    var onActivityChange: (() -> Void)?
    var onWillRepair: ((@escaping (Bool) -> Void) -> Void)?
    var onSettled: (() -> Void)?
    private var worker: DesktopInstallWorker?
    private var validationID: UUID?
    private var pendingVerification = false
    private let scanQueue = DispatchQueue(label: "org.pccs.voxbridge.models.inventory", qos: .utility)
    var isRepairing: Bool { [.validating, .repairing, .cancelling].contains(state) }
    var isBusy: Bool { verifying || pendingVerification || isRepairing || externalBusy }
    var activeEvent: DesktopInstallEvent? { externalBusy ? externalEvent : isRepairing ? event : nil }

    init(workspace: URL, resources: URL) throws {
        self.resources = resources
        inventory = try ModelInventory(workspace: workspace, manifest: resources.appendingPathComponent("model-tools/runtime-assets.json"))
    }
    func refresh(verify: Bool = false) {
        guard !scanning else { pendingVerification = pendingVerification || verify; return }
        scanning = true; verifying = verify; onChange?()
        let inventory = self.inventory
        scanQueue.async { [weak self] in
            let result = inventory.scan(verify: verify) { path in
                Task { @MainActor [weak self] in self?.checkingFile = path; self?.onChange?() }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.files = result; self.scanning = false; self.verifying = false; self.checkingFile = nil; self.onChange?()
                if self.pendingVerification { self.pendingVerification = false; self.refresh(verify: true) }
            }
        }
    }
    func repair(paths: [String]?) {
        guard repairAvailable, !isBusy else { return }
        let id = UUID(); validationID = id; state = .validating; event = nil
        message = "正在检查服务状态…"; onChange?(); onActivityChange?()
        let proceed: (Bool) -> Void = { [weak self] allowed in
            guard let self, self.validationID == id else { return }
            self.validationID = nil
            guard allowed else {
                self.state = .failed; self.message = "请先结束传译并停止服务，再下载或修复模型。"
                self.onChange?(); self.onActivityChange?(); self.notifySettled(); return
            }
            self.beginRepair(paths: paths)
        }
        // Mutations are always gated by the native service owner.
        if let onWillRepair { onWillRepair(proceed) } else { proceed(false) }
    }
    private func beginRepair(paths: [String]?) {
        state = .repairing; details = ""; message = "正在下载或修复模型…"
        let running = DesktopInstallWorker(); worker = running
        running.onLine = { [weak self] line in Task { @MainActor [weak self] in self?.receive(line) } }
        let root = inventory.workspace
        let script = resources.appendingPathComponent("model-tools/model_manager.py")
        var arguments = ["-B", "-u", script.path, "--root", root.path]
        for path in paths ?? [] { arguments += ["--asset", path] }
        onChange?(); onActivityChange?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { _ = try running.run(root.appendingPathComponent(".venv/bin/python"), arguments,
                                                      directory: root.appendingPathComponent("VoxBridge"), emitLines: true) }
            Task { @MainActor [weak self] in self?.finished(result) }
        }
    }
    private func receive(_ line: String) {
        guard isRepairing else { return }
        if let parsed = try? JSONDecoder().decode(DesktopInstallEvent.self, from: Data(line.utf8)) { event = parsed }
        details += line + "\n"
        if details.count > 60_000 { details = String(details.suffix(50_000)) }
        onChange?()
    }
    private func finished(_ result: Result<Void, Error>) {
        worker = nil
        switch result {
        case .success: state = .ready; message = "所选模型文件已校验并恢复。"
        case .failure(let error):
            if case DesktopInstallError.cancelled = error {
                state = .paused; message = "下载已暂停，已完成和部分下载的文件均已保留。"
            } else {
                state = .failed; message = "下载或修复未完成，请查看详情后重试。"
                details += error.localizedDescription + "\n"
            }
        }
        event = nil; onChange?(); onActivityChange?(); notifySettled(); refresh(verify: state == .ready)
    }
    private func notifySettled() {
        let completion = onSettled; onSettled = nil; completion?()
    }
    func cancel() {
        if validationID != nil {
            validationID = nil; state = .paused; message = "下载已暂停，已完成和部分下载的文件均已保留。"
            onChange?(); onActivityChange?(); notifySettled()
        } else if isRepairing {
            state = .cancelling; message = "正在暂停下载…"; worker?.cancel(); onChange?()
        }
    }
}
