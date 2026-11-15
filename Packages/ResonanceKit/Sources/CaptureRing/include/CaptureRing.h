#ifndef RESONANCE_CAPTURE_RING_H
#define RESONANCE_CAPTURE_RING_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

typedef struct ResonanceCaptureRing ResonanceCaptureRing;

// Fixed-capacity single-producer/single-consumer queue. The audio callback is
// the sole producer and performs no allocation or locking.
ResonanceCaptureRing * _Nullable ResonanceCaptureRingCreate(
    uint32_t capacity, uint32_t maxFrames, uint32_t buffers,
    uint32_t channelsPerBuffer, uint32_t bytesPerFrame
);

void ResonanceCaptureRingDestroy(ResonanceCaptureRing * _Nullable ring);

void ResonanceCaptureRingWrite(
    ResonanceCaptureRing * _Nonnull ring, const AudioBufferList * _Nonnull input,
    const AudioTimeStamp * _Nonnull timestamp
);

// Returns 1 for a copied slot, 0 while empty, or -1 after an interruption.
// Destination buffers must have enough storage and advertise their capacity.
int ResonanceCaptureRingRead(
    ResonanceCaptureRing * _Nonnull ring, AudioBufferList * _Nonnull output,
    uint32_t * _Nonnull frames
);

#endif
