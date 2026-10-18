package org.moonfin.nativevideo

import androidx.media3.common.MimeTypes
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioPassthroughPolicyTest {
    @Test
    fun `auto vetoes only a definite format-specific TrueHD failure`() {
        val policy = AudioPassthroughPolicy.fromWire("auto", emptySet())
        assertFalse(policy.allowsBitstream(MimeTypes.AUDIO_TRUEHD, false))
        assertTrue(policy.allowsBitstream(MimeTypes.AUDIO_TRUEHD, true))
        assertTrue(policy.allowsBitstream(MimeTypes.AUDIO_TRUEHD, null))
        assertTrue(policy.allowsBitstream(MimeTypes.AUDIO_TRUEHD))
    }

    @Test
    fun `auto does not veto other formats even if TrueHD failed`() {
        val policy = AudioPassthroughPolicy.fromWire("auto", emptySet())
        assertTrue(policy.allowsBitstream(MimeTypes.AUDIO_DTS_HD, false))
        assertTrue(policy.allowsBitstream(MimeTypes.AUDIO_AC3, false))
        assertTrue(policy.allowsBitstream(null, false))
    }

    @Test
    fun `manual TrueHD on always overrides an unsupported Auto verdict`() {
        val policy = AudioPassthroughPolicy.fromWire("manual", setOf("truehd"))
        assertTrue(policy.allowsBitstream(MimeTypes.AUDIO_TRUEHD, false))
        assertFalse(policy.allowsBitstream(MimeTypes.AUDIO_AC3))
    }

    @Test
    fun `manual TrueHD off always wins even if Auto reports supported`() {
        val policy = AudioPassthroughPolicy.fromWire("manual", setOf("ac3"))
        assertFalse(policy.allowsBitstream(MimeTypes.AUDIO_TRUEHD, true))
        assertTrue(policy.allowsBitstream(MimeTypes.AUDIO_AC3))
    }

    @Test
    fun `disabled mode always decodes compressed audio`() {
        val policy = AudioPassthroughPolicy.fromWire("disabled", setOf("truehd"))
        assertFalse(policy.allowsBitstream(MimeTypes.AUDIO_TRUEHD, true))
        assertFalse(policy.allowsBitstream(MimeTypes.AUDIO_AC3))
    }
}
