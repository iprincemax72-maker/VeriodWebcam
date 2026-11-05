package com.veriod.webcam

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * Captures mic audio and streams 10 ms frames of PCM-16 LE mono 48 kHz over UDP.
 *
 * Wire format:
 *   byte 0      : packet type (0x01 = audio)
 *   bytes 1..3  : 24-bit big-endian sequence
 *   bytes 4..N  : PCM-16 LE payload (960 bytes for 10 ms)
 *
 * Three NoiseMode profiles control the audio source, built-in effects, and
 * software gain applied before transmission:
 *
 *   CLEAN_FAR        - mic source, no effects, 2× software gain (captures room)
 *   NOISE_MODERATE   - VOICE_COMMUNICATION source + AGC (OS default VoIP path)
 *   NOISE_HIGH       - VOICE_COMMUNICATION + NoiseSuppressor + AGC + 1.5× gain
 */
class AudioStreamer(private val appContext: android.content.Context? = null) {

    enum class NoiseMode { CLEAN_FAR, NOISE_MODERATE, NOISE_HIGH, RNNOISE, DEEPFILTERNET }

    sealed interface State {
        data object Idle : State
        data class Running(val host: String, val port: Int, val packetsSent: Long) : State
        data class Error(val message: String) : State
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    @Volatile var muted: Boolean = false
    @Volatile var mode: NoiseMode = NoiseMode.NOISE_MODERATE

    private var job: Job? = null

