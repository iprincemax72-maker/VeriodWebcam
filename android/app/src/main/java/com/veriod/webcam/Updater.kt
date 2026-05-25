package com.veriod.webcam

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Fetches `version.json` from the Mac HTTP server (port 8765), compares with
 * this APK's versionCode, downloads the new APK if newer, and hands it to
 * the Android package installer.
 */
object Updater {

    data class RemoteVersion(
        val versionCode: Int,
        val versionName: String,
        val apk: String,
    )

    sealed interface CheckResult {
        data class UpToDate(val currentCode: Int) : CheckResult
        data class UpdateAvailable(val current: Int, val remote: RemoteVersion) : CheckResult
        data class Error(val message: String) : CheckResult
    }

    private const val UPDATE_PORT = 8765
    private const val VERSION_PATH = "/version.json"

    suspend fun check(host: String): CheckResult = withContext(Dispatchers.IO) {
        val current = BuildConfig.VERSION_CODE
        try {
            val url = URL("http://$host:$UPDATE_PORT$VERSION_PATH")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5_000
                readTimeout = 5_000
                requestMethod = "GET"
            }
            conn.inputStream.use { input ->
                val json = JSONObject(input.bufferedReader().readText())
                val remote = RemoteVersion(
                    versionCode = json.getInt("versionCode"),
                    versionName = json.optString("versionName", "?"),
                    apk = json.optString("apk", "VeriodWebcam.apk"),
                )
                if (remote.versionCode > current) {
                    CheckResult.UpdateAvailable(current, remote)
                } else {
                    CheckResult.UpToDate(current)
                }
            }
        } catch (t: Throwable) {
            CheckResult.Error(t.message ?: t.javaClass.simpleName)
        }
    }

    suspend fun downloadAndInstall(
        context: Context,
        host: String,
        remote: RemoteVersion,
        onProgress: (Int) -> Unit = {},
    ): String? = withContext(Dispatchers.IO) {
        try {
            val url = URL("http://$host:$UPDATE_PORT/${remote.apk}")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5_000
                readTimeout = 20_000
                requestMethod = "GET"
            }
            val total = conn.contentLengthLong.coerceAtLeast(1L)
            val dir = File(context.cacheDir, "updates").apply { mkdirs() }
            val out = File(dir, "VeriodWebcam-${remote.versionCode}.apk")
            conn.inputStream.use { input ->
                out.outputStream().use { sink ->
                    val buf = ByteArray(64 * 1024)
                    var written = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        sink.write(buf, 0, n)
                        written += n
                        onProgress(((written * 100) / total).toInt().coerceAtMost(100))
                    }
                }
            }
            // Launch the Android package installer.
            val authority = "${context.packageName}.fileprovider"
            val uri = FileProvider.getUriForFile(context, authority, out)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            }
            context.startActivity(intent)
            null
        } catch (t: Throwable) {
            t.message ?: t.javaClass.simpleName
        }
    }
}
