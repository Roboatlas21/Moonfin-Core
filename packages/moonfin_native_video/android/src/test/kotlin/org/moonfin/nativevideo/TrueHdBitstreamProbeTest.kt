package org.moonfin.nativevideo

import android.media.AudioFormat
import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TrueHdBitstreamProbeTest {
    private val bitstream = AudioManager.DIRECT_PLAYBACK_BITSTREAM_SUPPORTED

    private fun verdict(
        apiLevel: Int = 34,
        hdmi: Boolean = true,
        rate: Int = 48_000,
        channels: Int = 8,
        flags: Int? = bitstream,
    ) = classifyTrueHdSupport(
        apiLevel = apiLevel,
        activeHdmiRoute = hdmi,
        sampleRate = rate,
        channelCount = channels,
        directFlags = flags,
        bitstreamFlag = bitstream,
    )

    @Test
    fun `matching 7 point 1 bitstream support preserves passthrough`() {
        assertEquals(TrueHdSupport.SUPPORTED, verdict())
        assertEquals(TrueHdSupport.SUPPORTED, verdict(flags = 5))
        assertEquals(AudioFormat.CHANNEL_OUT_7POINT1_SURROUND, trueHdChannelMask(8))
    }

    @Test
    fun `offload-only and zero flags veto the checked format`() {
        assertEquals(TrueHdSupport.UNSUPPORTED, verdict(flags = 0))
        assertEquals(TrueHdSupport.UNSUPPORTED, verdict(flags = 1))
        assertEquals(TrueHdSupport.UNSUPPORTED, verdict(flags = 3))
    }

    @Test
    fun `support for one format is not applied to another format`() {
        // The caller asks Android for each exact sample rate and channel mask,
        // so two TrueHD tracks may legitimately have different answers.
        assertEquals(TrueHdSupport.SUPPORTED, verdict(channels = 6, flags = 4))
        assertEquals(TrueHdSupport.UNSUPPORTED, verdict(channels = 8, flags = 0))
        assertEquals(TrueHdSupport.SUPPORTED, verdict(rate = 96_000, flags = 4))
        assertEquals(TrueHdSupport.UNSUPPORTED, verdict(rate = 48_000, flags = 0))
        assertEquals(AudioFormat.CHANNEL_OUT_5POINT1, trueHdChannelMask(6))
        assertEquals(AudioFormat.CHANNEL_OUT_STEREO, trueHdChannelMask(2))
    }

    @Test
    fun `older Android never introduces a TrueHD Auto veto`() {
        assertEquals(TrueHdSupport.UNKNOWN, verdict(apiLevel = 32, flags = 0))
        assertEquals(TrueHdSupport.UNKNOWN, verdict(apiLevel = 29, flags = 0))
    }

    @Test
    fun `inconclusive results defer to Media3`() {
        assertEquals(TrueHdSupport.UNKNOWN, verdict(hdmi = false, flags = 0))
        assertEquals(TrueHdSupport.UNKNOWN, verdict(flags = null))
        assertEquals(TrueHdSupport.UNKNOWN, verdict(rate = -1, flags = 0))
        assertEquals(TrueHdSupport.UNKNOWN, verdict(channels = -1, flags = 0))
        assertEquals(TrueHdSupport.UNKNOWN, verdict(channels = 12, flags = 0))
        assertNull(trueHdChannelMask(12))
    }
}
