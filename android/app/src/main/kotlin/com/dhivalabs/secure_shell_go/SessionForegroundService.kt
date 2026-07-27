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
 * `dataSync` is the honest foreground service type here. The alternatives do
 * not fit: `connectedDevice` is for companion hardware, `mediaPlayback` and
 * `location` would be lies, and `specialUse` requires a Play Console
 * justification for a case that an existing type already describes. An SSH
 * connection is a long-running network transfer on the user's behalf, which is
 * what `dataSync` is for. Note that this comes with Android 15+'s cumulative
 * six-hour daily budget for `dataSync` — hence [onTimeout], which shuts the
 * service down cleanly instead of letting the platform kill the app.
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

        // The typed overload is required from API 29 on, and from API 34 on it
        // is enforced against the manifest's foregroundServiceType.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Not sticky: if the process dies the session dies with it, so having
        // Android resurrect a bare service — notification and all, with no
        // connection behind it — would be worse than nothing.
        return Service.START_NOT_STICKY
    }

    /**
     * Android 15+ calls this when a `dataSync` service has used up its daily
     * budget. Stopping promptly is not optional: the platform throws
     * `ForegroundServiceDidNotStopInTimeException` at apps that linger.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        shutDown()
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
