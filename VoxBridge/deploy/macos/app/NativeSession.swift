import Foundation
import AVFoundation

@MainActor protocol NativeAudioSource: AnyObject {
    var onPCM: ((Data) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start(inputUID: String) async throws
    func stop() async
}

extension AudioCapture: NativeAudioSource {}

private final class NativeWebSocketDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let completion: @Sendable (URLSessionTask, Error?) -> Void
    init(completion: @escaping @Sendable (URLSessionTask, Error?) -> Void) { self.completion = completion }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Foundation can report completion here before resuming async send/receive.
        completion(task, error)
    }
}

enum HLSPlaybackBootstrap {
    static func isReady(_ playlist: String) -> Bool {
        var target: Double = 0, duration: Double = 0
        for line in playlist.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else { return false }
                duration += seconds
            }
        }
        return target.isFinite && target > 0 && duration >= 3 * target
    }
}

/// Move only inside a publisher-confirmed carrier gap, retaining natural pauses.
enum HLSPlaybackGap {
    struct Cue: Decodable {
        let id: String
        let start: Double
        let end: Double
        let discardable: Double
        let resume: Double?
        var text: String? = nil
        enum CodingKeys: String, CodingKey {
            case id = "cue_id", start = "start_at_ms", end = "end_at_ms"
            case discardable = "discardable_gap_before_ms", resume = "resume_at_ms", text
        }
    }
    struct Snapshot: Decodable { let cues: [Cue] }
    struct Target {
        let cueID: String
        let mediaTime: Double
        let skippedSeconds: Double
        let nextSpeechMs: Double
    }
    static func target(cues: [Cue], playheadMs: Double, mediaTime: Double,
                       seekable: [ClosedRange<Double>]) -> Target? {
        guard playheadMs.isFinite, mediaTime.isFinite,
              cues.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }),
              zip(cues, cues.dropFirst()).allSatisfy({ $0.end <= $1.start }),
              let nextIndex = cues.firstIndex(where: { $0.start > playheadMs }), nextIndex > 0 else { return nil }
        let previous = cues[nextIndex - 1], next = cues[nextIndex]
        guard let resume = next.resume,
              [previous.start, previous.end, next.start, next.end, next.discardable, resume].allSatisfy(\.isFinite),
              previous.end > previous.start, next.end > next.start, !next.id.isEmpty,
              next.discardable >= 500, resume >= previous.end, resume <= next.start,
              abs(resume - previous.end - next.discardable) <= 1,
              playheadMs >= previous.end, playheadMs < next.start else { return nil }
        let naturalPause = next.start - resume
        let remainingPause = max(0, naturalPause - (playheadMs - previous.end))
        // Exact AAC seeks retain 250ms of decoded lead-in before the next voice.
        let targetMs = max(previous.end, min(next.start - remainingPause, next.start - 250))
        let skippedSeconds = (targetMs - playheadMs) / 1000
        let target = mediaTime + skippedSeconds
        let guardTime = mediaTime + (next.start + 100 - playheadMs) / 1000
        guard skippedSeconds >= 0.5, target.isFinite, guardTime.isFinite,
              seekable.contains(where: { $0.contains(target) && $0.contains(guardTime) }) else { return nil }
        return Target(cueID: next.id, mediaTime: target, skippedSeconds: skippedSeconds, nextSpeechMs: next.start)
    }
}

