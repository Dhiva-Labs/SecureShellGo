package com.dhivalabs.secure_shell_go

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Tells Dart when the device's default network changes, so an SSH session
 * can check its link — and reconnect over the new network — at once, rather
 * than finding out a minute and a half later from keep-alives that went
 * unanswered. The Dart half is `network_watch.dart`.
 *
 * It sends the raw facts only — "network X is now the default", "network X
 * is gone" — and Dart decides what they mean, where it can be tested.
 *
 * Registered only while Dart listens, which `SessionManager` does only while
 * a session is open: an app with nothing connected registers no callback.
 *
 * Needs ACCESS_NETWORK_STATE, a normal install-time permission.
 */
class NetworkWatchBridge(context: Context) : EventChannel.StreamHandler {

    companion object {
        const val CHANNEL = "com.dhivalabs.secure_shell_go/network"
    }

    private val connectivity =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)

    /** Callbacks arrive on a connectivity thread; the sink is main-thread only. */
    private val main = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        unregister()
        sink = events
        val manager = connectivity ?: return
        val watcher = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = send("available", network)
            override fun onLost(network: Network) = send("lost", network)
        }
        val registered = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                // The default network — the one new sockets use — which is
                // exactly the one an SSH session made over.
                manager.registerDefaultNetworkCallback(watcher)
            } else {
                // API 23 has no default-network callback; any network that
                // reaches the internet is the closest it offers.
                val request = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build()
                manager.registerNetworkCallback(request, watcher)
            }
        }.isSuccess
        if (registered) callback = watcher
    }

    override fun onCancel(arguments: Any?) {
        unregister()
        sink = null
    }

    fun dispose() = onCancel(null)

    private fun unregister() {
        val watcher = callback ?: return
        callback = null
        runCatching { connectivity?.unregisterNetworkCallback(watcher) }
    }

    private fun send(event: String, network: Network) {
        val payload = mapOf("event" to event, "network" to network.toString())
        main.post { sink?.success(payload) }
    }
}
