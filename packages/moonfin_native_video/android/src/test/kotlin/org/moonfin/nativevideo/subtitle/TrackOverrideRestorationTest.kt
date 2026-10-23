package org.moonfin.nativevideo.subtitle

import androidx.media3.common.Format
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotEquals
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

    @Test
    fun latestExplicitChoiceWinsOverAnOlderActivatedTrack() {
        val english = Format.Builder().setSampleMimeType("application/x-subrip")
            .setLanguage("en").build()
        val japanese = Format.Builder().setSampleMimeType("application/x-subrip")
            .setLanguage("ja").build()
        val original = TrackGroup("original", english, japanese)
        val replacement = TrackGroup("0:original", english, japanese)

        // English is still active, but the pending Media3 override already requests Japanese.
        val activatedOrdinal = 1
        val overrides = mapOf(original to TrackSelectionOverride(original, listOf(1)))
        val requestedOrdinal = overriddenTrackOrdinal(
            listOf(original to 0, original to 1), overrides,
        )
        assertNotEquals(activatedOrdinal, requestedOrdinal)
        assertEquals(2, requestedOrdinal)
        // The old override isn't attached to the replacement group.
        assertNull(overriddenTrackOrdinal(listOf(replacement to 0, replacement to 1), overrides))
        val reapplied = mapOf(replacement to TrackSelectionOverride(
            replacement, listOf(requestedOrdinal!! - 1),
        ))
        assertEquals(2, overriddenTrackOrdinal(
            listOf(replacement to 0, replacement to 1), reapplied,
        ))
    }
}