@MainActor final class NativeSession {
    enum Phase: String { case idle, starting, running, stopping, failed }
    private(set) var phase: Phase = .idle
    private(set) var message = "选择音频设备后开始传译"
    private(set) var lastError: String?
    private(set) var sourceText = ""
    private(set) var translationText = ""
    private var subtitleState = CompletedSubtitleState()
    private var playbackSubtitle: SubtitlePlayback.Caption?
    var subtitleFollowsPlayback: Bool { preferences.outputUID != "none" }
    var subtitleText: String { subtitleFollowsPlayback ? (playbackSubtitle?.text ?? "") : subtitleState.text }
    var subtitleIdentity: CompletedSubtitleState.Identity? { subtitleFollowsPlayback ? playbackSubtitle?.identity : subtitleState.identity }
    var languagePair: NativeTranslationDirection { preferences.languagePair }
    private(set) var level: Float = 0
    private(set) var backlogSeconds: Double = 0
    private(set) var speed: Double = 1.05
    private(set) var listenerCount = 0
    private(set) var ttsWarning: String?
    var playbackTime: Double { speechPlayer.map { Double($0.renderedFrame) / 24000 } ?? player?.currentTime().seconds ?? 0 }
    #if NATIVE_PLAYBACK_TESTING
    var onPlaybackPCM: ((NativeSpeechChunk) -> Void)?
    var playbackDiagnostics: [String: Any] {
        if let speechPlayer {
            return ["mode": "pcm", "media_time": playbackTime, "listener": localListener ?? "",
                    "epoch": speechPlayer.epoch, "received_seq": speechPlayer.receivedSequence,
                    "played_seq": speechPlayer.playedSequence, "buffered_ms": speechPlayer.bufferedMilliseconds,
                    "rendered_frame": speechPlayer.renderedFrame, "subtitle_presented_frame": speechPlayer.subtitlePresentedFrame ?? -1, "pcm_chunks": speechPlayer.scheduledChunks,
                    "rate": speechPlayer.isPlaying ? 1 : 0, "waiting": ""]
        }
        var result: [String: Any] = ["media_time": playbackTime, "listener": localListener ?? "",
                                    "rate": player?.rate ?? 0,
                                    "waiting": player?.reasonForWaitingToPlay?.rawValue ?? ""]
        if let date = player?.currentItem?.currentDate() { result["program_ms"] = date.timeIntervalSince1970 * 1000 }
        result["seekable"] = player?.currentItem?.seekableTimeRanges.map {
            [$0.timeRangeValue.start.seconds, CMTimeRangeGetEnd($0.timeRangeValue).seconds]
        } ?? []
        result["loaded"] = player?.currentItem?.loadedTimeRanges.map {
            [$0.timeRangeValue.start.seconds, CMTimeRangeGetEnd($0.timeRangeValue).seconds]
        } ?? []
        result["gap_events"] = playbackGapEvents
        result["gap_seek_count"] = gapSeekCount
        result["gap_skipped_seconds"] = gapSkippedSeconds
        return result
    }
    private var playbackGapEvents: [[String: Any]] = []
    #endif
    var onChange: (() -> Void)?
    var isActive: Bool { phase == .starting || phase == .running || phase == .stopping }

    private let capture: NativeAudioSource
    private let inputDevices: () throws -> [AudioDevice]
    private let outputDevices: () throws -> [AudioDevice]
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private let http: URLSession
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var subtitleClock: Task<Void, Never>?
    private var subtitleHLSCues: [HLSPlaybackGap.Cue] = []
    private var gapMaintenance: Task<Void, Never>?
    private var pcm = NativePCMQueue()
    private var acceptingAudio = false
    private var generation = UUID()
    private var finalReceived = false
    private var localListener: String?
    private var player: AVPlayer?
    private var speechPlayer: NativeSpeechPlayer?
    private var speechTransport: Task<Void, Never>?
    private var nativePCMMode = false
    private var controlToken = ""
    private var playerObservation: NSKeyValueObservation?
    private var preferences = NativePreferences()
    private var lastLeaseRefresh = Date.distantPast
    private var lastDeviceCheck = Date.distantPast
    private var statusFailures = 0
    private var playbackStarted = false
    private var playbackLastProgress = Date()
    private var playbackLastTime: Double = 0
    private var gapSeekInFlight = false
    private var gapSeekCount = 0
    private var gapSkippedSeconds: Double = 0
    private let base = URL(string: "http://127.0.0.1:8024")!

    init(capture: NativeAudioSource? = nil,
         inputDevices: @escaping () throws -> [AudioDevice] = AudioDevices.inputs,
         outputDevices: @escaping () throws -> [AudioDevice] = AudioDevices.outputs) {
        self.capture = capture ?? AudioCapture()
        self.inputDevices = inputDevices; self.outputDevices = outputDevices
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        http = URLSession(configuration: configuration)
    }

