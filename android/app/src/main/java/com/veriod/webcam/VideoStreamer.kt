package com.veriod.webcam

import android.annotation.SuppressLint
import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * Capture rear camera → H.264 encode → UDP to Mac. Whatever the sensor sees
 * is what the Mac shows. No rotation, no orientation logic.
 */
class VideoStreamer(private val context: Context) {

    sealed interface State {
        data object Idle : State
        data class Running(val framesSent: Long) : State
        data class Error(val message: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val mainScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private val ioScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var codec: MediaCodec? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var drainJob: Job? = null
    private var socket: DatagramSocket? = null

    private val previewLock = Any()
    private var previewSurface: Surface? = null
    private var localDecoder: MediaCodec? = null
    private var cachedCsd: ByteArray? = null

    fun setPreviewSurface(surface: Surface?) {
        synchronized(previewLock) {
            if (previewSurface === surface) return
            releaseLocalDecoder()
            previewSurface = surface
            if (surface != null) configureLocalDecoder(surface)
        }
    }

    private fun configureLocalDecoder(surface: Surface) {
        try {
            val dec = MediaCodec.createDecoderByType("video/avc")
            val fmt = MediaFormat.createVideoFormat("video/avc", WIDTH, HEIGHT)
            dec.configure(fmt, surface, null, 0)
            dec.start()
            localDecoder = dec
            cachedCsd?.let { feedLocalDecoder(it, MediaCodec.BUFFER_FLAG_CODEC_CONFIG) }
        } catch (_: Throwable) {
            localDecoder = null
        }
    }

    private fun releaseLocalDecoder() {
        try { localDecoder?.stop() } catch (_: Throwable) {}
        try { localDecoder?.release() } catch (_: Throwable) {}
        localDecoder = null
    }

    private fun feedLocalDecoder(bytes: ByteArray, flags: Int) {
        val dec = synchronized(previewLock) { localDecoder } ?: return
        try {
            val idx = dec.dequeueInputBuffer(0)
            if (idx >= 0) {
                dec.getInputBuffer(idx)?.let { it.clear(); it.put(bytes) }
                dec.queueInputBuffer(idx, 0, bytes.size, System.nanoTime() / 1000, flags)
            }
            val info = MediaCodec.BufferInfo()
            while (true) {
                val oi = dec.dequeueOutputBuffer(info, 0)
                if (oi < 0) break
                dec.releaseOutputBuffer(oi, true)
            }
        } catch (_: Throwable) {}
    }

    fun start(lifecycleOwner: LifecycleOwner, host: String, port: Int) {
        stop()
        try {
            val format = MediaFormat.createVideoFormat("video/avc", WIDTH, HEIGHT).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, KEYFRAME_INTERVAL_S)
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
                setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel42)
            }
            val c = MediaCodec.createEncoderByType("video/avc")
            c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val inputSurface = c.createInputSurface()
            c.start()
            codec = c

            socket = DatagramSocket()
            val address = InetAddress.getByName(host)

            drainJob = ioScope.launch { drainEncoder(c, socket!!, address, port) }

