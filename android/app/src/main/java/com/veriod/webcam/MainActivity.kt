package com.veriod.webcam

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Surface
import android.view.TextureView
import androidx.compose.ui.viewinterop.AndroidView
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat as CoreContextCompat
import kotlinx.coroutines.launch
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {

    private lateinit var streamer: AudioStreamer
    private lateinit var videoStreamer: VideoStreamer
    private var pendingStart: (() -> Unit)? = null
    private var pendingCamStart: (() -> Unit)? = null

    private val requestMicPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) pendingStart?.invoke()
            pendingStart = null
        }

    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* optional */ }

    private val requestCameraPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) pendingCamStart?.invoke()
            pendingCamStart = null
        }

    fun startMicService() {
        val intent = Intent(this, MicForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    fun stopMicService() {
        stopService(Intent(this, MicForegroundService::class.java))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        streamer = AudioStreamer(applicationContext)
        videoStreamer = VideoStreamer(applicationContext)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            CoreContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    MainScreen(
                        streamer = streamer,
                        videoStreamer = videoStreamer,
                        lifecycleOwner = this,
                        onRequestMic = { onGranted ->
                            if (ContextCompat.checkSelfPermission(
                                    this,
                                    Manifest.permission.RECORD_AUDIO,
                                ) == PackageManager.PERMISSION_GRANTED
                            ) {
                                onGranted()
                            } else {
                                pendingStart = onGranted
                                requestMicPermission.launch(Manifest.permission.RECORD_AUDIO)
                            }
                        },
                        onRequestCamera = { onGranted ->
                            if (ContextCompat.checkSelfPermission(
                                    this,
                                    Manifest.permission.CAMERA,
                                ) == PackageManager.PERMISSION_GRANTED
                            ) {
                                onGranted()
                            } else {
                                pendingCamStart = onGranted
                                requestCameraPermission.launch(Manifest.permission.CAMERA)
                            }
                        },
                        onStartService = { startMicService() },
                        onStopService = { stopMicService() },
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        streamer.shutdown()
        videoStreamer.shutdown()
        stopMicService()
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MainScreen(
    streamer: AudioStreamer,
    videoStreamer: VideoStreamer,
    lifecycleOwner: androidx.lifecycle.LifecycleOwner,
    onRequestMic: (onGranted: () -> Unit) -> Unit,
    onRequestCamera: (onGranted: () -> Unit) -> Unit,
    onStartService: () -> Unit,
    onStopService: () -> Unit,
) {
    var host by remember { mutableStateOf("192.168.29.215") }
    var port by remember { mutableStateOf("50001") }
    var videoPort by remember { mutableStateOf("50002") }
    var camOn by remember { mutableStateOf(false) }
    var muted by remember { mutableStateOf(streamer.muted) }
    var mode by remember { mutableStateOf(streamer.mode) }

    val micState by streamer.state.collectAsState()
    val micOn = micState is AudioStreamer.State.Running
    val videoState by videoStreamer.state.collectAsState()
    val camActive = videoState is VideoStreamer.State.Running

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("VeriodWebcam", style = MaterialTheme.typography.headlineMedium)

        OutlinedTextField(
            value = host,
            onValueChange = { host = it.trim() },
            label = { Text("Mac IP") },
            singleLine = true,
            enabled = !micOn,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = port,
            onValueChange = { new -> port = new.filter { it.isDigit() } },
            label = { Text("Port") },
            singleLine = true,
            enabled = !micOn,
            modifier = Modifier.fillMaxWidth(),
        )

        HorizontalDivider()

        // --- Microphone on/off -----------------------------------------------
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.fillMaxWidth(0.75f)) {
                Text("Microphone", style = MaterialTheme.typography.titleMedium)
                Text(
                    when (val s = micState) {
                        AudioStreamer.State.Idle -> "Off"
                        is AudioStreamer.State.Running ->
                            "Streaming to ${s.host}:${s.port} · ${s.packetsSent} packets"
                        is AudioStreamer.State.Error -> "Error: ${s.message}"
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Spacer(modifier = Modifier.fillMaxWidth(1f))
            Switch(
                checked = micOn,
                onCheckedChange = { checked ->
                    if (checked) {
                        val parsedPort = port.toIntOrNull()
                        if (host.isNotBlank() && parsedPort != null) {
                            onRequestMic {
                                onStartService()
                                streamer.startMic(host, parsedPort)
                            }
                        }
                    } else {
                        streamer.stopMic()
                        onStopService()
                    }
                },
            )
        }

        // --- Mute button -----------------------------------------------------
        Button(
            onClick = {
                muted = !muted
                streamer.muted = muted
            },
            enabled = micOn,
            colors = if (muted) ButtonDefaults.buttonColors(containerColor = Color(0xFFC62828))
                     else ButtonDefaults.buttonColors(),
            modifier = Modifier
                .fillMaxWidth()
                .height(60.dp),
            shape = RoundedCornerShape(12.dp),
        ) {
            Text(
                if (muted) "MUTED — tap to unmute" else "Tap to mute",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
            )
        }

        HorizontalDivider()

        // --- Noise suppression mode ------------------------------------------
        Text("Noise suppression", style = MaterialTheme.typography.titleMedium)
        Text(
            when (mode) {
                AudioStreamer.NoiseMode.CLEAN_FAR ->
                    "Default (far) — captures quiet/distant voice, room sounds pass through"
                AudioStreamer.NoiseMode.NOISE_MODERATE ->
                    "Moderate — VoIP-grade noise + echo cancel, close-talk voice"
                AudioStreamer.NoiseMode.NOISE_HIGH ->
                    "High — aggressive noise suppressor + AGC + voice boost"
                AudioStreamer.NoiseMode.RNNOISE ->
                    "RNNoise (neural, small) — kills keyboards / fans / background voices"
                AudioStreamer.NoiseMode.DEEPFILTERNET ->
                    "DeepFilterNet 3 (neural, best) — Krisp-tier cleanup, heavier on CPU"
            },
            style = MaterialTheme.typography.bodySmall,
        )
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            ModeChip("Default", mode == AudioStreamer.NoiseMode.CLEAN_FAR, micOn) {
                mode = AudioStreamer.NoiseMode.CLEAN_FAR
                streamer.mode = mode
            }
            ModeChip("Moderate", mode == AudioStreamer.NoiseMode.NOISE_MODERATE, micOn) {
                mode = AudioStreamer.NoiseMode.NOISE_MODERATE
                streamer.mode = mode
            }
            ModeChip("High", mode == AudioStreamer.NoiseMode.NOISE_HIGH, micOn) {
                mode = AudioStreamer.NoiseMode.NOISE_HIGH
                streamer.mode = mode
            }
            ModeChip("RNNoise", mode == AudioStreamer.NoiseMode.RNNOISE, micOn) {
                mode = AudioStreamer.NoiseMode.RNNOISE
                streamer.mode = mode
            }
            ModeChip("DFNet3", mode == AudioStreamer.NoiseMode.DEEPFILTERNET, micOn) {
                mode = AudioStreamer.NoiseMode.DEEPFILTERNET
                streamer.mode = mode
            }
        }
        if (micOn) {
            Text(
                "Toggle the mic off and back on to apply a new mode.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
            )
        }

        HorizontalDivider()

        UpdateRow(host = host)

        HorizontalDivider()

        // --- Camera ----------------------------------------------------------
        if (camActive) {
            AndroidView(
                factory = { ctx ->
                    TextureView(ctx).apply {
                        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
                                videoStreamer.setPreviewSurface(Surface(st))
                            }
                            override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) {}
                            override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                                videoStreamer.setPreviewSurface(null)
                                return true
                            }
                            override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
                        }
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(220.dp),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.fillMaxWidth(0.75f)) {
                Text("Camera", style = MaterialTheme.typography.titleMedium)
                Text(
                    when (val s = videoState) {
                        VideoStreamer.State.Idle -> "Off"
                        is VideoStreamer.State.Running ->
                            "Streaming video to $host:$videoPort · ${s.framesSent} frames"
                        is VideoStreamer.State.Error -> "Error: ${s.message}"
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Spacer(modifier = Modifier.fillMaxWidth(1f))
            Switch(
                checked = camOn || camActive,
                onCheckedChange = { checked ->
                    camOn = checked
                    if (checked) {
                        val vp = videoPort.toIntOrNull()
                        if (host.isNotBlank() && vp != null) {
                            onRequestCamera {
                                videoStreamer.start(lifecycleOwner, host, vp)
                            }
                        }
                    } else {
                        videoStreamer.stop()
                    }
                },
            )
        }
    }
}

@Composable
private fun UpdateRow(host: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf("Current: ${BuildConfig.VERSION_NAME} (code ${BuildConfig.VERSION_CODE})") }
    var busy by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    var progress by androidx.compose.runtime.remember { androidx.compose.runtime.mutableIntStateOf(0) }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("App update", style = MaterialTheme.typography.titleMedium)
        Text(
            status + if (busy) "  ·  downloading $progress%" else "",
            style = MaterialTheme.typography.bodySmall,
        )
        Button(
            enabled = !busy && host.isNotBlank(),
            onClick = {
                busy = true
                progress = 0
                status = "Checking Mac for new version…"
                scope.launch {
                    when (val r = Updater.check(host)) {
                        is Updater.CheckResult.UpToDate -> {
                            status = "Already on latest (code ${r.currentCode})."
                            busy = false
                        }
                        is Updater.CheckResult.Error -> {
                            status = "Update check failed: ${r.message}"
                            busy = false
                        }
                        is Updater.CheckResult.UpdateAvailable -> {
                            status = "Found v${r.remote.versionName} (code ${r.remote.versionCode}). Downloading…"
                            if (!context.packageManager.canRequestPackageInstalls()) {
                                val i = Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${context.packageName}"),
                                )
                                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                context.startActivity(i)
                                status = "Grant ‘Install unknown apps’ permission, then tap Update again."
                                busy = false
                                return@launch
                            }
                            val err = Updater.downloadAndInstall(context, host, r.remote) { p -> progress = p }
                            busy = false
                            status = err?.let { "Download failed: $it" }
                                ?: "Installer launched — confirm the update on screen."
                        }
                    }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (busy) "Updating…" else "Check for update")
        }
    }
}

@Composable
private fun ModeChip(label: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label) },
        enabled = enabled || !selected,
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = MaterialTheme.colorScheme.primary,
            selectedLabelColor = MaterialTheme.colorScheme.onPrimary,
        ),
    )
}
