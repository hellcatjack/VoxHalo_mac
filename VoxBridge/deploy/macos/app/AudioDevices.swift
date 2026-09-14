import Foundation
import CoreAudio

struct AudioDevice {
    let id: UInt32
    let uid: String
    let name: String
    let isInput: Bool
}

enum NativeAudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum AudioDevices {
    static func inputs() throws -> [AudioDevice] { try devices(input: true) }
    static func outputs() throws -> [AudioDevice] { try devices(input: false) }
    static func defaultInputUID() -> String? { defaultUID(kAudioHardwarePropertyDefaultInputDevice) }
    static func defaultOutputUID() -> String? { defaultUID(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return try? string(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, let value = value else { throw NativeAudioError.message("无法读取音频设备信息（\(status)）。") }
        return value.takeRetainedValue() as String
    }

    private static func devices(input: Bool) throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw NativeAudioError.message("无法列出音频设备（\(status)）。") }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw NativeAudioError.message("无法列出音频设备（\(status)）。") }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes >= MemoryLayout<AudioBufferList>.size else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(id, &streams, 0, nil, &bytes, memory) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.contains(where: { $0.mNumberChannels > 0 }),
                  let uid = try? string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = try? string(id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, isInput: input)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
