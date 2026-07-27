package com.dhivalabs.secure_shell_go

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val KEEP_AWAKE_CHANNEL = "com.dhivalabs.secure_shell_go/keep_awake"
        private const val SESSION_SERVICE_CHANNEL =
            "com.dhivalabs.secure_shell_go/session_service"

        /** Distinct from StorageBridge's codes so the two never collide. */
        private const val REQUEST_POST_NOTIFICATIONS = 0x5350
    }

    private var storage: StorageBridge? = null

    /**
     * Asked at most once per process. A user who said no to notifications is
     * not going to enjoy being asked again every time they connect, and the
     * service runs either way — on Android 13+ a denied POST_NOTIFICATIONS
     * only means the ongoing notification is hidden, not that the foreground
     * service is refused.
     */
    private var notificationPermissionAsked = false

    /**
     * The label of the session currently holding the service open, or null if
     * none is. Kept so the notification can be re-posted if the user grants
     * POST_NOTIFICATIONS *after* the service has already started — see
     * [onRequestPermissionsResult].
     */
    private var activeSessionLabel: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val bridge = StorageBridge(this)
        storage = bridge
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            StorageBridge.CHANNEL,
        ).setMethodCallHandler(bridge)

        // A single FLAG_KEEP_SCREEN_ON toggle for Settings' "keep screen
        // awake" option — see keep_awake.dart for why this is a channel
        // rather than a plugin.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            KEEP_AWAKE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Start/stop the foreground service that keeps the process — and so
        // the SSH socket — alive while the user is in another app. The
        // reference counting lives on the Dart side in
        // session_foreground.dart; this end just does what it is told.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SESSION_SERVICE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val label = call.argument<String>("label").orEmpty()
                    activeSessionLabel = label
                    // Asked here, at the moment the first session opens, which
                    // is the only point where the notification has an obvious
                    // meaning to the user. No rationale dialog: the system
                    // prompt arrives one tap after they hit "connect", with a
                    // session notification already on its way.
                    requestNotificationPermissionOnce()
                    val started = runCatching {
                        SessionForegroundService.start(this, label)
                    }.isSuccess
                    result.success(started)
                }
                "stop" -> {
                    activeSessionLabel = null
                    runCatching { SessionForegroundService.stop(this) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermissionOnce() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (notificationPermissionAsked) return
        val permission = android.Manifest.permission.POST_NOTIFICATIONS
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            notificationPermissionAsked = true
            return
        }
        notificationPermissionAsked = true
        runCatching {
            requestPermissions(arrayOf(permission), REQUEST_POST_NOTIFICATIONS)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (storage?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == REQUEST_POST_NOTIFICATIONS) {
            // A refusal costs the user the notification, not the session, so
            // there is nothing to do on that branch. A *grant*, though, needs
            // acting on: the service called startForeground while the
            // permission was still denied, so the platform accepted the
            // service and silently dropped its notification, and it does not
            // go back and post it once permission arrives. Re-issuing
            // startForeground with the same id is what makes it appear —
            // otherwise the first session a user ever opens runs with no
            // notification at all, which is the one case where they most need
            // the way back into the app.
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val label = activeSessionLabel
            if (granted && label != null) {
                runCatching { SessionForegroundService.start(this, label) }
            }
            return
        }
        if (storage?.onRequestPermissionsResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        storage?.dispose()
        storage = null
        // The engine goes with the activity, and the session with the engine,
        // so a notification outliving this point would be advertising a
        // connection that no longer exists.
        runCatching { SessionForegroundService.stop(this) }
        super.onDestroy()
    }
}
