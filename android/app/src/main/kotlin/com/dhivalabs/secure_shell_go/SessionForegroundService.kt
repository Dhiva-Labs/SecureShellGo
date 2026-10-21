package com.dhivalabs.secure_shell_go

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app's process alive — and visibly so — for as long as an SSH
 * session is connected.
 *
 * Without this the session is at Android's mercy the moment the user switches
 * apps: a backgrounded process is a candidate for reclaim, and a reclaimed
 * process takes the socket, the PTY and whatever was running in it with it.
 * A foreground service is the only sanctioned way to say "this process is
 * doing something the user asked for and can see".
 *
 * `specialUse` on Android 14 and later, `dataSync` before. An interactive
 * terminal is not a data sync: it has no end, and the user may leave it
 * idle for a day with a build or a tmux session running in it. Android 15
 * caps `dataSync` at six hours a day in the background and then stops the
 * service, which for this app meant a session that died for no reason the
 * user could see. None of the other types fit (`connectedDevice` is for
 * companion hardware, `mediaPlayback` and `location` would be lies), so this
 * is the case `specialUse` exists for. It needs the
 * PROPERTY_SPECIAL_USE_FGS_SUBTYPE property in the manifest and a
 * declaration in the Play Console, written out in
 * `store/play-fgs-declaration.md`.
 *
 * `dataSync` stays declared beside it: Android 10–13 have no `specialUse`,
 * and on 14+ it is the fallback if a `specialUse` start is ever refused.
 * When a `dataSync` service does reach its limit, [onTimeout] stops it
 * cleanly and tells Dart, which starts it again the next time the app is on
 * screen — when Android allows it, and resets the limit.
 *
 * A hand-written service rather than `flutter_foreground_task` or similar, for
 * the same reason `StorageBridge.kt` is hand-written: this project keeps zero
 * third-party native dependencies on a toolchain (AGP 9 / Kotlin 2.3) that has
 * been unkind to plugins, and the whole platform side of this feature is one
 * notification and two lifecycle calls.
 *
 * Deliberately action-free. A "Disconnect" button in the notification would
 * have to reach back into the Dart isolate to tear the session down properly,
 * which is a whole extra channel direction for a control the user already has
 * one tap away inside the app.
 */
class SessionForegroundService : Service() {

    companion object {
        const val ACTION_START = "com.dhivalabs.secure_shell_go.SESSION_START"
        const val ACTION_STOP = "com.dhivalabs.secure_shell_go.SESSION_STOP"
        const val EXTRA_LABEL = "label"

        /**
         * Told when Android stops the service by itself ([onTimeout]). Set by
         * MainActivity to pass the news to Dart over the session-service
         * channel; null while no activity is there to hear it.
         */
        @Volatile
        var onTimedOut: (() -> Unit)? = null

        private const val CHANNEL_ID = "ssh_session"
        private const val NOTIFICATION_ID = 0x5349

        /** Starts (or re-labels) the service. Safe to call repeatedly. */
        fun start(context: Context, label: String) {
            val intent = Intent(context, SessionForegroundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_LABEL, label)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * Stops the service. Routed through [Context.startService] rather than
         * [Context.stopService] so a stop that lands before the pending start
         * has been delivered is still ordered behind it — otherwise the start
         * would win and leave a notification with no session behind it.
         */
        fun stop(context: Context) {
            val intent = Intent(context, SessionForegroundService::class.java)
                .setAction(ACTION_STOP)
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutDown()
            return Service.START_NOT_STICKY
        }

        val label = intent?.getStringExtra(EXTRA_LABEL)?.takeIf { it.isNotBlank() }
            ?: "SSH session"
        val notification = buildNotification(label)

        startInForeground(notification)

        // Not sticky: if the process dies the session dies with it, so having
        // Android resurrect a bare service — notification and all, with no
        // connection behind it — would be worse than nothing.
        return Service.START_NOT_STICKY
    }

    /**
     * The typed overload is required from API 29 on, and from API 34 on it is
     * enforced against the manifest's foregroundServiceType, which declares
     * both types used here.
     */
    private fun startInForeground(notification: Notification) {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                val started = runCatching {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                }.isSuccess || runCatching {
                    // Refused as specialUse (a platform that will not take
                    // the type): dataSync is the one other honest choice.
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                }.isSuccess
                // Refused both ways — a background start restriction refuses
                // every type. The session still works while the app is on
                // screen; a crash here would end it.
                if (!started) stopSelf()
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
            else -> startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Android 15+ calls this when a `dataSync` service has used up its daily
     * budget — only reachable here on the fallback, `specialUse` has none.
     * Stopping promptly is not optional: the platform throws
     * `ForegroundServiceDidNotStopInTimeException` at apps that linger. Dart
     * is told, so it can start the service again once the app is on screen.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        shutDown()
        runCatching { onTimedOut?.invoke() }
    }

    private fun shutDown() {
        stopForeground(Service.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(label: String): Notification {
        ensureChannel()

        // The launcher intent, not a fresh MainActivity intent: it carries
        // ACTION_MAIN/CATEGORY_LAUNCHER and FLAG_ACTIVITY_NEW_TASK, which is
        // what brings the *existing* task forward with its navigator stack
        // intact rather than starting a second copy on top of the session.
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }

        return builder
            .setContentTitle(label)
            .setContentText("Connected — tap to return")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setShowWhen(false)
            .also { if (contentIntent != null) it.setContentIntent(contentIntent) }
            .build()
    }

    /**
     * IMPORTANCE_LOW: visible and dismissible-proof while it is ongoing, but
     * silent and never a heads-up. A terminal session going quiet in the tray
     * is the desired result — the notification exists to keep the process
     * alive and to offer a way back, not to be an event.
     */
    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "SSH session",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while an SSH session is connected."
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }
}