    func start(preferences: NativePreferences, root: URL) async throws {
        guard !isActive else { return }
        let selected = try preferences.validated()
        if try selected.outputUID != "default" && selected.outputUID != "none" &&
            !outputDevices().contains(where: { $0.uid == selected.outputUID }) {
            throw ServiceError.message("所选输出设备已断开，请重新选择。")
        }
        let tokenURL = root.appendingPathComponent("artifacts/macos-service/native-control-token")
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32 else { throw ServiceError.message("本机控制凭据无效，请重新启动服务。") }
        controlToken = token
        let run = UUID(); generation = run
        preferencesDidChange(selected)
        phase = .starting; message = "正在连接本机识别服务…"; lastError = nil
        finalReceived = false; pcm.reset(); subtitleState.reset(); playbackSubtitle = nil; subtitleHLSCues = []; sourceText = ""; translationText = ""; ttsWarning = nil
        onChange?()
        do {
            // A live socket must not inherit the 60-second HTTP resource limit.
            // Keep Foundation's multi-day resource lifetime and retire this session
            // on every stop, so a failed transport cannot poison the next run.
            let socketConfiguration = URLSessionConfiguration.ephemeral
            let delegate = NativeWebSocketDelegate { [weak self] task, error in
                Task { @MainActor in
                    guard let self, self.generation == run, self.socket === task,
                          self.phase == .running || self.phase == .starting else { return }
                    let message = error?.localizedDescription ?? "服务已关闭语音连接。"
                    NSLog("Native interpretation socket completed: %@", message)
                    self.fail("本机识别连接中断：\(message)", run: run)
                }
            }
            let transport = URLSession(configuration: socketConfiguration, delegate: delegate, delegateQueue: nil)
            socketSession = transport
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:8024/ws")!, timeoutInterval: 15)
            request.setValue(token, forHTTPHeaderField: "X-VoxBridge-Control-Token")
            let ws = transport.webSocketTask(with: request); ws.maximumMessageSize = 4 * 1024 * 1024
            socket = ws; ws.resume()
            let ready = try await receive(ws)
            guard ready["type"] as? String == "ready" else {
                throw ServiceError.message(ready["message"] as? String ?? "识别服务没有就绪。")
            }
            try requireCurrent(run)
            let listener = "native-" + UUID().uuidString.lowercased()
            localListener = listener
            let capabilityData = try await requestData("/api/monitor/state")
            let capabilities = try JSONSerialization.jsonObject(with: capabilityData) as? [String: Any]
            nativePCMMode = capabilities?["native_pcm"] as? Bool == true
            if nativePCMMode {
                _ = try await nativeSpeechSnapshot(listener: listener, after: -1, run: run)
                try requireCurrent(run)
            } else {
                let playlist = try await playbackPlaylist(listener: listener, run: run)
                try requireCurrent(run)
                if selected.outputUID != "none" {
                    try await waitForPlaybackBootstrap(listener: listener, initial: playlist, run: run)
                    startPlayer(listener: listener, outputUID: selected.outputUID, run: run)
                }
            }
            lastLeaseRefresh = Date()
            // Shared HLS already performs synthesis. Do not request duplicate private jobs.
            try await sendJSON(["type": "start", "asr_engine": "qwen3-asr",
                                "translation_direction": selected.direction,
                                "language": selected.languagePair.sourceLanguage,
                                "asr_context_terms": selected.contextTerms, "tts_enabled": false], to: ws)
            while true {
                let event = try await receive(ws)
                try requireCurrent(run)
                let previousSubtitle = subtitleState.text, previousIdentity = subtitleState.identity
                subtitleState.observe(event)
                if previousSubtitle != subtitleState.text || previousIdentity != subtitleState.identity { onChange?() }
                if event["type"] as? String == "error" {
                    throw ServiceError.message(event["message"] as? String ?? "无法开始传译。")
                }
                if event["type"] as? String == "started" {
                    try selected.languagePair.validateStarted(event)
                    break
                }
            }
            try requireCurrent(run)
            if nativePCMMode && selected.outputUID != "none" {
                // Start acknowledges the new producer generation before joining
                // audio; a surviving LAN epoch may still contain old speech.
                let joined = try await nativeSpeechSnapshot(listener: listener, after: -1, run: run)
                try requireCurrent(run)
                let audio = NativeSpeechPlayer()
                audio.onFailure = { [weak self] error in self?.fail(error, run: run) }
                #if NATIVE_PLAYBACK_TESTING
                audio.onPCMChunk = { [weak self] chunk in self?.onPlaybackPCM?(chunk) }
                #endif
                try audio.start(outputUID: selected.outputUID, epoch: joined.epoch, cursor: joined.cursor)
                speechPlayer = audio
                speechTransport = Task { [weak self] in await self?.receiveSpeech(listener: listener, run: run) }
            }
            receiver = Task { [weak self] in await self?.receiveLoop(ws, run: run) }
            heartbeat = Task { [weak self] in await self?.keepConnectionAlive(ws, run: run) }
            subtitleClock = Task { [weak self] in await self?.observeSubtitlePlayback(run: run) }
            maintenance = Task { [weak self] in await self?.maintain(run: run) }
            capture.onPCM = { [weak self] data in
                DispatchQueue.main.async { self?.enqueue(data, run: run) }
            }
            capture.onLevel = { [weak self] value in
                guard let self, self.generation == run else { return }
                self.level = value; self.onChange?()
            }
            capture.onFailure = { [weak self] error in self?.fail(error, run: run) }
            acceptingAudio = true
            message = selected.usesSystemAudio ? "正在开启系统声音采集…" : "正在开启输入设备…"
            onChange?()
            try await capture.start(inputUID: selected.inputUID)
            try requireCurrent(run)
            phase = .running; message = "\(selected.languagePair.title) · 传译运行中 · 网页可随时关闭"; onChange?()
        } catch {
            let cancelled = Task.isCancelled || generation != run
            if generation == run {
                await stop(drain: false)
                lastError = error.localizedDescription; phase = .failed; message = "传译未启动"; onChange?()
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    private func preferencesDidChange(_ value: NativePreferences) {
        preferences = value; statusFailures = 0; playbackStarted = false
        playbackLastProgress = Date(); playbackLastTime = 0
        gapSeekInFlight = false; gapSeekCount = 0; gapSkippedSeconds = 0
        #if NATIVE_PLAYBACK_TESTING
        playbackGapEvents.removeAll()
        #endif
    }

    private func requireCurrent(_ run: UUID, allowStopping: Bool = false) throws {
        guard generation == run, (phase != .stopping || allowStopping), !Task.isCancelled else { throw CancellationError() }
    }

    private func enqueue(_ data: Data, run: UUID) {
        guard generation == run, acceptingAudio, let ws = socket else { return }
        do { try pcm.append(data) } catch { fail(error.localizedDescription, run: run); return }
        guard sender == nil else { return }
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                while self.generation == run, let data = self.pcm.next() {
                    try Task.checkCancellation()
                    try await ws.send(.data(data))
                }
            } catch {
                if !Task.isCancelled { self.fail("音频发送中断：\(error.localizedDescription)", run: run) }
            }
            if self.generation == run { self.sender = nil }
        }
    }

    private func receive(_ ws: URLSessionWebSocketTask) async throws -> [String: Any] {
        let event = try await ws.receive()
        let data: Data
        switch event { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: throw ServiceError.message("无法读取识别消息。") }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.message("识别服务返回了无效消息。")
        }
        return result
    }

