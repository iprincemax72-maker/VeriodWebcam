package com.veriod.webcam

import android.content.Context
import com.rikorose.deepfilternet.NativeDeepFilterNet
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Thin wrapper around Kaleyra's DeepFilterNet JNI binding.
 *
 * DeepFilterNet expects 48 kHz mono PCM-16 LE in 10 ms frames (960 bytes).
 * Our AudioStreamer already produces exactly that, so each UDP frame maps
 * 1:1 to a DFN call — no extra buffering.
 */
class DeepFilter(context: Context, attenuationDb: Float = 30f) : AutoCloseable {

    private val native: NativeDeepFilterNet = NativeDeepFilterNet(context).apply {
        setAttenuationLimit(attenuationDb)
    }
    val frameBytes: Int = native.frameLength.toInt()

    private val scratch: ByteBuffer = ByteBuffer
        .allocateDirect(frameBytes)
        .order(ByteOrder.LITTLE_ENDIAN)

    /** Denoise `length` bytes in place starting at `offset`. No-op if size mismatches. */
    fun processBytes(buffer: ByteArray, offset: Int, length: Int) {
        if (length != frameBytes) return
        scratch.clear()
        scratch.put(buffer, offset, length)
        scratch.position(0)
        try {
            native.processFrame(scratch)
        } catch (_: Throwable) {
            return
        }
        scratch.position(0)
        scratch.get(buffer, offset, length)
    }

    override fun close() {
        runCatching { native.release() }
    }
}
