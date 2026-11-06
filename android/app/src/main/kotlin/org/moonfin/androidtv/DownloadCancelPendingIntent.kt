package org.moonfin.androidtv

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver

/**
 * Flutter Local Notifications identifies action PendingIntents using
 * notificationId * 16. Notification ID 1000 is reused when an episode is
 * promoted to own the foreground service. FLAG_UPDATE_CURRENT otherwise
 * retargets an outstanding action from the previous episode to the next.
 *
 * Cancel the old token BEFORE posting the new owner's Cancel action. A
 * late tap on the old token then fails safely instead of stopping the wrong
 * download. Regular per-episode notification IDs are never reused.
 */
internal object DownloadCancelPendingIntent {
    const val CHANNEL = "org.moonfin.androidtv/download_notifications"

    fun invalidate(context: Context, notificationId: Int) {
        val intent = Intent(context, ActionBroadcastReceiver::class.java)
            .setAction(ActionBroadcastReceiver.ACTION_TAPPED)
        val immutableFlag =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val flags = PendingIntent.FLAG_NO_CREATE or immutableFlag
        PendingIntent.getBroadcast(context, notificationId * 16, intent, flags)
            ?.cancel()
    }
}
