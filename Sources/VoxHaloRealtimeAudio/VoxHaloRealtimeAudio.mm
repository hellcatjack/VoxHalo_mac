#include "VoxHaloRealtimeAudio.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <mach/mach_time.h>
#include <new>
#include <vector>

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "The real-time ring requires lock-free 64-bit atomics");
static_assert(std::atomic<int32_t>::is_always_lock_free,
              "The real-time input requires lock-free status atomics");

struct VHRealtimeRing {
    uint32_t slotCount = 0;
    uint32_t bytesPerSlot = 0;
    uint8_t *storage = nullptr;
    VHRealtimePacket *packets = nullptr;
    std::atomic<uint64_t> readSequence {0};
    std::atomic<uint64_t> writeSequence {0};
    std::atomic<uint64_t> droppedPacketCount {0};
};

struct VHAUHALInput {
    AudioUnit unit = nullptr;
    VHRealtimeRing *ring = nullptr;
    AudioStreamBasicDescription format {};
    UInt32 maximumFramesPerSlice = 0;
    UInt32 bufferCount = 0;
    UInt32 bytesPerBuffer = 0;
    AudioBufferList *bufferList = nullptr;
    uint8_t *renderStorage = nullptr;
    uint8_t *packetStorage = nullptr;
    uint32_t packetCapacity = 0;
    mach_timebase_info_data_t timebase {0, 0};
    bool callbackInstalled = false;
    bool initialized = false;
    bool started = false;
};

struct VHAudioDeviceInput {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProcID = nullptr;
    VHRealtimeRing *ring = nullptr;
    AudioStreamBasicDescription format {};
    UInt32 bufferFrameSize = 0;
    UInt32 bufferCount = 0;
    uint8_t *packetStorage = nullptr;
    uint32_t packetCapacity = 0;
    mach_timebase_info_data_t timebase {0, 0};
    std::atomic<uint64_t> callbackCount {0};
    std::atomic<uint64_t> sourcePacketCount {0};
    std::atomic<uint64_t> sourceFrameCount {0};
    std::atomic<uint64_t> sourceByteCount {0};
    std::atomic<uint64_t> ringWriteFailureCount {0};
    std::atomic<int32_t> lastStatus {noErr};
    bool started = false;
};

