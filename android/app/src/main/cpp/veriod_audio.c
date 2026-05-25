#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "rnnoise.h"

/* RNNoise processes frames of exactly 480 samples at 48 kHz (10 ms).
 * That matches VeriodWebcam's frame size 1:1, so each UDP frame maps to
 * one RNNoise call. No buffering needed. */
#define RNN_FRAME 480
#define RNN_FRAME_BYTES (RNN_FRAME * 2)

JNIEXPORT jlong JNICALL
Java_com_veriod_webcam_RNNoise_nativeCreate(JNIEnv *env, jclass clazz) {
    DenoiseState *state = rnnoise_create(NULL);
    return (jlong)(intptr_t) state;
}

JNIEXPORT void JNICALL
Java_com_veriod_webcam_RNNoise_nativeDestroy(JNIEnv *env, jclass clazz, jlong handle) {
    DenoiseState *state = (DenoiseState *)(intptr_t) handle;
    if (state) rnnoise_destroy(state);
}

/* Process one 480-sample (960-byte) frame of PCM-16 LE in place. */
JNIEXPORT void JNICALL
Java_com_veriod_webcam_RNNoise_nativeProcessBytes(JNIEnv *env, jclass clazz,
                                                  jlong handle,
                                                  jbyteArray bytes,
                                                  jint offset,
                                                  jint byteLength) {
    if (byteLength != RNN_FRAME_BYTES) return;
    DenoiseState *state = (DenoiseState *)(intptr_t) handle;
    if (!state) return;

    jbyte *b = (*env)->GetByteArrayElements(env, bytes, NULL);
    if (!b) return;

    float buf[RNN_FRAME];
    for (int i = 0; i < RNN_FRAME; i++) {
        uint8_t lo = (uint8_t) b[offset + 2 * i];
        int8_t  hi = (int8_t)  b[offset + 2 * i + 1];
        int16_t s = (int16_t) (lo | ((uint16_t)(uint8_t) hi << 8));
        buf[i] = (float) s;
    }

    rnnoise_process_frame(state, buf, buf);

    for (int i = 0; i < RNN_FRAME; i++) {
        float v = buf[i];
        if (v > 32767.0f) v = 32767.0f;
        else if (v < -32768.0f) v = -32768.0f;
        int16_t s = (int16_t) v;
        b[offset + 2 * i] = (jbyte) (s & 0xff);
        b[offset + 2 * i + 1] = (jbyte) ((s >> 8) & 0xff);
    }

    (*env)->ReleaseByteArrayElements(env, bytes, b, 0);
}
