package com.veriod.webcam

/**
 * Thin Kotlin wrapper over RNNoise (xiph/rnnoise).
 *
 * Processes exactly 480 PCM-16 LE samples (10 ms @ 48 kHz, 960 bytes) at a
 * time — matching VeriodWebcam's UDP frame size, so no extra buffering is
 * needed.
 */
class RNNoise : AutoCloseable {

    private var handle: Long = nativeCreate()

    /** Denoise 960 bytes (480 samples) in place. */
    fun processBytes(buffer: ByteArray, offset: Int = 0) {
        if (handle == 0L) return
        nativeProcessBytes(handle, buffer, offset, 960)
    }

    override fun close() {
        if (handle != 0L) {
            nativeDestroy(handle)
            handle = 0L
        }
    }

    companion object {
        init {
            System.loadLibrary("veriod_audio")
        }

        @JvmStatic external fun nativeCreate(): Long
        @JvmStatic external fun nativeDestroy(handle: Long)
        @JvmStatic external fun nativeProcessBytes(
            handle: Long,
            bytes: ByteArray,
            offset: Int,
            byteLength: Int,
        )
    }
}
