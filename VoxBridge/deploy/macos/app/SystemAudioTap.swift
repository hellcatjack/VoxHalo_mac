import Foundation
import CoreAudio
import AVFoundation

/// Confined to the tap's lifecycle queue. Also handles partially completed starts.
final class AudioTapCleanup {
    private var actions: [() -> Void] = []
    func add(_ action: @escaping () -> Void) { actions.append(action) }
    func close() {
        let pending = actions.reversed(); actions = []
        for action in pending { action() }
    }
    deinit { close() }
}

/// Serial HAL ownership with a cancellable caller. A synchronous OS permission
/// request cannot be interrupted; any late completion is cleaned on this queue.
final class AudioTapLifecycle: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.voxbridge.capture.tap.lifecycle")
    private let cleanup = AudioTapCleanup()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?

    func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }

    private func install(_ pending: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        continuation = pending
        return true
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        finished = true
        let pending = continuation; continuation = nil
        let stopped = cancelled
        lock.unlock()
        pending?.resume(with: stopped ? .failure(CancellationError()) : result)
    }

    /// Returns whether HAL startup already finished and cleanup can be awaited.
    @discardableResult private func cancel() -> Bool {
        lock.lock()
        cancelled = true
        let pending = continuation; continuation = nil
        let canWait = finished
        lock.unlock()
        pending?.resume(throwing: CancellationError())
        return canWait
    }

    func start(_ operation: @escaping (AudioTapCleanup) throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                guard install(pending) else { pending.resume(throwing: CancellationError()); return }
                queue.async { [self] in
                    do {
                        try checkCancellation()
                        try operation(cleanup)
                        try checkCancellation()
                        complete(.success(()))
                    } catch { cleanup.close(); complete(.failure(error)) }
                }
            }
        } onCancel: {
            self.cancel()
            self.queue.async { self.cleanup.close() }
        }
    }

    func stop() async {
        guard cancel() else {
            // Do not hold the UI or PCM shutdown behind an unanswered prompt.
            queue.async { self.cleanup.close() }
            return
        }
        await withCheckedContinuation { continuation in
            queue.async { [self] in cleanup.close(); continuation.resume() }
        }
    }
}

/// A private tap: mute other processes while reading, exclude this App's TTS.
final class SystemAudioTap: @unchecked Sendable {
    private let lifecycle = AudioTapLifecycle()
    private let ioQueue = DispatchQueue(label: "org.voxbridge.capture.tap.io", qos: .userInitiated)

    static func description(excluding process: AudioObjectID) throws -> CATapDescription {
        guard process != kAudioObjectUnknown else {
            throw NativeAudioError.message("无法排除本 App 的朗读音频，已取消采集以防止回声。")
        }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [process])
        description.name = "教会同声传译 · 只听译音"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    static func aggregateDescription(tapUID: String) -> [String: Any] {
        [kAudioAggregateDeviceNameKey: "VoxBridge Private Capture",
         kAudioAggregateDeviceUIDKey: UUID().uuidString,
         kAudioAggregateDeviceIsPrivateKey: true,
         kAudioAggregateDeviceIsStackedKey: false,
         // Do not wait inside AudioDeviceStart for a paused browser to play.
         kAudioAggregateDeviceTapAutoStartKey: false,
         kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                          kAudioSubTapDriftCompensationKey: true]]]
    }

    func start(run: AudioCaptureRun) async throws {
        try await lifecycle.start { [self] cleanup in try startSync(run: run, cleanup: cleanup) }
    }

    func stop() async {
        await lifecycle.stop()
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw NativeAudioError.message("系统声音采集失败（\(step)：\(status)）。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许“教会同声传译”。")
        }
    }

    private func startSync(run: AudioCaptureRun, cleanup: AudioTapCleanup) throws {
        guard #available(macOS 14.2, *) else {
            throw NativeAudioError.message("“只听译音”需要 macOS 14.2 或更新版本。")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "排除自身")
        let description = try Self.description(excluding: process)
        try lifecycle.checkCancellation()
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "创建截取")
        let tapID = tap
        cleanup.add { _ = AudioHardwareDestroyProcessTap(tapID) }

        address.mSelector = kAudioTapPropertyFormat
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "读取格式")
        guard let format = AVAudioFormat(streamDescription: &asbd),
              format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else {
            throw NativeAudioError.message("系统音频截取未提供有效浮点 PCM。")
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        try lifecycle.checkCancellation()
        try check(AudioHardwareCreateAggregateDevice(Self.aggregateDescription(tapUID: description.uuid.uuidString) as CFDictionary, &device), "创建采集设备")
        let deviceID = device
        cleanup.add { _ = AudioHardwareDestroyAggregateDevice(deviceID) }
        var io: AudioDeviceIOProcID?
        let lifecycle = self.lifecycle
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, ioQueue) { _, input, _, _, _ in
            guard (try? lifecycle.checkCancellation()) != nil,
                  input.pointee.mNumberBuffers > 0,
                  input.pointee.mBuffers.mDataByteSize > 0,
                  input.pointee.mBuffers.mData != nil else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else {
                run.fail("系统音频截取缓冲区无效。"); return
            }
            // AudioCaptureRun copies the PCM before this callback returns.
            if buffer.frameLength > 0 { run.submit(buffer) }
        }, "创建音频回调")
        guard let io else { throw NativeAudioError.message("系统音频回调不可用。") }
        cleanup.add {
            _ = AudioDeviceStop(deviceID, io)
            _ = AudioDeviceDestroyIOProcID(deviceID, io)
        }
        try lifecycle.checkCancellation()
        try check(AudioDeviceStart(device, io), "开始音频截取")
    }
}
