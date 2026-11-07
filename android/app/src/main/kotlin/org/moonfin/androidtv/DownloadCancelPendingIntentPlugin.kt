package org.moonfin.androidtv

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * A Flutter engine plugin rather than an Activity-owned method channel.
 * Foreground transcodes can outlive the UI Activity; retaining an Activity
 * in a notification-action handler would leak it and break cancellation.
 */
class DownloadCancelPendingIntentPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var applicationContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger,
            DownloadCancelPendingIntent.CHANNEL,
        ).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "invalidateForegroundCancelAction" -> {
                val id = call.argument<Int>("notificationId")
                if (id != 1000) {
                    result.error("INVALID_ID", "Unexpected download notification", null)
                    return
                }
                val context = applicationContext
                if (context == null) {
                    result.error("ENGINE_DETACHED", "Download notification channel unavailable", null)
                    return
                }
                try {
                    DownloadCancelPendingIntent.invalidate(context, id)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("PENDING_INTENT", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