namespace {

constexpr double kMinimumBufferedSeconds = 1.28;

bool MultiplyFits(uint64_t lhs, uint64_t rhs, uint32_t *result) {
    const uint64_t product = lhs * rhs;
    if (lhs != 0 && product / lhs != rhs) {
        return false;
    }
    if (product > std::numeric_limits<uint32_t>::max()) {
        return false;
    }
    *result = static_cast<uint32_t>(product);
    return true;
}

bool ConfigureRing(VHRealtimeRing *ring,
                   uint32_t slotCount,
                   uint32_t bytesPerSlot) {
    if (ring == nullptr || slotCount == 0 || bytesPerSlot == 0) {
        return false;
    }
    const size_t slotBytes = static_cast<size_t>(slotCount)
        * static_cast<size_t>(bytesPerSlot);
    if (slotBytes / slotCount != bytesPerSlot) {
        return false;
    }

    auto *storage = new (std::nothrow) uint8_t[slotBytes];
    auto *packets = new (std::nothrow) VHRealtimePacket[slotCount];
    if (storage == nullptr || packets == nullptr) {
        delete[] storage;
        delete[] packets;
        return false;
    }

    delete[] ring->storage;
    delete[] ring->packets;
    ring->storage = storage;
    ring->packets = packets;
    ring->slotCount = slotCount;
    ring->bytesPerSlot = bytesPerSlot;
    ring->readSequence.store(0, std::memory_order_relaxed);
    ring->writeSequence.store(0, std::memory_order_relaxed);
    ring->droppedPacketCount.store(0, std::memory_order_relaxed);
    return true;
}

void ReleaseCaptureStorage(VHAUHALInput *input) {
    if (input == nullptr) {
        return;
    }
    delete[] reinterpret_cast<uint8_t *>(input->bufferList);
    delete[] input->renderStorage;
    delete[] input->packetStorage;
    input->bufferList = nullptr;
    input->renderStorage = nullptr;
    input->packetStorage = nullptr;
    input->packetCapacity = 0;
    input->bufferCount = 0;
    input->bytesPerBuffer = 0;
}

OSStatus AllocateCaptureStorage(VHAUHALInput *input) {
    const auto &format = input->format;
    if (format.mFormatID != kAudioFormatLinearPCM
        || format.mSampleRate <= 0
        || format.mChannelsPerFrame == 0
        || format.mBytesPerFrame == 0
        || input->maximumFramesPerSlice == 0) {
        return kAudioFormatUnsupportedDataFormatError;
    }

    const bool noninterleaved =
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    input->bufferCount = noninterleaved ? format.mChannelsPerFrame : 1;
    if (!MultiplyFits(input->maximumFramesPerSlice,
                      format.mBytesPerFrame,
                      &input->bytesPerBuffer)) {
        return kAudio_ParamError;
    }
    if (!MultiplyFits(input->bufferCount,
                      input->bytesPerBuffer,
                      &input->packetCapacity)) {
        return kAudio_ParamError;
    }

    const size_t listBytes = offsetof(AudioBufferList, mBuffers)
        + static_cast<size_t>(input->bufferCount) * sizeof(AudioBuffer);
    auto *listBytesStorage = new (std::nothrow) uint8_t[listBytes];
    auto *renderStorage = new (std::nothrow) uint8_t[input->packetCapacity];
    auto *packetStorage = new (std::nothrow) uint8_t[input->packetCapacity];
    if (listBytesStorage == nullptr
        || renderStorage == nullptr
        || packetStorage == nullptr) {
        delete[] listBytesStorage;
        delete[] renderStorage;
        delete[] packetStorage;
        return memFullErr;
    }

    input->bufferList = reinterpret_cast<AudioBufferList *>(listBytesStorage);
    input->renderStorage = renderStorage;
    input->packetStorage = packetStorage;
    input->bufferList->mNumberBuffers = input->bufferCount;
    for (UInt32 index = 0; index < input->bufferCount; ++index) {
        AudioBuffer &buffer = input->bufferList->mBuffers[index];
        buffer.mNumberChannels = noninterleaved ? 1 : format.mChannelsPerFrame;
        buffer.mDataByteSize = input->bytesPerBuffer;
        buffer.mData = input->renderStorage
            + static_cast<size_t>(index) * input->bytesPerBuffer;
    }

    const double desiredFrames = format.mSampleRate * kMinimumBufferedSeconds;
    const uint64_t calculatedSlots = static_cast<uint64_t>(std::ceil(
        desiredFrames / static_cast<double>(input->maximumFramesPerSlice)
    ));
    const uint64_t slotCount64 = std::max<uint64_t>(4, calculatedSlots);
    if (slotCount64 > std::numeric_limits<uint32_t>::max()
        || !ConfigureRing(input->ring,
                          static_cast<uint32_t>(slotCount64),
                          input->packetCapacity)) {
        ReleaseCaptureStorage(input);
        return memFullErr;
    }
    return noErr;
}

uint64_t MonotonicNanoseconds(const VHAUHALInput *input) {
    const uint64_t ticks = mach_continuous_time();
    const __uint128_t scaled = static_cast<__uint128_t>(ticks)
        * input->timebase.numer / input->timebase.denom;
    if (scaled > std::numeric_limits<uint64_t>::max()) {
        return std::numeric_limits<uint64_t>::max();
    }
    return static_cast<uint64_t>(scaled);
}

uint64_t MonotonicNanoseconds(const VHAudioDeviceInput *input) {
    const uint64_t ticks = mach_continuous_time();
    const __uint128_t scaled = static_cast<__uint128_t>(ticks)
        * input->timebase.numer / input->timebase.denom;
    if (scaled > std::numeric_limits<uint64_t>::max()) {
        return std::numeric_limits<uint64_t>::max();
    }
    return static_cast<uint64_t>(scaled);
}

OSStatus ReadSingleInputStreamFormat(
    AudioDeviceID deviceID,
    AudioStreamBasicDescription *format
) {
    AudioObjectPropertyAddress streamsAddress {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 streamsSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        deviceID,
        &streamsAddress,
        0,
        nullptr,
        &streamsSize
    );
    if (status != noErr || streamsSize < sizeof(AudioObjectID)) {
        return status == noErr ? kAudioFormatUnsupportedDataFormatError : status;
    }

    std::vector<AudioObjectID> streams(
        streamsSize / static_cast<UInt32>(sizeof(AudioObjectID))
    );
    status = AudioObjectGetPropertyData(
        deviceID,
        &streamsAddress,
        0,
        nullptr,
        &streamsSize,
        streams.data()
    );
    if (status != noErr) {
        return status;
    }
    streams.resize(streamsSize / sizeof(AudioObjectID));

    AudioObjectID inputStream = kAudioObjectUnknown;
    for (const AudioObjectID stream : streams) {
        AudioObjectPropertyAddress directionAddress {
            kAudioStreamPropertyDirection,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 direction = 0;
        UInt32 directionSize = sizeof(direction);
        status = AudioObjectGetPropertyData(
            stream,
            &directionAddress,
            0,
            nullptr,
            &directionSize,
            &direction
        );
        if (status != noErr) {
            return status;
        }
        if (direction == 0) {
            continue;
        }
        if (inputStream != kAudioObjectUnknown) {
            return kAudioFormatUnsupportedDataFormatError;
        }
        inputStream = stream;
    }
    if (inputStream == kAudioObjectUnknown) {
        return kAudioFormatUnsupportedDataFormatError;
    }

    AudioObjectPropertyAddress formatAddress {
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 formatSize = sizeof(*format);
    return AudioObjectGetPropertyData(
        inputStream,
        &formatAddress,
        0,
        nullptr,
        &formatSize,
        format
    );
}

OSStatus AllocateDeviceInputStorage(VHAudioDeviceInput *input) {
    if (input->format.mFormatID != kAudioFormatLinearPCM
        || input->format.mSampleRate <= 0
        || input->format.mChannelsPerFrame == 0
        || input->format.mBytesPerFrame == 0
        || input->bufferFrameSize == 0) {
        return kAudioFormatUnsupportedDataFormatError;
    }

    const bool noninterleaved =
        (input->format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    input->bufferCount = noninterleaved
        ? input->format.mChannelsPerFrame
        : 1;
    uint32_t bytesPerBuffer = 0;
    if (!MultiplyFits(
            input->bufferFrameSize,
            input->format.mBytesPerFrame,
            &bytesPerBuffer
        )
        || !MultiplyFits(
            input->bufferCount,
            bytesPerBuffer,
            &input->packetCapacity
        )) {
        return kAudio_ParamError;
    }

    input->packetStorage = new (std::nothrow) uint8_t[input->packetCapacity];
    if (input->packetStorage == nullptr) {
        return memFullErr;
    }
    const double desiredFrames = input->format.mSampleRate
        * kMinimumBufferedSeconds;
    const uint64_t calculatedSlots = static_cast<uint64_t>(std::ceil(
        desiredFrames / static_cast<double>(input->bufferFrameSize)
    ));
    const uint64_t slotCount64 = std::max<uint64_t>(4, calculatedSlots);
    if (slotCount64 > std::numeric_limits<uint32_t>::max()
        || !ConfigureRing(
            input->ring,
            static_cast<uint32_t>(slotCount64),
            input->packetCapacity
        )) {
        delete[] input->packetStorage;
        input->packetStorage = nullptr;
        input->packetCapacity = 0;
        return memFullErr;
    }
    return noErr;
}

OSStatus DeviceInputIOProc(
    AudioObjectID,
    const AudioTimeStamp *,
    const AudioBufferList *inputData,
    const AudioTimeStamp *,
    AudioBufferList *,
    const AudioTimeStamp *,
    void *reference
) {
    auto *input = static_cast<VHAudioDeviceInput *>(reference);
    if (input == nullptr) {
        return noErr;
    }
    input->callbackCount.fetch_add(1, std::memory_order_relaxed);

    auto reject = [input](OSStatus status) {
        input->lastStatus.store(status, std::memory_order_relaxed);
        return noErr;
    };
    if (inputData == nullptr
        || inputData->mNumberBuffers != input->bufferCount) {
        return reject(kAudio_ParamError);
    }

    UInt32 frameCount = 0;
    uint32_t packetBytes = 0;
    for (UInt32 index = 0; index < inputData->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = inputData->mBuffers[index];
        if (buffer.mData == nullptr
            || buffer.mDataByteSize == 0
            || buffer.mDataByteSize % input->format.mBytesPerFrame != 0
            || buffer.mDataByteSize > input->packetCapacity - packetBytes) {
            return reject(kAudio_ParamError);
        }
        const UInt32 bufferFrames = buffer.mDataByteSize
            / input->format.mBytesPerFrame;
        if (index == 0) {
            frameCount = bufferFrames;
        } else if (bufferFrames != frameCount) {
            return reject(kAudio_ParamError);
        }
        std::memcpy(
            input->packetStorage + packetBytes,
            buffer.mData,
            buffer.mDataByteSize
        );
        packetBytes += buffer.mDataByteSize;
    }
    if (frameCount == 0 || frameCount > input->bufferFrameSize) {
        return reject(kAudio_ParamError);
    }

    const bool wrote = VHRealtimeRingWrite(
        input->ring,
        input->packetStorage,
        packetBytes,
        frameCount,
        MonotonicNanoseconds(input)
    );
    if (!wrote) {
        input->ringWriteFailureCount.fetch_add(1, std::memory_order_relaxed);
        return reject(kAudioHardwareUnspecifiedError);
    }
    input->sourcePacketCount.fetch_add(1, std::memory_order_relaxed);
    input->sourceFrameCount.fetch_add(frameCount, std::memory_order_relaxed);
    input->sourceByteCount.fetch_add(packetBytes, std::memory_order_relaxed);
    input->lastStatus.store(noErr, std::memory_order_relaxed);
    return noErr;
}

OSStatus RenderInput(void *reference,
                     AudioUnitRenderActionFlags *flags,
                     const AudioTimeStamp *timestamp,
                     UInt32,
                     UInt32 frameCount,
                     AudioBufferList *) {
    auto *input = static_cast<VHAUHALInput *>(reference);
    if (input == nullptr || frameCount == 0) {
        return noErr;
    }
    if (frameCount > input->maximumFramesPerSlice) {
        return kAudio_ParamError;
    }

    const UInt32 callbackBytesPerBuffer = frameCount * input->format.mBytesPerFrame;
    for (UInt32 index = 0; index < input->bufferCount; ++index) {
        AudioBuffer &buffer = input->bufferList->mBuffers[index];
        buffer.mDataByteSize = callbackBytesPerBuffer;
        buffer.mData = input->renderStorage
            + static_cast<size_t>(index) * input->bytesPerBuffer;
    }

    const OSStatus status = AudioUnitRender(
        input->unit,
        flags,
        timestamp,
        1,
        frameCount,
        input->bufferList
    );
    if (status != noErr) {
        return status;
    }

    uint32_t packetBytes = 0;
    for (UInt32 index = 0; index < input->bufferCount; ++index) {
        const AudioBuffer &buffer = input->bufferList->mBuffers[index];
        if (buffer.mData == nullptr
            || buffer.mDataByteSize > input->packetCapacity - packetBytes) {
            return kAudio_ParamError;
        }
        std::memcpy(input->packetStorage + packetBytes,
                    buffer.mData,
                    buffer.mDataByteSize);
        packetBytes += buffer.mDataByteSize;
    }

    VHRealtimeRingWrite(
        input->ring,
        input->packetStorage,
        packetBytes,
        frameCount,
        MonotonicNanoseconds(input)
    );
    return noErr;
}

void RemoveInputCallback(VHAUHALInput *input) {
    if (input == nullptr || input->unit == nullptr || !input->callbackInstalled) {
        return;
    }
    AURenderCallbackStruct callback {};
    AudioUnitSetProperty(
        input->unit,
        kAudioOutputUnitProperty_SetInputCallback,
        kAudioUnitScope_Global,
        0,
        &callback,
        sizeof(callback)
    );
    input->callbackInstalled = false;
}

void RollBackCreate(VHAUHALInput *input) {
    if (input == nullptr) {
        return;
    }
    if (input->initialized) {
        AudioUnitUninitialize(input->unit);
        input->initialized = false;
    }
    RemoveInputCallback(input);
    ReleaseCaptureStorage(input);
    if (input->unit != nullptr) {
        AudioComponentInstanceDispose(input->unit);
        input->unit = nullptr;
    }
}

} // namespace

int32_t VHRealtimeAudioBridgeVersion(void) {
    return 1;
}

VHRealtimeRing *VHRealtimeRingCreate(uint32_t slotCount,
                                     uint32_t bytesPerSlot) {
    auto *ring = new (std::nothrow) VHRealtimeRing();
    if (ring == nullptr) {
        return nullptr;
    }
    if (!ConfigureRing(ring, slotCount, bytesPerSlot)) {
        delete ring;
        return nullptr;
    }
    return ring;
}

void VHRealtimeRingDestroy(VHRealtimeRing *ring) {
    if (ring == nullptr) {
        return;
    }
    delete[] ring->storage;
    delete[] ring->packets;
    delete ring;
}

void VHRealtimeRingReset(VHRealtimeRing *ring) {
    if (ring == nullptr) {
        return;
    }
    ring->readSequence.store(0, std::memory_order_relaxed);
    ring->writeSequence.store(0, std::memory_order_relaxed);
    ring->droppedPacketCount.store(0, std::memory_order_relaxed);
}

bool VHRealtimeRingWrite(VHRealtimeRing *ring,
                         const void *source,
                         uint32_t byteCount,
                         uint32_t frameCount,
                         uint64_t callbackNanoseconds) {
    if (ring == nullptr
        || (source == nullptr && byteCount != 0)
        || byteCount > ring->bytesPerSlot) {
        if (ring != nullptr) {
            ring->droppedPacketCount.fetch_add(1, std::memory_order_relaxed);
        }
        return false;
    }

    const uint64_t write = ring->writeSequence.load(std::memory_order_relaxed);
    const uint64_t read = ring->readSequence.load(std::memory_order_acquire);
    if (write - read >= ring->slotCount) {
        ring->droppedPacketCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    const uint32_t slot = static_cast<uint32_t>(write % ring->slotCount);
    if (byteCount != 0) {
        std::memcpy(
            ring->storage + static_cast<size_t>(slot) * ring->bytesPerSlot,
            source,
            byteCount
        );
    }
    ring->packets[slot] = VHRealtimePacket {
        byteCount,
        frameCount,
        callbackNanoseconds
    };
    ring->writeSequence.store(write + 1, std::memory_order_release);
    return true;
}

bool VHRealtimeRingRead(VHRealtimeRing *ring,
                        void *destination,
                        uint32_t destinationCapacity,
                        VHRealtimePacket *packet) {
    if (ring == nullptr || packet == nullptr) {
        return false;
    }
    packet->byteCount = 0;
    packet->frameCount = 0;
    packet->callbackNanoseconds = 0;

    const uint64_t read = ring->readSequence.load(std::memory_order_relaxed);
    const uint64_t write = ring->writeSequence.load(std::memory_order_acquire);
    if (read == write) {
        return false;
    }

    const uint32_t slot = static_cast<uint32_t>(read % ring->slotCount);
    *packet = ring->packets[slot];
    if ((destination == nullptr && packet->byteCount != 0)
        || destinationCapacity < packet->byteCount) {
        return false;
    }
    if (packet->byteCount != 0) {
        std::memcpy(
            destination,
            ring->storage + static_cast<size_t>(slot) * ring->bytesPerSlot,
            packet->byteCount
        );
    }
    ring->readSequence.store(read + 1, std::memory_order_release);
    return true;
}

uint64_t VHRealtimeRingDroppedPacketCount(const VHRealtimeRing *ring) {
    if (ring == nullptr) {
        return 0;
    }
    return ring->droppedPacketCount.load(std::memory_order_relaxed);
}

OSStatus VHAUHALInputCreate(AudioDeviceID deviceID,
                            VHRealtimeRing *ring,
                            VHAUHALInput **output) {
    if (ring == nullptr || output == nullptr) {
        return kAudio_ParamError;
    }
    *output = nullptr;
    auto *input = new (std::nothrow) VHAUHALInput();
    if (input == nullptr) {
        return memFullErr;
    }
    input->ring = ring;

    AudioComponentDescription description {};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    const AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr) {
        delete input;
        return kAudio_ParamError;
    }

    // Required AUHAL setup order begins here.
    OSStatus status = AudioComponentInstanceNew(component, &input->unit);
    if (status != noErr) {
        delete input;
        return status;
    }

    UInt32 enabled = 1;
    status = AudioUnitSetProperty(
        input->unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1,
        &enabled,
        sizeof(enabled)
    );
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }

    UInt32 disabled = 0;
    status = AudioUnitSetProperty(
        input->unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0,
        &disabled,
        sizeof(disabled)
    );
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }

    status = AudioUnitSetProperty(
        input->unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceID,
        sizeof(deviceID)
    );
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }

    UInt32 formatSize = sizeof(input->format);
    status = AudioUnitGetProperty(
        input->unit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        1,
        &input->format,
        &formatSize
    );
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }

    UInt32 maximumFramesSize = sizeof(input->maximumFramesPerSlice);
    status = AudioUnitGetProperty(
        input->unit,
        kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global,
        0,
        &input->maximumFramesPerSlice,
        &maximumFramesSize
    );
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }

    status = AllocateCaptureStorage(input);
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }

    AURenderCallbackStruct callback {
        RenderInput,
        input
    };
    status = AudioUnitSetProperty(
        input->unit,
        kAudioOutputUnitProperty_SetInputCallback,
        kAudioUnitScope_Global,
        0,
        &callback,
        sizeof(callback)
    );
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }
    input->callbackInstalled = true;

    status = AudioUnitInitialize(input->unit);
    if (status != noErr) {
        RollBackCreate(input);
        delete input;
        return status;
    }
    input->initialized = true;
    mach_timebase_info(&input->timebase);
    if (input->timebase.denom == 0) {
        RollBackCreate(input);
        delete input;
        return kAudio_ParamError;
    }

    *output = input;
    return noErr;
}

OSStatus VHAUHALInputGetFormat(VHAUHALInput *input,
                               AudioStreamBasicDescription *format) {
    if (input == nullptr || format == nullptr) {
        return kAudio_ParamError;
    }
    *format = input->format;
    return noErr;
}