    private func sendJSON(_ value: [String: Any], to ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask, run: UUID) async {
        do {
            while !Task.isCancelled, generation == run {
                let event = try await receive(ws)
                guard !Task.isCancelled, generation == run else { return }
                let previousSubtitle = subtitleState.text, previousIdentity = subtitleState.identity
                subtitleState.observe(event)
                if previousSubtitle != subtitleState.text || previousIdentity != subtitleState.identity { onChange?() }
                if event["type"] as? String == "error" {
                    fail(event["message"] as? String ?? "识别服务异常。", run: run); return
                }
                if event["type"] as? String == "final" { finalReceived = true; return }
            }
        } catch {
            if generation == run && !Task.isCancelled && phase != .stopping {
                fail("本机识别连接中断：\(error.localizedDescription)", run: run)
            }
        }
    }

    private func keepConnectionAlive(_ ws: URLSessionWebSocketTask, run: UUID) async {
        // Application JSON reaches the server's receive loop; WebSocket control
        // pings do not reset its idle timer. Keep this independent of HTTP polls
        // and capture startup, which can wait for a macOS permission decision.
        do {
            while generation == run, phase == .starting || phase == .running {
                try Task.checkCancellation()
                try await sendJSON(["type": "ping"], to: ws)
                try await Task.sleep(nanoseconds: 8_000_000_000)
            }
        } catch {
            if !Task.isCancelled, generation == run, phase == .starting || phase == .running {
                fail("本机识别连接中断：\(error.localizedDescription)", run: run)
            }
        }
    }