    @SuppressLint("MissingPermission")
    fun startMic(host: String, port: Int) {
        stopMic()
        job = scope.launch {
            var recorder: AudioRecord? = null
            var socket: DatagramSocket? = null
            var rnn: RNNoise? = null
            var dfn: DeepFilter? = null
            val fx = mutableListOf<android.media.audiofx.AudioEffect>()
            try {
                val minBuf = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                ).coerceAtLeast(BYTES_PER_FRAME * 2)

                val activeMode = mode
                val source = when (activeMode) {
                    NoiseMode.CLEAN_FAR -> MediaRecorder.AudioSource.MIC
                    NoiseMode.NOISE_MODERATE -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
                    NoiseMode.NOISE_HIGH -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
                    NoiseMode.RNNOISE -> MediaRecorder.AudioSource.MIC
                    NoiseMode.DEEPFILTERNET -> MediaRecorder.AudioSource.MIC
                }

                recorder = AudioRecord(
                    source,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    minBuf,
                )
                if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                    _state.value = State.Error("AudioRecord failed to initialize")
                    return@launch
                }

                val sessionId = recorder.audioSessionId
                if (activeMode == NoiseMode.NOISE_HIGH && NoiseSuppressor.isAvailable()) {
                    runCatching { NoiseSuppressor.create(sessionId) }
                        .getOrNull()?.also { it.enabled = true; fx.add(it) }
                }
                if ((activeMode == NoiseMode.NOISE_MODERATE || activeMode == NoiseMode.NOISE_HIGH)
                    && AutomaticGainControl.isAvailable()
                ) {
                    runCatching { AutomaticGainControl.create(sessionId) }
                        .getOrNull()?.also { it.enabled = true; fx.add(it) }
                }

                val gain: Float = when (activeMode) {
                    NoiseMode.CLEAN_FAR -> 2.0f
                    NoiseMode.NOISE_MODERATE -> 1.0f
                    NoiseMode.NOISE_HIGH -> 1.5f
                    NoiseMode.RNNOISE -> 2.5f
                    NoiseMode.DEEPFILTERNET -> 2.0f
                }

                if (activeMode == NoiseMode.RNNOISE) {
                    rnn = runCatching { RNNoise() }.getOrNull()
                }
                if (activeMode == NoiseMode.DEEPFILTERNET) {
                    val ctx = appContext
                    if (ctx != null) {
                        dfn = runCatching { DeepFilter(ctx) }.getOrNull()
                    }
                }

                socket = DatagramSocket()
                val address = InetAddress.getByName(host)

                val audioBuf = ByteArray(BYTES_PER_FRAME)
                val packet = ByteArray(HEADER_SIZE + BYTES_PER_FRAME)
                packet[0] = PACKET_TYPE_AUDIO
                var seq = 0
                var packetsSent = 0L

                recorder.startRecording()
                _state.value = State.Running(host, port, 0L)

                var micFails = 0
                while (isActive) {
                    var read = 0
                    var micDied = false
                    while (read < BYTES_PER_FRAME) {
                        val n = recorder!!.read(audioBuf, read, BYTES_PER_FRAME - read)
                        if (n < 0) {
                            micDied = true
                            break
                        }
                        if (n == 0) break
                        read += n
                    }
                    if (micDied) {
                        // read() error used to spin here and send nothing, so the
                        // Mac sat on "Phone stopped sending" with the switch still on.
                        micFails += 1
                        if (micFails > 5) throw IllegalStateException("Mic read failed")
                        runCatching { recorder?.stop() }
                        recorder?.release()
                        fx.forEach { runCatching { it.release() } }
                        fx.clear()
                        val again = AudioRecord(
                            source,
                            SAMPLE_RATE,
                            AudioFormat.CHANNEL_IN_MONO,
                            AudioFormat.ENCODING_PCM_16BIT,
                            minBuf,
                        )
                        if (again.state != AudioRecord.STATE_INITIALIZED) {
                            again.release()
                            throw IllegalStateException("AudioRecord failed to initialize")
                        }
                        recorder = again
                        val sid = again.audioSessionId
                        if (activeMode == NoiseMode.NOISE_HIGH && NoiseSuppressor.isAvailable()) {
                            runCatching { NoiseSuppressor.create(sid) }
                                .getOrNull()?.also { it.enabled = true; fx.add(it) }
                        }
                        if ((activeMode == NoiseMode.NOISE_MODERATE || activeMode == NoiseMode.NOISE_HIGH)
                            && AutomaticGainControl.isAvailable()
                        ) {
                            runCatching { AutomaticGainControl.create(sid) }
                                .getOrNull()?.also { it.enabled = true; fx.add(it) }
                        }
                        again.startRecording()
                        continue
                    }
                    micFails = 0
                    if (read <= 0) {
                        Thread.sleep(10)
                        continue
                    }

                    packet[1] = ((seq shr 16) and 0xFF).toByte()
                    packet[2] = ((seq shr 8) and 0xFF).toByte()
                    packet[3] = (seq and 0xFF).toByte()
                    seq = (seq + 1) and 0xFFFFFF

                    if (muted) {
                        java.util.Arrays.fill(packet, HEADER_SIZE, HEADER_SIZE + read, 0)
                    } else {
                        if (rnn != null && read == BYTES_PER_FRAME) {
                            rnn.processBytes(audioBuf, 0)
                        }
                        if (dfn != null && read == BYTES_PER_FRAME) {
                            dfn.processBytes(audioBuf, 0, read)
                        }
                        if (gain != 1.0f) {
                            applyGain(audioBuf, read, gain, packet, HEADER_SIZE)
                        } else {
                            System.arraycopy(audioBuf, 0, packet, HEADER_SIZE, read)
                        }
                    }

                    val dp = DatagramPacket(packet, HEADER_SIZE + read, address, port)
                    try {
                        socket!!.send(dp)
                    } catch (e: IOException) {
                        // one wifi blip used to kill the whole stream
                        runCatching { socket?.close() }
                        socket = DatagramSocket()
                        continue
                    }

                    packetsSent += 1
                    if (packetsSent % 50 == 0L) {
                        _state.value = State.Running(host, port, packetsSent)
                    }
                }
            } catch (t: Throwable) {
                _state.value = State.Error(t.message ?: t.javaClass.simpleName)
            } finally {
                fx.forEach { runCatching { it.release() } }
                runCatching { recorder?.stop() }
                recorder?.release()
                socket?.close()
                runCatching { rnn?.close() }
                runCatching { dfn?.close() }
                if (_state.value is State.Running) {
                    _state.value = State.Idle
                }
            }
        }
    }

    fun stopMic() {
        job?.cancel()
        job = null
        if (_state.value is State.Running) {
            _state.value = State.Idle
        }
    }

    fun shutdown() {
        stopMic()
        scope.cancel()
    }

    /** Multiply PCM-16 LE samples by `gain` into `dst` starting at `dstOffset`, with saturation. */
    private fun applyGain(src: ByteArray, srcLen: Int, gain: Float, dst: ByteArray, dstOffset: Int) {
        var i = 0
        var o = dstOffset
        while (i < srcLen - 1) {
            val lo = src[i].toInt() and 0xFF
            val hi = src[i + 1].toInt()
            val s = (lo or (hi shl 8)).toShort().toInt()
            var amp = (s * gain).toInt()
            if (amp > 32767) amp = 32767 else if (amp < -32768) amp = -32768
            dst[o] = (amp and 0xFF).toByte()
            dst[o + 1] = ((amp shr 8) and 0xFF).toByte()
            i += 2
            o += 2
        }
    }

    companion object {
        private const val SAMPLE_RATE = 48_000
        private const val FRAME_MS = 10
        private const val SAMPLES_PER_FRAME = SAMPLE_RATE * FRAME_MS / 1000
        private const val BYTES_PER_FRAME = SAMPLES_PER_FRAME * 2
        private const val HEADER_SIZE = 4
        private const val PACKET_TYPE_AUDIO: Byte = 0x01
    }
}
