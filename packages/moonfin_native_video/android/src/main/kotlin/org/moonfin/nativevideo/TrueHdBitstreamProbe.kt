package org.moonfin.nativevideo

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.os.Build
import androidx.media3.common.Format

internal enum class TrueHdSupport { SUPPORTED, UNSUPPORTED, UNKNOWN }

/** A missing route, incomplete track format, or failed query is never a veto. */
internal fun classifyTrueHdSupport(
    apiLevel: Int,
    activeHdmiRoute: Boolean,
    sampleRate: Int,
    channelCount: Int,
    directFlags: Int?,
    bitstreamFlag: Int,
): TrueHdSupport {
    if (apiLevel < 33 || !activeHdmiRoute || sampleRate <= 0 ||
        channelCount !in setOf(1, 2, 6, 8) || directFlags == null
    ) return TrueHdSupport.UNKNOWN
    return if ((directFlags and bitstreamFlag) != 0) {
        TrueHdSupport.SUPPORTED
    } else {
        TrueHdSupport.UNSUPPORTED
    }
}

internal fun trueHdChannelMask(channels: Int): Int? = when (channels) {
    1 -> AudioFormat.CHANNEL_OUT_MONO
    2 -> AudioFormat.CHANNEL_OUT_STEREO
    6 -> AudioFormat.CHANNEL_OUT_5POINT1
    8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
    else -> null
}

/**
 * Checks the *selected* TrueHD format on the route Android expects to play
 * media. The startup capability scan cannot answer for every channel layout
 * and sample rate. UNKNOWN leaves Media3's original decision untouched.
 */
internal class TrueHdBitstreamProbe(
    context: Context,
    private val report: (String) -> Unit,
) {
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
        .build()

    fun supportsBitstream(format: Format): Boolean? {
        // Existing Media3 Auto support detection remains authoritative on
        // Android 12 and older; the API 33 probe does not exist there.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null

        val routed = runCatching {
            manager?.getAudioDevicesForAttributes(attributes)?.toList()
        }.getOrNull()
        val route = routed?.map { "${it.type}:${it.id}" }?.sorted()?.joinToString(",")
            ?: "unavailable"
        val sampleRate = format.sampleRate
        val channels = format.channelCount
        val hdmi = routed?.any {
            it.type == AudioDeviceInfo.TYPE_HDMI ||
                it.type == AudioDeviceInfo.TYPE_HDMI_ARC ||
                it.type == AudioDeviceInfo.TYPE_HDMI_EARC ||
                it.type == AudioDeviceInfo.TYPE_LINE_DIGITAL
        } == true

        val mask = trueHdChannelMask(channels)
        val flags = if (hdmi && sampleRate > 0 && mask != null) {
            runCatching {
                val audioFormat = AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_DOLBY_TRUEHD)
                    .setSampleRate(sampleRate)
                    .setChannelMask(mask)
                    .build()
                AudioManager.getDirectPlaybackSupport(audioFormat, attributes)
            }.getOrNull()
        } else null

        val verdict = classifyTrueHdSupport(
            apiLevel = Build.VERSION.SDK_INT,
            activeHdmiRoute = hdmi,
            sampleRate = sampleRate,
            channelCount = channels,
            directFlags = flags,
            bitstreamFlag = AudioManager.DIRECT_PLAYBACK_BITSTREAM_SUPPORTED,
        )
        val detail = "route=${route} channels=${channels} rate=${sampleRate}Hz " +
            "directFlags=${flags?.toString() ?: "unknown"} " +
            "decision=${when (verdict) {
                TrueHdSupport.SUPPORTED -> "passthrough-eligible"
                TrueHdSupport.UNSUPPORTED -> "decode-pcm"
                TrueHdSupport.UNKNOWN -> "defer-to-media3"
            }}"
        report(detail)
        return when (verdict) {
            TrueHdSupport.SUPPORTED -> true
            TrueHdSupport.UNSUPPORTED -> false
            TrueHdSupport.UNKNOWN -> null
        }
    }
}
