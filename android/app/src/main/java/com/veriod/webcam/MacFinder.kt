package com.veriod.webcam

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/** Finds the Veriod Mac app on Wi-Fi via its "_veriod._udp" Bonjour ad. */
object MacFinder {
    data class Mac(val name: String, val host: String, val port: Int)

    @Suppress("DEPRECATION")
    fun find(context: Context): Flow<Mac> = callbackFlow {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager

        fun resolve(info: NsdServiceInfo) {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(si: NsdServiceInfo, code: Int) {
                    // only one resolve at a time is allowed on older androids, so retry
                    if (code == NsdManager.FAILURE_ALREADY_ACTIVE) {
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ resolve(si) }, 300)
                    }
                }

                override fun onServiceResolved(si: NsdServiceInfo) {
                    val addr = si.host?.hostAddress ?: return
                    if (addr.contains(':')) return // skip ipv6
                    trySend(Mac(si.serviceName, addr, si.port))
                }
            })
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {}
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onServiceFound(info: NsdServiceInfo) = resolve(info)
        }

        nsd.discoverServices("_veriod._udp", NsdManager.PROTOCOL_DNS_SD, listener)
        awaitClose { runCatching { nsd.stopServiceDiscovery(listener) } }
    }
}
