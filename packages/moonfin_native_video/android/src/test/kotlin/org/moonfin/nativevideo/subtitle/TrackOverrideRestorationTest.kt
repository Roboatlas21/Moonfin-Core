package org.moonfin.nativevideo.subtitle

import androidx.media3.common.Format
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class TrackOverrideRestorationTest {
    @Test
    fun explicitAudioAndSubtitleChoicesUseTheSameMapping() {
        val audio = TrackGroup("audio",
            Format.Builder().setSampleMimeType("audio/aac").build(),
            Format.Builder().setSampleMimeType("audio/ac3").build())
        val text = TrackGroup("text",
            Format.Builder().setSampleMimeType("application/x-subrip").build())
        val overrides = mapOf(
            audio to TrackSelectionOverride(audio, listOf(1)),
            text to TrackSelectionOverride(text, listOf(0)),
        )

        assertEquals(2, overriddenTrackOrdinal(listOf(audio to 0, audio to 1), overrides))
        assertEquals(1, overriddenTrackOrdinal(listOf(text to 0), overrides))
        assertNull(overriddenTrackOrdinal(listOf(audio to 0), overrides))
        assertNull(overriddenTrackOrdinal(listOf(text to 0), emptyMap()))
    }

}
