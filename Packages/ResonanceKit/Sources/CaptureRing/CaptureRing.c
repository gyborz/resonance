#include "CaptureRing.h"

#include <math.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2 &&
               ATOMIC_BOOL_LOCK_FREE == 2, "The audio callback requires lock-free atomics");

struct ResonanceCaptureRing {
    uint32_t capacity;
    uint32_t buffers;
    uint32_t channelsPerBuffer;
    uint32_t bytesPerFrame;
    size_t planeCapacityBytes;
    size_t slotCapacityBytes;
    uint32_t *frameCounts;
    unsigned char *storage;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic bool interrupted;
    // Timestamp state belongs exclusively to the producer.
    bool hasExpectedSampleTime;
    double expectedSampleTime;
};

ResonanceCaptureRing *ResonanceCaptureRingCreate(
    uint32_t capacity, uint32_t maxFrames, uint32_t buffers,
    uint32_t channelsPerBuffer, uint32_t bytesPerFrame
) {
    size_t planeCapacityBytes, slotCapacityBytes, storageBytes;
    if (capacity == 0 || maxFrames == 0 || buffers == 0 ||
        channelsPerBuffer == 0 || bytesPerFrame == 0 ||
        __builtin_mul_overflow(maxFrames, bytesPerFrame, &planeCapacityBytes) ||
        __builtin_mul_overflow(planeCapacityBytes, buffers, &slotCapacityBytes) ||
        __builtin_mul_overflow(slotCapacityBytes, capacity, &storageBytes) ||
        storageBytes > 64 * 1024 * 1024) {
        return NULL;
    }

    ResonanceCaptureRing *ring = calloc(1, sizeof(*ring));
    if (ring == NULL) {
        return NULL;
    }

    ring->storage = malloc(storageBytes);
    ring->frameCounts = calloc(capacity, sizeof(*ring->frameCounts));
    if (ring->storage == NULL || ring->frameCounts == NULL) {
        ResonanceCaptureRingDestroy(ring);
        return NULL;
    }

    // Touch storage before the first real-time write.
    memset(ring->storage, 0x01, storageBytes);
    ring->capacity = capacity;
    ring->buffers = buffers;
    ring->channelsPerBuffer = channelsPerBuffer;
    ring->bytesPerFrame = bytesPerFrame;
    ring->planeCapacityBytes = planeCapacityBytes;
    ring->slotCapacityBytes = slotCapacityBytes;
    atomic_init(&ring->writeIndex, 0);
    atomic_init(&ring->readIndex, 0);
    atomic_init(&ring->interrupted, false);
    return ring;
}

void ResonanceCaptureRingDestroy(ResonanceCaptureRing *ring) {
    if (ring != NULL) {
        free(ring->frameCounts);
        free(ring->storage);
        free(ring);
    }
}

static bool validInput(ResonanceCaptureRing *ring, const AudioBufferList *input, uint32_t bytes) {
    if (input->mNumberBuffers != ring->buffers ||
        bytes > ring->planeCapacityBytes || bytes % ring->bytesPerFrame != 0) {
        return false;
    }
    const AudioBuffer *planes = (const AudioBuffer *)((const unsigned char *)input + offsetof(AudioBufferList, mBuffers));
    for (uint32_t i = 0; i < ring->buffers; ++i) {
        const AudioBuffer *buffer = &planes[i];
        if (buffer->mDataByteSize != bytes ||
            (bytes != 0 && (buffer->mNumberChannels != ring->channelsPerBuffer || buffer->mData == NULL))) {
            return false;
        }
    }
    return true;
}

static bool advanceTimestamp(
    ResonanceCaptureRing *ring, const AudioTimeStamp *timestamp, uint32_t frames
) {
    if ((timestamp->mFlags & kAudioTimeStampSampleTimeValid) != 0) {
        const double sampleTime = timestamp->mSampleTime;
        if (!isfinite(sampleTime) ||
            (ring->hasExpectedSampleTime && fabs(sampleTime - ring->expectedSampleTime) > 0.5)) {
            return false;
        }
        ring->hasExpectedSampleTime = true;
        ring->expectedSampleTime = sampleTime;
    }
    if (ring->hasExpectedSampleTime) {
        ring->expectedSampleTime += frames;
    }
    return true;
}

void ResonanceCaptureRingWrite(
    ResonanceCaptureRing *ring, const AudioBufferList *input, const AudioTimeStamp *timestamp
) {
    if (atomic_load_explicit(&ring->interrupted, memory_order_relaxed) || input->mNumberBuffers == 0) {
        return;
    }

    const uint32_t bytes = input->mBuffers[0].mDataByteSize;
    if (!validInput(ring, input, bytes)) {
        atomic_store_explicit(&ring->interrupted, true, memory_order_release);
        return;
    }
    if (bytes == 0) {
        return;
    }

    const uint32_t frames = bytes / ring->bytesPerFrame;
    const uint64_t writeIndex = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    const uint64_t readIndex = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    if (writeIndex - readIndex >= ring->capacity || !advanceTimestamp(ring, timestamp, frames)) {
        atomic_store_explicit(&ring->interrupted, true, memory_order_release);
        return;
    }

    const size_t slot = writeIndex % ring->capacity;
    unsigned char *destination = ring->storage + slot * ring->slotCapacityBytes;
    const AudioBuffer *planes = (const AudioBuffer *)((const unsigned char *)input + offsetof(AudioBufferList, mBuffers));
    for (uint32_t i = 0; i < ring->buffers; ++i) {
        memcpy(destination + i * ring->planeCapacityBytes, planes[i].mData, bytes);
    }
    ring->frameCounts[slot] = frames;
    atomic_store_explicit(&ring->writeIndex, writeIndex + 1, memory_order_release);
}

int ResonanceCaptureRingRead(ResonanceCaptureRing *ring, AudioBufferList *output, uint32_t *frames) {
    if (atomic_load_explicit(&ring->interrupted, memory_order_acquire)) {
        return -1;
    }

    const uint64_t readIndex = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    const uint64_t writeIndex = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    if (readIndex == writeIndex) {
        return 0;
    }
    if (output->mNumberBuffers != ring->buffers) {
        return -1;
    }

    const size_t slot = readIndex % ring->capacity;
    const size_t bytes = (size_t)ring->frameCounts[slot] * ring->bytesPerFrame;
    const unsigned char *source = ring->storage + slot * ring->slotCapacityBytes;
    AudioBuffer *planes = (AudioBuffer *)((unsigned char *)output + offsetof(AudioBufferList, mBuffers));
    for (uint32_t i = 0; i < ring->buffers; ++i) {
        AudioBuffer *buffer = &planes[i];
        if (buffer->mNumberChannels != ring->channelsPerBuffer ||
            buffer->mData == NULL || buffer->mDataByteSize < bytes) {
            return -1;
        }
        memcpy(buffer->mData, source + i * ring->planeCapacityBytes, bytes);
    }
    *frames = ring->frameCounts[slot];
    atomic_store_explicit(&ring->readIndex, readIndex + 1, memory_order_release);
    return 1;
}
