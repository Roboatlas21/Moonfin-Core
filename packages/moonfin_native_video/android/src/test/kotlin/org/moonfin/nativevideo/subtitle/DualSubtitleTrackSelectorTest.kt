package org.moonfin.nativevideo.subtitle

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.Timeline
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.TrackSelector
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class DualSubtitleTrackSelectorTest {
    private lateinit var selector: DualSubtitleTrackSelector
    private lateinit var english: TrackGroup
    private lateinit var french: TrackGroup
    private val renderer = object : RendererCapabilities {
        override fun getName() = "TextRenderer"
        override fun getTrackType() = C.TRACK_TYPE_TEXT
        override fun supportsFormat(format: Format) = RendererCapabilities.create(C.FORMAT_HANDLED)
        override fun supportsMixedMimeTypeAdaptation() = RendererCapabilities.ADAPTIVE_NOT_SUPPORTED
    }

    @Before
    fun setup() {
        val context = RuntimeEnvironment.getApplication()
        selector = DualSubtitleTrackSelector(context)
        selector.init(TrackSelector.InvalidationListener {}, DefaultBandwidthMeter.Builder(context).build())
        fun group(id: String, language: String) = TrackGroup(id, Format.Builder()
            .setSampleMimeType(MimeTypes.APPLICATION_MEDIA3_CUES)
            .setCodecs(MimeTypes.APPLICATION_SUBRIP).setLanguage(language).build())
        english = group("2", "en")
        french = group("3", "fr")
        selector.parameters = selector.buildUponParameters()
            .addOverride(TrackSelectionOverride(english, 0)).build()
        selector.setSecondaryTrack(TrackSelectionOverride(french, 0))
    }

    @After
    fun teardown() = selector.release()

    private fun select(groups: TrackGroupArray = TrackGroupArray(english, french)) =
        selector.selectTracks(arrayOf(renderer, renderer), groups, MediaPeriodId("test"), Timeline.EMPTY)
            .also { selector.onSelectionActivated(it.info) }

    @Test
    fun `two different embedded queues are selected and reported`() {
        val result = select()
        assertEquals(english, result.selections[0]!!.trackGroup)
        assertEquals(french, result.selections[1]!!.trackGroup)
        assertTrue(result.tracks.groups.all { it.isSelected })
        assertTrue(selector.isPrimaryTrackSelected(english, 0))
        assertFalse(selector.isPrimaryTrackSelected(french, 0))
    }

    @Test
    fun `primary off leaves secondary active and secondary off leaves primary active`() {
        selector.parameters = selector.buildUponParameters().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
        assertNull(select().selections[0])
        assertEquals(french, select().selections[1]!!.trackGroup)
        assertFalse(selector.isPrimaryTrackSelected(french, 0))
        selector.parameters = selector.buildUponParameters().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).build()
        selector.setSecondaryTrack(null)
        assertEquals(english, select().selections[0]!!.trackGroup)
        assertNull(select().selections[1])
    }

    @Test
    fun `duplicate primary and stale source groups cannot create a second reader`() {
        selector.setSecondaryTrack(TrackSelectionOverride(english, 0))
        assertNull(select().selections[1])
        selector.setSecondaryTrack(TrackSelectionOverride(french, 0))
        assertNull(select(TrackGroupArray(english)).selections[1])
    }

    @Test
    fun `retiming temporarily releases secondary then restores its selection`() {
        selector.suspendSecondary(true)
        assertNull(select().selections[1])
        selector.suspendSecondary(false)
        assertEquals(french, select().selections[1]!!.trackGroup)
    }
}
