package org.moonfin.nativevideo.subtitle

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.PlaybackException
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.SilenceMediaSource
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.text.TextRenderer
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.test.utils.FakeRenderer
import androidx.media3.test.utils.robolectric.TestPlayerRunHelper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.io.IOException
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger

/**
 * Integration probe on an isolated testing branch. Uses the production subtitle
 * MediaSource wrapper and dual track selector, but substitutes a synthetic
 * audio/video timeline and a DataSource that fails like a broken Jellyfin request.
 * No network service or device is involved.
 */
@UnstableApi
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
@LooperMode(LooperMode.Mode.PAUSED)
class Media3SecondaryHttpFailureIntegrationTest {
    @Test
    fun failingSecondarySubtitleRequestDoesNotEndPlayback() {
        val context = RuntimeEnvironment.getApplication()
        val requestCount = AtomicInteger()
        val subtitleErrors = Collections.synchronizedList(mutableListOf<IOException>())
        val failures = Collections.synchronizedList(mutableListOf<PlaybackException>())
        val brokenNetwork = DataSource.Factory {
            object : DataSource {
                override fun addTransferListener(transferListener: TransferListener) {}

                override fun open(dataSpec: DataSpec): Long {
                    requestCount.incrementAndGet()
                    throw IOException("Injected subtitle HTTP 503")
                }

                override fun read(buffer: ByteArray, offset: Int, length: Int) = C.RESULT_END_OF_INPUT
                override fun getUri(): Uri? = null
                override fun close() {}
            }
        }
        val config = MediaItem.SubtitleConfiguration.Builder(
            Uri.parse("https://example.invalid/second-language.srt")
        ).setMimeType(MimeTypes.APPLICATION_SUBRIP).setLanguage("ja").build()
        val sidecar = TimeOffsetMediaSource(
            SidecarSourceFactory.create(config, brokenNetwork, DefaultSubtitleParserFactory()),
            0L,
            0L,
            onSecondaryError = subtitleErrors::add,
        )
        val selector = DualSubtitleTrackSelector(context)
        // The initial playback has no primary subtitles. This makes the
        // secondary-only request explicit and gives us a clean baseline clock.
        selector.setParameters(
            selector.buildUponParameters().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        )
        val audioRenderer = FakeRenderer(C.TRACK_TYPE_AUDIO)
        val output = object : TextOutput {
            override fun onCues(cueGroup: CueGroup) {}
        }
        val renderersFactory = RenderersFactory { handler, _, _, _, _ ->
            arrayOf(
                audioRenderer,
                TextRenderer(output, handler.looper),
                TextRenderer(output, handler.looper),
            )
        }
        val player = ExoPlayer.Builder(context, renderersFactory)
            .setTrackSelector(selector)
            .build()
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                failures.add(error)
            }
        })
        try {
            player.setMediaSource(MergingMediaSource(
                SilenceMediaSource.Factory().setDurationUs(15_000_000L).createMediaSource(),
                sidecar,
            ))
            player.prepare()
            TestPlayerRunHelper.advance(player)
                .untilState(Player.STATE_READY)
            // First prove the synthetic media can play WITHOUT any subtitle;
            // a failure here belongs to the test harness rather than Moonfin.
            try {
                TestPlayerRunHelper.play(player).untilPositionAtLeast(1_000L)
            } catch (error: Exception) {
                throw AssertionError(
                    "Baseline synthetic playback failed BEFORE secondary selection: " +
                        "state=${player.playbackState}, play=${player.isPlaying}, " +
                        "position=${player.currentPosition}, error=${player.playerError}, " +
                        "audioBuffers=${audioRenderer.sampleBufferReadCount}",
                    error,
                )
            }
            val subtitleGroup = player.currentTracks.groups.first {
                it.type == C.TRACK_TYPE_TEXT
            }
            assertTrue(selector.setSecondaryTrack(TrackSelectionOverride(
                subtitleGroup.mediaTrackGroup, listOf(0),
            )))
            try {
                // Advance after deliberately selecting the broken subtitle.
                TestPlayerRunHelper.advance(player).untilPositionAtLeast(10_000L)
            } catch (error: Exception) {
                throw AssertionError(
                    "Playback stopped after SECONDARY subtitle request: " +
                        "state=${player.playbackState}, play=${player.isPlaying}, " +
                        "position=${player.currentPosition}, error=${player.playerError}, " +
                        "requests=${requestCount.get()}, subtitleErrors=${subtitleErrors.size}, " +
                        "playerErrors=${failures.size}, audioBuffers=${audioRenderer.sampleBufferReadCount}",
                    error,
                )
            }
            assertTrue("Injected subtitle request never happened", requestCount.get() > 0)
            assertTrue("Secondary stream error wasn't reported", subtitleErrors.isNotEmpty())
            assertTrue("Movie clock should remain active", player.isPlaying)
            assertEquals(Player.STATE_READY, player.playbackState)
            assertNull(player.playerError)
            val before = player.currentPosition
            TestPlayerRunHelper.advance(player)
                .untilPositionAtLeast(before + 500L)
            assertTrue("Playback should advance after subtitle request failed", player.currentPosition > before)
            assertTrue("Audio stream should still be rendered", audioRenderer.sampleBufferReadCount > 0)
        } finally {
            player.release()
        }
    }
}