            mainScope.launch {
                try {
                    setupCamera(lifecycleOwner, inputSurface)
                    _state.value = State.Running(0L)
                } catch (t: Throwable) {
                    _state.value = State.Error(t.message ?: "camera setup")
                    stop()
                }
            }
        } catch (t: Throwable) {
            _state.value = State.Error(t.message ?: "codec init")
            stop()
        }
    }

    fun stop() {
        drainJob?.cancel()
        drainJob = null
        mainScope.launch {
            try { cameraProvider?.unbindAll() } catch (_: Throwable) {}
            cameraProvider = null
        }
        try { codec?.stop() } catch (_: Throwable) {}
        runCatching { codec?.release() }
        codec = null
        socket?.close()
        socket = null
        synchronized(previewLock) { releaseLocalDecoder() }
        cachedCsd = null
        _state.value = State.Idle
    }

    fun shutdown() {
        stop()
        mainScope.cancel()
        ioScope.cancel()
    }

    @SuppressLint("RestrictedApi")
    private suspend fun setupCamera(lifecycleOwner: LifecycleOwner, surface: Surface) {
        val provider = getProvider()
        cameraProvider = provider
        provider.unbindAll()

        val preview = Preview.Builder()
            .setTargetResolution(Size(WIDTH, HEIGHT))
            .build()
        preview.setSurfaceProvider { request ->
            request.provideSurface(surface, ContextCompat.getMainExecutor(context)) { }
        }

        provider.bindToLifecycle(
            lifecycleOwner,
            CameraSelector.DEFAULT_BACK_CAMERA,
            preview,
        )
    }

    private suspend fun getProvider(): ProcessCameraProvider =
        suspendCancellableCoroutine { cont ->
            val f = ProcessCameraProvider.getInstance(context)
            f.addListener({
                try { cont.resumeWith(Result.success(f.get())) }
                catch (t: Throwable) { cont.resumeWith(Result.failure(t)) }
            }, ContextCompat.getMainExecutor(context))
        }

    private fun drainEncoder(
        c: MediaCodec,
        sock: DatagramSocket,
        address: InetAddress,
        port: Int,
    ) {
        val info = MediaCodec.BufferInfo()
        var frameId = 0
        var seq = 0
        var csd: ByteArray? = null
        var framesSent = 0L

        while (drainJob?.isActive == true) {
            val idx = try { c.dequeueOutputBuffer(info, 10_000) } catch (_: Throwable) { return }
            if (idx < 0) continue
            val buffer = c.getOutputBuffer(idx)
            if (buffer == null) {
                runCatching { c.releaseOutputBuffer(idx, false) }
                continue
            }
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)
            val bytes = ByteArray(info.size)
            buffer.get(bytes)
            runCatching { c.releaseOutputBuffer(idx, false) }

            if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                csd = bytes
                cachedCsd = bytes
                feedLocalDecoder(bytes, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
                continue
            }

            feedLocalDecoder(bytes, 0)

            val payload =
                if ((info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 && csd != null) {
                    csd!! + bytes
                } else bytes

            val chunks = (payload.size + MAX_CHUNK_PAYLOAD - 1) / MAX_CHUNK_PAYLOAD
            for (ci in 0 until chunks) {
                val start = ci * MAX_CHUNK_PAYLOAD
                val end = minOf(start + MAX_CHUNK_PAYLOAD, payload.size)
                val partSize = end - start
                val packet = ByteArray(HEADER_SIZE + partSize)
                packet[0] = PACKET_TYPE_VIDEO
                packet[1] = ((seq shr 16) and 0xFF).toByte()
                packet[2] = ((seq shr 8) and 0xFF).toByte()
                packet[3] = (seq and 0xFF).toByte()
                seq = (seq + 1) and 0xFFFFFF
                packet[4] = (frameId and 0xFF).toByte()
                packet[5] = ((frameId shr 8) and 0xFF).toByte()
                packet[6] = ci.toByte()
                packet[7] = chunks.toByte()
                System.arraycopy(payload, start, packet, HEADER_SIZE, partSize)
                try {
                    sock.send(DatagramPacket(packet, packet.size, address, port))
                } catch (_: Throwable) { return }
            }
            frameId = (frameId + 1) and 0xFFFF
            framesSent += 1
            if (framesSent % 30 == 0L) {
                _state.value = State.Running(framesSent)
            }
        }
    }

    companion object {
        const val WIDTH = 1920
        const val HEIGHT = 1080
        const val FPS = 60
        const val BITRATE = 6_000_000
        const val KEYFRAME_INTERVAL_S = 2
        const val PACKET_TYPE_VIDEO: Byte = 0x02
        const val MAX_CHUNK_PAYLOAD = 1400
        const val HEADER_SIZE = 8
    }
}
