#ifndef VOXHALO_REALTIME_AUDIO_H
#define VOXHALO_REALTIME_AUDIO_H

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t VHRealtimeAudioBridgeVersion(void);

typedef struct VHRealtimeRing VHRealtimeRing;
typedef struct VHAUHALInput VHAUHALInput;

typedef struct {
    uint32_t byteCount;
    uint32_t frameCount;
    uint64_t callbackNanoseconds;
} VHRealtimePacket;

VHRealtimeRing *VHRealtimeRingCreate(uint32_t slotCount, uint32_t bytesPerSlot);
void VHRealtimeRingDestroy(VHRealtimeRing *ring);
void VHRealtimeRingReset(VHRealtimeRing *ring);
bool VHRealtimeRingWrite(VHRealtimeRing *ring,
                         const void *source,
                         uint32_t byteCount,
                         uint32_t frameCount,
                         uint64_t callbackNanoseconds);
bool VHRealtimeRingRead(VHRealtimeRing *ring,
                        void *destination,
                        uint32_t destinationCapacity,
                        VHRealtimePacket *packet);
uint64_t VHRealtimeRingDroppedPacketCount(const VHRealtimeRing *ring);

OSStatus VHAUHALInputCreate(AudioDeviceID deviceID,
                            VHRealtimeRing *ring,
                            VHAUHALInput **output);
OSStatus VHAUHALInputGetFormat(VHAUHALInput *input,
                               AudioStreamBasicDescription *format);
OSStatus VHAUHALInputStart(VHAUHALInput *input);
OSStatus VHAUHALInputStop(VHAUHALInput *input);
void VHAUHALInputDispose(VHAUHALInput *input);

#ifdef __cplusplus
}
#endif

#endif
