package com.induma.duplex_printer

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
import android.os.PowerManager

/**
 * Keeps FlipPrint alive while a print is running in the background: a
 * foreground service with a progress notification, plus a partial wake lock
 * so pages keep streaming with the screen off.
 */
class PrintService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            release()
            stopForeground(STOP_FOREGROUND_REMOVE)
            // Optional "Printing finished" message, shown only when given.
            if (intent.hasExtra(EXTRA_TITLE)) {
                manager(this).notify(DONE_ID, build(this, intent, alert = true))
            }
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = build(this, intent, alert = false)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, notification)
        }
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FlipPrint:print")
                .apply { acquire(2 * 60 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        release()
        super.onDestroy()
    }

    private fun release() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    companion object {
        const val ACTION_STOP = "stop"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_MAX = "max"
        private const val ID = 41
        private const val ALERT_ID = 42
        private const val DONE_ID = 43
        private const val CHANNEL = "printing"
        private const val ALERT_CHANNEL = "print_alerts"

        fun manager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        /** A loud, separate notification, e.g. "Flip the paper". */
        fun alert(context: Context, title: String, text: String) {
            manager(context).notify(ALERT_ID, build(context, Intent().apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }, alert = true))
        }

        fun clearAlert(context: Context) = manager(context).cancel(ALERT_ID)

        /** Refreshes the ongoing notification without restarting the
         *  service, which Android forbids from the background. */
        fun update(context: Context, intent: Intent) =
            manager(context).notify(ID, build(context, intent, alert = false))

        private fun build(context: Context, intent: Intent?, alert: Boolean): Notification {
            ensureChannels(context)
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java)
                    .setAction(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val max = intent?.getIntExtra(EXTRA_MAX, 0) ?: 0
            val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
            return Notification.Builder(context, if (alert) ALERT_CHANNEL else CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: "FlipPrint")
                .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "")
                .setContentIntent(open)
                .setOnlyAlertOnce(!alert)
                .setOngoing(!alert)
                .setAutoCancel(alert)
                .setCategory(if (alert) Notification.CATEGORY_REMINDER else Notification.CATEGORY_PROGRESS)
                .apply { if (!alert && max > 0) setProgress(max, progress, false) }
                .build()
        }

        private fun ensureChannels(context: Context) {
            val m = manager(context)
            if (m.getNotificationChannel(CHANNEL) == null) {
                m.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Printing progress", NotificationManager.IMPORTANCE_LOW),
                )
            }
            if (m.getNotificationChannel(ALERT_CHANNEL) == null) {
                m.createNotificationChannel(
                    NotificationChannel(ALERT_CHANNEL, "Flip the paper", NotificationManager.IMPORTANCE_HIGH)
                        .apply { enableVibration(true) },
                )
            }
        }
    }
}
