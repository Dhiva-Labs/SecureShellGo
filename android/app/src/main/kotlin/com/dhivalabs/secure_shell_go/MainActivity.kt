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

    /** The optional app lock's platform half. See `AppLockBridge.kt`. */
    private var appLock: AppLockBridge? = null

    /**
     * Kept so a share arriving while the app is already running can tell Dart
     * to come and get it. The cold-start case needs no push — Dart asks once
     * on startup, and the intent that launched the activity is already
     * recorded by then.
     */
    private var shareChannel: MethodChannel? = null

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

        // Files another app sent us through its Share menu. Dart pulls rather
        // than being pushed the payload, so staging a large file happens when
        // the app is ready for it instead of during a cold start.
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            StorageBridge.SHARE_CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePendingShare" -> {
                        val bridge = storage
                        if (bridge == null) result.success(null)
                        else bridge.takePendingShare(result)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // The cold-start case: the activity was launched by the share itself,
        // so the intent is sitting there before Dart has drawn a frame.
        bridge.recordSharedIntent(intent)

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

        // The optional app lock: the OS credential sheet, and the FLAG_SECURE
        // that keeps the terminal out of the recent-apps thumbnail while the
        // lock is switched on.
        val lock = AppLockBridge(this)
        appLock = lock
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AppLockBridge.CHANNEL,
        ).setMethodCallHandler(lock)

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

    /**
     * The warm case: the app is already running (singleTop, so no second
     * activity) and the user shares something into it. Record the files and
     * nudge Dart, which then asks for them the same way it does on a cold
     * start.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (storage?.recordSharedIntent(intent) == true) {
            runCatching { shareChannel?.invokeMethod("shareAvailable", null) }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (storage?.onActivityResult(requestCode, resultCode, data) == true) return
        // The API 23–27 confirm-credential screen comes back through here.
        if (appLock?.onActivityResult(requestCode, resultCode, data) == true) return
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
        // Answers any credential prompt still in flight, so the Dart side is
        // never left awaiting a result that can no longer arrive.
        appLock?.dispose()
        appLock = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        // The engine goes with the activity, and the session with the engine,
        // so a notification outliving this point would be advertising a
        // connection that no longer exists.
        runCatching { SessionForegroundService.stop(this) }
        super.onDestroy()
    }
}
