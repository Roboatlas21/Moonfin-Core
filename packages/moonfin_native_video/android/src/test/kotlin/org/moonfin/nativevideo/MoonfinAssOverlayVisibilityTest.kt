package org.moonfin.nativevideo

import io.github.peerless2012.ass.AssFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class MoonfinAssOverlayVisibilityTest {
    @Test
    fun firstNewTrackBitmapSurvivesAndUnchangedRetryCannotReplaceIt() {
        val h = MoonfinAssOverlayTestHarness()

        h.overlay.syncNativeAssTrack(Any())
        val previousGeneration = h.generation
        val oldFrame = h.frame(6, 9)
        h.publishFrame(oldFrame, previousGeneration)
        assertSame(oldFrame, h.cachedFrame())

        // B's native selection is now recorded before the render task can
        // snapshot its generation. An already-finished A frame is stale.
        h.overlay.syncNativeAssTrack(Any())
        val currentGeneration = h.generation
        assertTrue(currentGeneration > previousGeneration)
        // A's bitmap stays cached but is hidden until its owner is reselected.
        assertSame(oldFrame, h.cachedFrame())
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())
        h.publishFrame(oldFrame, previousGeneration)
        assertSame(oldFrame, h.cachedFrame())

        val firstB = h.frame(12, 26)
        h.publishFrame(firstB, currentGeneration)
        assertSame(firstB, h.cachedFrame())
        assertEquals(12f, h.overlay.visibleFrameBounds().single().left)

        // Native libass returns changed=0 with no image array on retry.
        // That cannot reconstruct a B bitmap lost in the ownership handover.
        h.publishFrame(AssFrame(images = null, changed = 0), currentGeneration)
        assertSame(firstB, h.cachedFrame())
    }

    @Test
    fun rapidAssTrackABARetainsTheLastRenderedImage() {
        val h = MoonfinAssOverlayTestHarness()
        val a = Any()
        val b = Any()
        val frameA = h.frame(37, 42, changed = 2)

        assertTrue(h.overlay.syncNativeAssTrack(a))
        h.publishFrame(frameA)
        assertEquals(37f, h.overlay.visibleFrameBounds().single().left)

        // B was selected but never rendered, so libass's next render for A
        // reports unchanged and does not supply a replacement bitmap.
        assertTrue(h.overlay.syncNativeAssTrack(b))
        assertSame(frameA, h.cachedFrame())
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())

        assertTrue(h.overlay.syncNativeAssTrack(a))
        assertEquals(37f, h.overlay.visibleFrameBounds().single().left)
        h.publishFrame(AssFrame(images = null, changed = 0))
        assertSame(frameA, h.cachedFrame())
        assertEquals(37f, h.overlay.visibleFrameBounds().single().left)
    }

    @Test
    fun identicalPixelsTransferBitmapOwnershipAfterRenderingAnotherTrack() {
        val h = MoonfinAssOverlayTestHarness()
        val a = Any()
        val b = Any()
        val frameA = h.frame(21, 34, changed = 2)

        h.overlay.syncNativeAssTrack(a)
        h.publishFrame(frameA)
        h.overlay.syncNativeAssTrack(b)
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())

        // libass compared B's pixels to A's most recent native render and
        // returned unchanged, but the identical image is valid for B too.
        h.publishFrame(AssFrame(images = null, changed = 0))
        assertSame(frameA, h.cachedFrame())
        assertEquals(21f, h.overlay.visibleFrameBounds().single().left)

        // The same result must work in the opposite direction.
        h.overlay.syncNativeAssTrack(a)
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())
        h.publishFrame(AssFrame(images = null, changed = 0))
        assertEquals(21f, h.overlay.visibleFrameBounds().single().left)
    }

    @Test
    fun emptySelectedTrackHidesWithoutDiscardingLastNativeBitmap() {
        val h = MoonfinAssOverlayTestHarness()
        val a = Any()
        val b = Any()
        val frameA = h.frame(54, 63, changed = 2)

        h.overlay.syncNativeAssTrack(a)
        h.publishFrame(frameA)
        h.overlay.syncNativeAssTrack(b)

        // The ASS track exists from its header, but its first dialogue hasn't
        // loaded, so rendering B returns null without advancing libass's image.
        h.publishFrame(null)
        assertSame(frameA, h.cachedFrame())
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())

        h.overlay.syncNativeAssTrack(a)
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())
        h.publishFrame(AssFrame(images = null, changed = 0))
        assertEquals(54f, h.overlay.visibleFrameBounds().single().left)

        // A genuinely empty current cue must hide its pixels and bounds too,
        // even though the previous bitmap remains available if libass needs it.
        h.publishFrame(null)
        assertSame(frameA, h.cachedFrame())
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())
        h.publishFrame(null)
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())
    }

    @Test
    fun offRenderRetainsBitmapUntilActiveTrackRendersAgain() {
        val h = MoonfinAssOverlayTestHarness()
        val track = Any()

        assertTrue(h.overlay.syncNativeAssTrack(track))
        val currentGeneration = h.generation
        val cue = h.frame(15, 25)
        h.publishFrame(cue, currentGeneration)

        h.overlay.setPrimaryVisible(false)
        assertTrue(!h.overlay.syncNativeAssTrack(null))
        // No active track: a null native return must not erase the cached cue.
        h.publishFrame(null, currentGeneration, active = false)
        assertSame(cue, h.cachedFrame())
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())

        // Selecting the same track again is still an activation transition:
        // the player listener must ask for a render at the latest timestamp.
        assertTrue(h.overlay.syncNativeAssTrack(track))
        val resumedGeneration = h.generation
        assertTrue(resumedGeneration > currentGeneration)
        h.overlay.setPrimaryVisible(true)
        // A late Off-time result cannot overwrite the reactivated track.
        h.publishFrame(null, currentGeneration, active = false)
        assertSame(cue, h.cachedFrame())
        h.publishFrame(AssFrame(images = null, changed = 0), resumedGeneration)
        assertSame(cue, h.cachedFrame())
        assertEquals(15f, h.overlay.visibleFrameBounds().single().left)

        // If playback crossed the cue's end while Off, the active render
        // returns an empty changed frame, which must clear the old caption.
        h.publishFrame(AssFrame(emptyArray(), changed = 2), resumedGeneration)
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())
    }

    @Test
    fun differentAssTracksClearCachedPlacementWithoutPlaybackTicks() {
        val h = MoonfinAssOverlayTestHarness()
        var placementUpdates = 0
        h.overlay.onFrameChanged = { placementUpdates++ }

        val trackA = Any()
        val trackB = Any()
        assertTrue(h.overlay.syncNativeAssTrack(trackA))
        assertEquals(1, placementUpdates)
        assertTrue(!h.overlay.syncNativeAssTrack(trackA))
        assertEquals(1, placementUpdates)

        // Off retains native identity, while a genuinely different ASS track
        // changes it under the same lock used by the render executor.
        h.overlay.setPrimaryVisible(false)
        assertTrue(!h.overlay.syncNativeAssTrack(null))
        assertEquals(2, placementUpdates)
        h.overlay.setPrimaryVisible(true)
        assertTrue(h.overlay.syncNativeAssTrack(trackA))
        assertEquals(3, placementUpdates)

        assertTrue(h.overlay.syncNativeAssTrack(trackB))
        assertEquals(4, placementUpdates)
        assertTrue(!h.overlay.syncNativeAssTrack(trackB))
        assertEquals(4, placementUpdates)
        assertTrue(!h.overlay.syncNativeAssTrack(null))
        assertEquals(4, placementUpdates)
    }

    @Test
    fun primaryOffImmediatelyUpdatesAssVisibilityWithoutAFrameTick() {
        val h = MoonfinAssOverlayTestHarness()
        var placementUpdates = 0
        h.overlay.onFrameChanged = { placementUpdates++ }

        h.overlay.setPrimaryVisible(false)
        assertEquals(1, placementUpdates)
        assertTrue(h.overlay.visibleFrameBounds().isEmpty())
        h.overlay.setPrimaryVisible(false)
        assertEquals(1, placementUpdates)

        // Restoring the same ASS track must not depend on a new video frame.
        h.overlay.setPrimaryVisible(true)
        assertEquals(2, placementUpdates)
    }
}