    private func observeSubtitlePlayback(run: UUID) async {
        while generation == run, !Task.isCancelled {
            var candidate: SubtitlePlayback.Caption?
            if let audio = speechPlayer {
                candidate = SubtitlePlayback.pcm(audio.scheduledChunks, presentedFrame: audio.subtitlePresentedFrame)
            } else if let player, player.rate > 0, !gapSeekInFlight,
                      let date = player.currentItem?.currentDate() {
                let programMs = date.timeIntervalSince1970 * 1000
                if let cue = subtitleHLSCues.filter({ $0.start.isFinite && $0.start <= programMs && $0.text?.isEmpty == false })
                    .max(by: { $0.start < $1.start }), let text = cue.text {
                    candidate = .init(text: text, identity: .init(sentenceID: cue.id, revision: 0))
                }
            }
            // Hold the last audible text during a gap. Only actual playback can
            // advance it; draft/revised translations and network delays cannot.
            if let candidate, candidate != playbackSubtitle {
                playbackSubtitle = candidate; onChange?()
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func requestData(_ path: String, method: String = "GET", timeout: TimeInterval = 10,
                             body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!, timeoutInterval: timeout)
        request.httpMethod = method; request.cachePolicy = .reloadIgnoringLocalCacheData
        if !controlToken.isEmpty { request.setValue(controlToken, forHTTPHeaderField: "X-VoxBridge-Control-Token") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ServiceError.message("本机服务请求失败：\(path)")
        }
        return data
    }

    private func readStatus() async throws -> [String: Any] {
        let data = try await requestData("/api/monitor/state")
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["native_console"] as? Bool == true,
              let tts = result["tts"] as? [String: Any] else { throw ServiceError.message("服务版本不匹配，请停止服务后重新启动。") }
        let rows = result["rows"] as? [[String: Any]] ?? []
        sourceText = [rows.last?["source"] as? String ?? "", result["tentative"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        translationText = rows.reversed().compactMap { $0["translation"] as? String }.first(where: { !$0.isEmpty }) ?? ""
        backlogSeconds = (speechPlayer?.bufferedMilliseconds ?? (tts["translated_audio_backlog_ms"] as? Double ?? 0)) / 1000
        speed = tts["tts_effective_speed"] as? Double ?? 1.05
        listenerCount = tts["listener_count"] as? Int ?? 0
        // An individual synthesis failure is recoverable on the next sentence. It can
        // also predate this session when LAN listeners keep the shared epoch alive.
        let error = tts["last_error"] as? String ?? ""
        ttsWarning = error.isEmpty ? nil : "朗读合成提示：\(error)；下一句会继续尝试。"
        onChange?(); return tts
    }

    private func maintain(run: UUID) async {
        while !Task.isCancelled, generation == run {
            do {
                if let listener = localListener, Date().timeIntervalSince(lastLeaseRefresh) >= 5 {
                    if nativePCMMode { _ = try await nativeSpeechSnapshot(listener: listener, after: -1, run: run) }
                    else { _ = try await playbackPlaylist(listener: listener, run: run, allowStopping: true) }
                    lastLeaseRefresh = Date()
                }
                _ = try await readStatus()
                if Date().timeIntervalSince(lastDeviceCheck) >= 3 {
                    lastDeviceCheck = Date()
                    do {
                        if try preferences.outputUID != "default" && preferences.outputUID != "none" &&
                            !outputDevices().contains(where: { $0.uid == preferences.outputUID }) {
                            throw ServiceError.message("所选输出设备已断开，已停止传译。请重新选择输出设备。")
                        }
                        if try !preferences.usesSystemAudio && preferences.inputUID != "default" &&
                            !inputDevices().contains(where: { $0.uid == preferences.inputUID }) {
                            throw ServiceError.message("所选输入设备已断开，已停止传译。请重新选择输入设备。")
                        }
                    } catch { fail(error.localizedDescription, run: run); return }
                }
                statusFailures = 0
            } catch {
                guard generation == run, !Task.isCancelled else { return }
                statusFailures += 1
                if statusFailures >= 3 { fail(error.localizedDescription, run: run); return }
            }
            if let audio = speechPlayer, phase == .running {
                let time = Double(audio.renderedFrame) / 24000
                if audio.drained || time > playbackLastTime + 0.1 {
                    playbackLastTime = time; playbackLastProgress = Date()
                }
                if !audio.drained && Date().timeIntervalSince(playbackLastProgress) > 20 {
                    fail("本机 PCM 朗读播放已停滞，请停止后重试。", run: run); return
                }
            } else if let player, playbackStarted, phase == .running {
                let time = player.currentTime().seconds
                if time.isFinite, time > playbackLastTime + 0.1 { playbackLastTime = time; playbackLastProgress = Date() }
                if Date().timeIntervalSince(playbackLastProgress) > 20 { fail("本机朗读播放已停滞，请停止后重试。", run: run); return }
            } else if player != nil, phase == .running, Date().timeIntervalSince(playbackLastProgress) > 20 {
                fail("本机朗读未能开始播放，请检查输出设备后重试。", run: run); return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func startPlayer(listener: String, outputUID: String, run: UUID) {
        let item = AVPlayerItem(url: URL(string: playlistPath(listener), relativeTo: base)!)
        item.preferredForwardBufferDuration = 1
        let audio = AVPlayer(playerItem: item)
        audio.audioOutputDeviceUniqueID = outputUID == "default" ? nil : outputUID
        audio.automaticallyWaitsToMinimizeStalling = false
        player = audio
        gapMaintenance = Task { [weak self] in await self?.maintainPlaybackGaps(listener: listener, run: run) }
        playerObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak audio] item, _ in
            let status = item.status
            let error = item.error?.localizedDescription
            DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                if status == .failed { self.fail("无法播放朗读：\(error ?? "未知错误")", run: run) }
                if status == .readyToPlay && !self.playbackStarted {
                    self.playbackStarted = true; self.playbackLastProgress = Date()
                    audio?.play()
                }
            }
        }
    }

    private func nativeSpeechSnapshot(listener: String, after: Int, epoch: String? = nil,
                                      run: UUID) async throws -> NativeSpeechSnapshot {
        try requireCurrent(run, allowStopping: true)
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "after", value: String(after))]
        if let epoch { components.queryItems?.append(URLQueryItem(name: "epoch", value: epoch)) }
        do {
            let data = try await requestData("/api/native/tts/\(listener)/pcm?\(components.percentEncodedQuery!)", timeout: 3)
            try requireCurrent(run, allowStopping: true)
            return try JSONDecoder().decode(NativeSpeechSnapshot.self, from: data)
        } catch {
            if generation != run { await releaseListener(listener); throw CancellationError() }
            throw error
        }
    }

    private func receiveSpeech(listener: String, run: UUID) async {
        var failures = 0
        var feedbackAt = Date.distantPast
        while generation == run, !Task.isCancelled, let audio = speechPlayer {
            do {
                if audio.bufferedMilliseconds < 12000 {
                    let snapshot = try await nativeSpeechSnapshot(listener: listener, after: audio.receivedSequence,
                                                                  epoch: audio.epoch, run: run)
                    try requireCurrent(run, allowStopping: true)
                    try audio.accept(snapshot)
                }
                if Date().timeIntervalSince(feedbackAt) >= 0.25 {
                    _ = try await requestData("/api/native/tts/\(listener)/playback", method: "POST", timeout: 3,
                                             body: ["epoch": audio.epoch, "received_seq": audio.receivedSequence,
                                                    "played_seq": audio.playedSequence, "buffered_ms": audio.bufferedMilliseconds,
                                                    "playing": audio.isPlaying])
                    feedbackAt = Date()
                }
                failures = 0
            } catch {
                guard generation == run, !Task.isCancelled else { return }
                failures += 1
                if failures >= 3 { fail("本机朗读连接中断：\(error.localizedDescription)", run: run); return }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func maintainPlaybackGaps(listener: String, run: UUID) async {
        var cues: [HLSPlaybackGap.Cue] = [], attempted = Set<String>()
        var lastFetch = Date.distantPast
        while !Task.isCancelled, generation == run {
            if Date().timeIntervalSince(lastFetch) >= 0.5 {
                lastFetch = Date()
                // This is optional playback metadata: an unavailable snapshot must
                // leave ordinary continuous playback running, not stop interpretation.
                if let data = try? await requestData("/api/tts/live/\(listener)/captions", timeout: 2),
                   let snapshot = try? JSONDecoder().decode(HLSPlaybackGap.Snapshot.self, from: data) {
                    cues = snapshot.cues
                    if generation == run { subtitleHLSCues = snapshot.cues }
                    attempted.formIntersection(Set(cues.map(\.id)))
                }
            }
            guard generation == run, !Task.isCancelled else { return }
            if playbackStarted, !gapSeekInFlight, phase == .running || phase == .stopping,
               let audio = player, let item = audio.currentItem, item.status == .readyToPlay,
               let date = item.currentDate() {
                let mediaTime = audio.currentTime().seconds
                let programMs = date.timeIntervalSince1970 * 1000
                let ranges: [ClosedRange<Double>] = item.seekableTimeRanges.compactMap {
                    let start = $0.timeRangeValue.start.seconds, end = CMTimeRangeGetEnd($0.timeRangeValue).seconds
                    return start.isFinite && end.isFinite && start <= end ? start...end : nil
                }
                if let target = HLSPlaybackGap.target(cues: cues, playheadMs: programMs, mediaTime: mediaTime, seekable: ranges),
                   !attempted.contains(target.cueID) {
                    attempted.insert(target.cueID); gapSeekInFlight = true
                    let requestedAt = Date()
                    // Do not trim the server playlist: AVPlayer needs continuous
                    // sequence numbers. Exact forward seeks are confined to silence.
                    audio.seek(to: CMTime(seconds: target.mediaTime, preferredTimescale: 24000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak audio] finished in
                        Task { @MainActor in
                            guard let self, let audio, self.generation == run, self.player === audio,
                                  self.phase == .running || self.phase == .stopping else { return }
                            self.gapSeekInFlight = false
                            if finished {
                                self.gapSeekCount += 1; self.gapSkippedSeconds += target.skippedSeconds
                            }
                            #if NATIVE_PLAYBACK_TESTING
                            self.playbackGapEvents.append(["cue_id": target.cueID, "finished": finished,
                                "from_ms": programMs, "target_media_time": target.mediaTime,
                                "requested_wall_ms": requestedAt.timeIntervalSince1970 * 1000,
                                "next_speech_ms": target.nextSpeechMs, "skip_seconds": target.skippedSeconds,
                                "seek_wall_seconds": Date().timeIntervalSince(requestedAt),
                                "landed_ms": (audio.currentItem?.currentDate()?.timeIntervalSince1970 ?? 0) * 1000])
                            if self.playbackGapEvents.count > 256 { self.playbackGapEvents.removeFirst() }
                            #endif
                            NSLog("Native HLS carrier seek finished=%d skipped=%.3fs latency=%.3fs", finished ? 1 : 0,
                                  target.skippedSeconds, Date().timeIntervalSince(requestedAt))
                            audio.play()
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForPlaybackBootstrap(listener: String, initial: Data, run: UUID) async throws {
        // A one-segment cold playlist can leave AVPlayer in .unknown indefinitely,
        // even as subsequent manifests grow. Construct it only with a usable window.
        let deadline = Date().addingTimeInterval(12)
        var playlist = initial
        while true {
            try requireCurrent(run)
            if HLSPlaybackBootstrap.isReady(String(decoding: playlist, as: UTF8.self)) { return }
            guard Date() < deadline else { throw ServiceError.message("朗读音频尚未准备好，请重新开始。") }
            try await Task.sleep(nanoseconds: 250_000_000)
            playlist = try await playbackPlaylist(listener: listener, run: run)
        }
    }

    private func playbackPlaylist(listener: String, run: UUID, allowStopping: Bool = false) async throws -> Data {
        try requireCurrent(run, allowStopping: allowStopping)
        do {
            let data = try await requestData(playlistPath(listener))
            try requireCurrent(run, allowStopping: allowStopping)
            return data
        } catch {
            // An in-flight GET can register its lease after stop() deleted it.
            if generation != run {
                await releaseListener(listener)
                throw CancellationError()
            }
            throw error
        }
    }

    private func playlistPath(_ listener: String) -> String {
        "/api/tts/live/\(listener)/index.m3u8?continuous=true"
    }

    private func releaseListener(_ listener: String) async {
        // The App cancels startup before stopping. Cleanup must still reach the
        // server even when its caller is already canceled.
        let cleanup = Task { _ = try? await requestData("/api/tts/live/\(listener)", method: "DELETE") }
        await cleanup.value
    }

    private func fail(_ error: String, run: UUID) {
        guard generation == run, phase != .stopping, phase != .failed else { return }
        lastError = error
        Task { [weak self] in
            guard let self, self.generation == run else { return }
            await self.stop(drain: false)
            self.lastError = error; self.phase = .failed; self.message = "传译已停止，需要处理"; self.onChange?()
        }
    }

    func stop(drain: Bool = true) async {
        guard isActive else { return }
        if phase == .stopping {
            while phase == .stopping { try? await Task.sleep(nanoseconds: 50_000_000) }
            return
        }
        let wasStarting = phase == .starting
        heartbeat?.cancel(); heartbeat = nil
        phase = .stopping; message = drain && !wasStarting ? "正在完成最后一句并等待朗读结束…" : "正在停止传译…"; onChange?()
        if wasStarting || !drain {
            acceptingAudio = false; generation = UUID(); socket?.cancel(with: .goingAway, reason: nil)
            sender?.cancel(); receiver?.cancel()
        }
        await capture.stop()
        acceptingAudio = false; level = 0
        if drain && !wasStarting, let ws = socket {
            let sendDeadline = Date().addingTimeInterval(6)
            while sender != nil && Date() < sendDeadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if sender == nil {
                do {
                    try await sendJSON(["type": "finish"], to: ws)
                    let finalDeadline = Date().addingTimeInterval(45)
                    while !finalReceived && Date() < finalDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                    if !finalReceived { throw ServiceError.message("最后一句处理超时，已结束此次传译。") }
                    try await drainAudio()
                } catch { lastError = error.localizedDescription }
            } else { lastError = "待发送音频未能及时完成，已结束此次传译。" }
        }
        generation = UUID(); maintenance?.cancel(); maintenance = nil
        subtitleClock?.cancel(); subtitleClock = nil; playbackSubtitle = nil; subtitleHLSCues = []
        gapMaintenance?.cancel(); gapMaintenance = nil; gapSeekInFlight = false
        speechTransport?.cancel(); speechTransport = nil
        speechPlayer?.stop(); speechPlayer = nil
        receiver?.cancel(); receiver = nil; sender?.cancel(); sender = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        socketSession?.invalidateAndCancel(); socketSession = nil
        playerObservation = nil; player?.pause(); player = nil
        if let listener = localListener {
            await releaseListener(listener)
        }
        localListener = nil; pcm.reset(); backlogSeconds = 0; subtitleState.reset()
        phase = lastError == nil ? .idle : .failed
        message = lastError == nil ? "传译已停止 · 服务保持就绪" : "传译已停止，需要处理"
        onChange?()
    }

    private func drainAudio() async throws {
        let deadline = Date().addingTimeInterval(60)
        var quietSince: Date?
        while Date() < deadline {
            let tts = try await readStatus()
            let quiet = (tts["queue_depth"] as? Int ?? 0) == 0 &&
                (tts["preparation_queue_depth"] as? Int ?? 0) == 0 &&
                (tts["pending_audio_ms"] as? Int ?? 0) == 0 &&
                (tts["synthesis_active"] as? Bool ?? false) == false
            if quiet {
                if quietSince == nil { quietSince = Date() }
                if let audio = speechPlayer, let listener = localListener {
                    let tail = try await nativeSpeechSnapshot(listener: listener, after: -1, run: generation)
                    if audio.receivedSequence == tail.cursor && !audio.completeSentence {
                        throw ServiceError.message("最后一句朗读音频不完整，已停止。请检查语音合成错误后重试。")
                    }
                    if audio.drained && audio.receivedSequence == tail.cursor { return }
                } else if let player, let listener = localListener {
                    let data = try await requestData("/api/tts/live/\(listener)/captions")
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let cues = object?["cues"] as? [[String: Any]] ?? []
                    let end = cues.compactMap { $0["end_at_ms"] as? Double }.max() ?? 0
                    if end == 0 || (player.currentItem?.currentDate()?.timeIntervalSince1970 ?? 0) * 1000 >= end { return }
                } else if Date().timeIntervalSince(quietSince!) >= 2 { return }
            } else { quietSince = nil }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ServiceError.message("朗读等待超过 60 秒，已停止本机播放。")
    }
}