OSStatus VHAUHALInputStart(VHAUHALInput *input) {
    if (input == nullptr || input->unit == nullptr || !input->initialized) {
        return kAudio_ParamError;
    }
    if (input->started) {
        return noErr;
    }
    const OSStatus status = AudioOutputUnitStart(input->unit);
    if (status == noErr) {
        input->started = true;
    }
    return status;
}

OSStatus VHAUHALInputStop(VHAUHALInput *input) {
    if (input == nullptr) {
        return kAudio_ParamError;
    }
    if (!input->started) {
        return noErr;
    }
    const OSStatus status = AudioOutputUnitStop(input->unit);
    input->started = false;
    return status;
}

void VHAUHALInputDispose(VHAUHALInput *input) {
    if (input == nullptr) {
        return;
    }
    VHAUHALInputStop(input);
    if (input->initialized) {
        AudioUnitUninitialize(input->unit);
        input->initialized = false;
    }
    RemoveInputCallback(input);
    ReleaseCaptureStorage(input);
    if (input->unit != nullptr) {
        AudioComponentInstanceDispose(input->unit);
        input->unit = nullptr;
    }
    delete input;
}

OSStatus VHAudioDeviceInputCreate(
    AudioDeviceID deviceID,
    VHRealtimeRing *ring,
    VHAudioDeviceInput **output
) {
    if (deviceID == kAudioObjectUnknown || ring == nullptr || output == nullptr) {
        return kAudio_ParamError;
    }
    *output = nullptr;
    auto *input = new (std::nothrow) VHAudioDeviceInput();
    if (input == nullptr) {
        return memFullErr;
    }
    input->deviceID = deviceID;
    input->ring = ring;

    OSStatus status = ReadSingleInputStreamFormat(deviceID, &input->format);
    if (status != noErr) {
        delete input;
        return status;
    }

    AudioObjectPropertyAddress frameSizeAddress {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 frameSizeValueSize = sizeof(input->bufferFrameSize);
    status = AudioObjectGetPropertyData(
        deviceID,
        &frameSizeAddress,
        0,
        nullptr,
        &frameSizeValueSize,
        &input->bufferFrameSize
    );
    if (status != noErr) {
        delete input;
        return status;
    }

    status = AllocateDeviceInputStorage(input);
    if (status != noErr) {
        delete input;
        return status;
    }
    mach_timebase_info(&input->timebase);
    if (input->timebase.denom == 0) {
        delete[] input->packetStorage;
        delete input;
        return kAudio_ParamError;
    }

    status = AudioDeviceCreateIOProcID(
        deviceID,
        DeviceInputIOProc,
        input,
        &input->ioProcID
    );
    if (status != noErr) {
        delete[] input->packetStorage;
        delete input;
        return status;
    }
    *output = input;
    return noErr;
}

OSStatus VHAudioDeviceInputGetFormat(
    VHAudioDeviceInput *input,
    AudioStreamBasicDescription *format
) {
    if (input == nullptr || format == nullptr) {
        return kAudio_ParamError;
    }
    *format = input->format;
    return noErr;
}

OSStatus VHAudioDeviceInputGetMetrics(
    VHAudioDeviceInput *input,
    VHAudioDeviceInputMetrics *metrics
) {
    if (input == nullptr || metrics == nullptr) {
        return kAudio_ParamError;
    }
    metrics->callbackCount = input->callbackCount.load(
        std::memory_order_relaxed
    );
    metrics->sourcePacketCount = input->sourcePacketCount.load(
        std::memory_order_relaxed
    );
    metrics->sourceFrameCount = input->sourceFrameCount.load(
        std::memory_order_relaxed
    );
    metrics->sourceByteCount = input->sourceByteCount.load(
        std::memory_order_relaxed
    );
    metrics->ringWriteFailureCount = input->ringWriteFailureCount.load(
        std::memory_order_relaxed
    );
    metrics->lastStatus = input->lastStatus.load(std::memory_order_relaxed);
    return noErr;
}

OSStatus VHAudioDeviceInputStart(VHAudioDeviceInput *input) {
    if (input == nullptr
        || input->deviceID == kAudioObjectUnknown
        || input->ioProcID == nullptr) {
        return kAudio_ParamError;
    }
    if (input->started) {
        return noErr;
    }
    const OSStatus status = AudioDeviceStart(input->deviceID, input->ioProcID);
    if (status == noErr) {
        input->started = true;
    }
    return status;
}

OSStatus VHAudioDeviceInputStop(VHAudioDeviceInput *input) {
    if (input == nullptr) {
        return kAudio_ParamError;
    }
    if (!input->started) {
        return noErr;
    }
    const OSStatus status = AudioDeviceStop(input->deviceID, input->ioProcID);
    input->started = false;
    return status;
}

void VHAudioDeviceInputDispose(VHAudioDeviceInput *input) {
    if (input == nullptr) {
        return;
    }
    VHAudioDeviceInputStop(input);
    if (input->ioProcID != nullptr) {
        AudioDeviceDestroyIOProcID(input->deviceID, input->ioProcID);
        input->ioProcID = nullptr;
    }
    delete[] input->packetStorage;
    input->packetStorage = nullptr;
    delete input;
}
