package org.moonfin.nativevideo

import android.graphics.Bitmap
import io.github.peerless2012.ass.AssFrame
import io.github.peerless2012.ass.AssTex
import io.github.peerless2012.ass.media.AssHandler
import io.github.peerless2012.ass.media.type.AssRenderType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class MoonfinAssOverlayVisibilityTest {
    private fun cachedAssFrame(overlay: MoonfinAssOverlayView): AssFrame? {
        val cached = overlay.javaClass.getDeclaredField("cachedFrame")
            .apply { isAccessible = true }.get(overlay) ?: return null
        return cached.javaClass.getDeclaredField("frame")
            .apply { isAccessible = true }.get(cached) as AssFrame
    }

    @Test
    fun firstNewTrackBitmapSurvivesAndUnchangedRetryCannotReplaceIt() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        val generationField = overlay.javaClass.getDeclaredField("primaryTrackGeneration")
            .apply { isAccessible = true }
        val publish = overlay.javaClass.getDeclaredMethod(
            "publishFrame", AssFrame::class.java, Int::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }

        overlay.syncNativeAssTrack(Any())
        val previousGeneration = generationField.getInt(overlay)
        val oldBitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val oldFrame = AssFrame(arrayOf(AssTex(6, 9, 2, 2, 0, oldBitmap)), changed = 1)
        publish.invoke(overlay, oldFrame, previousGeneration, true)
        assertSame(oldFrame, cachedAssFrame(overlay))

        // B's native selection is now recorded before the render task can
        // snapshot its generation. An already-finished A frame is stale.
        overlay.syncNativeAssTrack(Any())
        val currentGeneration = generationField.getInt(overlay)
        assertTrue(currentGeneration > previousGeneration)
        // A's bitmap stays cached but is hidden until its owner is reselected.
        assertSame(oldFrame, cachedAssFrame(overlay))
        assertTrue(overlay.visibleFrameBounds().isEmpty())
        publish.invoke(overlay, oldFrame, previousGeneration, true)
        assertSame(oldFrame, cachedAssFrame(overlay))

        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val firstB = AssFrame(arrayOf(AssTex(12, 26, 2, 2, 0, bitmap)), changed = 1)
        publish.invoke(overlay, firstB, currentGeneration, true)
        assertSame(firstB, cachedAssFrame(overlay))
        assertEquals(12f, overlay.visibleFrameBounds().single().left)

        // Native libass returns changed=0 with no image array on retry.
        // That cannot reconstruct a B bitmap lost in the ownership handover.
        publish.invoke(overlay, AssFrame(images = null, changed = 0), currentGeneration, true)
        assertSame(firstB, cachedAssFrame(overlay))
    }

    @Test
    fun rapidAssTrackABARetainsTheLastRenderedImage() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        val generation = overlay.javaClass.getDeclaredField("primaryTrackGeneration")
            .apply { isAccessible = true }
        val publish = overlay.javaClass.getDeclaredMethod(
            "publishFrame", AssFrame::class.java, Int::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }
        val a = Any()
        val b = Any()
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val frameA = AssFrame(arrayOf(AssTex(37, 42, 2, 2, 0, bitmap)), changed = 2)

        assertTrue(overlay.syncNativeAssTrack(a))
        publish.invoke(overlay, frameA, generation.getInt(overlay), true)
        assertEquals(37f, overlay.visibleFrameBounds().single().left)

        // B was selected but never rendered, so libass's next render for A
        // reports unchanged and does not supply a replacement bitmap.
        assertTrue(overlay.syncNativeAssTrack(b))
        assertSame(frameA, cachedAssFrame(overlay))
        assertTrue(overlay.visibleFrameBounds().isEmpty())

        assertTrue(overlay.syncNativeAssTrack(a))
        assertEquals(37f, overlay.visibleFrameBounds().single().left)
        publish.invoke(
            overlay, AssFrame(images = null, changed = 0), generation.getInt(overlay), true,
        )
        assertSame(frameA, cachedAssFrame(overlay))
        assertEquals(37f, overlay.visibleFrameBounds().single().left)
    }

    @Test
    fun identicalPixelsTransferBitmapOwnershipAfterRenderingAnotherTrack() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        val generation = overlay.javaClass.getDeclaredField("primaryTrackGeneration")
            .apply { isAccessible = true }
        val publish = overlay.javaClass.getDeclaredMethod(
            "publishFrame", AssFrame::class.java, Int::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }
        val a = Any()
        val b = Any()
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val frameA = AssFrame(arrayOf(AssTex(21, 34, 2, 2, 0, bitmap)), changed = 2)

        overlay.syncNativeAssTrack(a)
        publish.invoke(overlay, frameA, generation.getInt(overlay), true)
        overlay.syncNativeAssTrack(b)
        assertTrue(overlay.visibleFrameBounds().isEmpty())

        // libass compared B's pixels to A's most recent native render and
        // returned unchanged, but the identical image is valid for B too.
        publish.invoke(
            overlay, AssFrame(images = null, changed = 0), generation.getInt(overlay), true,
        )
        assertSame(frameA, cachedAssFrame(overlay))
        assertEquals(21f, overlay.visibleFrameBounds().single().left)

        // The same result must work in the opposite direction.
        overlay.syncNativeAssTrack(a)
        assertTrue(overlay.visibleFrameBounds().isEmpty())
        publish.invoke(
            overlay, AssFrame(images = null, changed = 0), generation.getInt(overlay), true,
        )
        assertEquals(21f, overlay.visibleFrameBounds().single().left)
    }

    @Test
    fun emptySelectedTrackHidesWithoutDiscardingLastNativeBitmap() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        val generation = overlay.javaClass.getDeclaredField("primaryTrackGeneration")
            .apply { isAccessible = true }
        val publish = overlay.javaClass.getDeclaredMethod(
            "publishFrame", AssFrame::class.java, Int::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }
        val a = Any()
        val b = Any()
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val frameA = AssFrame(arrayOf(AssTex(54, 63, 2, 2, 0, bitmap)), changed = 2)

        overlay.syncNativeAssTrack(a)
        publish.invoke(overlay, frameA, generation.getInt(overlay), true)
        overlay.syncNativeAssTrack(b)

        // The ASS track exists from its header, but its first dialogue hasn't
        // loaded, so rendering B returns null without advancing libass's image.
        publish.invoke(overlay, null, generation.getInt(overlay), true)
        assertSame(frameA, cachedAssFrame(overlay))
        assertTrue(overlay.visibleFrameBounds().isEmpty())

        overlay.syncNativeAssTrack(a)
        assertTrue(overlay.visibleFrameBounds().isEmpty())
        publish.invoke(
            overlay, AssFrame(images = null, changed = 0), generation.getInt(overlay), true,
        )
        assertEquals(54f, overlay.visibleFrameBounds().single().left)

        // A genuinely empty current cue must hide its pixels and bounds too,
        // even though the previous bitmap remains available if libass needs it.
        publish.invoke(overlay, null, generation.getInt(overlay), true)
        assertSame(frameA, cachedAssFrame(overlay))
        assertTrue(overlay.visibleFrameBounds().isEmpty())
        publish.invoke(overlay, null, generation.getInt(overlay), true)
        assertTrue(overlay.visibleFrameBounds().isEmpty())
    }

    @Test
    fun offRenderRetainsBitmapUntilActiveTrackRendersAgain() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        val generation = overlay.javaClass.getDeclaredField("primaryTrackGeneration")
            .apply { isAccessible = true }
        val publish = overlay.javaClass.getDeclaredMethod(
            "publishFrame", AssFrame::class.java, Int::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }
        val track = Any()

        assertTrue(overlay.syncNativeAssTrack(track))
        val currentGeneration = generation.getInt(overlay)
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val cue = AssFrame(arrayOf(AssTex(15, 25, 2, 2, 0, bitmap)), changed = 1)
        publish.invoke(overlay, cue, currentGeneration, true)

        overlay.setPrimaryVisible(false)
        assertTrue(!overlay.syncNativeAssTrack(null))
        // No active track: a null native return must not erase the cached cue.
        publish.invoke(overlay, null, currentGeneration, false)
        assertSame(cue, cachedAssFrame(overlay))
        assertTrue(overlay.visibleFrameBounds().isEmpty())

        // Selecting the same track again is still an activation transition:
        // the player listener must ask for a render at the latest timestamp.
        assertTrue(overlay.syncNativeAssTrack(track))
        val resumedGeneration = generation.getInt(overlay)
        assertTrue(resumedGeneration > currentGeneration)
        overlay.setPrimaryVisible(true)
        // A late Off-time result cannot overwrite the reactivated track.
        publish.invoke(overlay, null, currentGeneration, false)
        assertSame(cue, cachedAssFrame(overlay))
        publish.invoke(overlay, AssFrame(images = null, changed = 0), resumedGeneration, true)
        assertSame(cue, cachedAssFrame(overlay))
        assertEquals(15f, overlay.visibleFrameBounds().single().left)

        // If playback crossed the cue's end while Off, the active render
        // returns an empty changed frame, which must clear the old caption.
        publish.invoke(overlay, AssFrame(emptyArray(), changed = 2), resumedGeneration, true)
        assertTrue(overlay.visibleFrameBounds().isEmpty())
    }

    @Test
    fun differentAssTracksClearCachedPlacementWithoutPlaybackTicks() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        var placementUpdates = 0
        overlay.onFrameChanged = { placementUpdates++ }

        val trackA = Any()
        val trackB = Any()
        assertTrue(overlay.syncNativeAssTrack(trackA))
        assertEquals(1, placementUpdates)
        assertTrue(!overlay.syncNativeAssTrack(trackA))
        assertEquals(1, placementUpdates)

        // Off retains native identity, while a genuinely different ASS track
        // changes it under the same lock used by the render executor.
        overlay.setPrimaryVisible(false)
        assertTrue(!overlay.syncNativeAssTrack(null))
        assertEquals(2, placementUpdates)
        overlay.setPrimaryVisible(true)
        assertTrue(overlay.syncNativeAssTrack(trackA))
        assertEquals(3, placementUpdates)

        assertTrue(overlay.syncNativeAssTrack(trackB))
        assertEquals(4, placementUpdates)
        assertTrue(!overlay.syncNativeAssTrack(trackB))
        assertEquals(4, placementUpdates)
        assertTrue(!overlay.syncNativeAssTrack(null))
        assertEquals(4, placementUpdates)
    }

    @Test
    fun primaryOffImmediatelyUpdatesAssVisibilityWithoutAFrameTick() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        var placementUpdates = 0
        overlay.onFrameChanged = { placementUpdates++ }

        overlay.setPrimaryVisible(false)
        assertEquals(1, placementUpdates)
        assertTrue(overlay.visibleFrameBounds().isEmpty())
        overlay.setPrimaryVisible(false)
        assertEquals(1, placementUpdates)

        // Restoring the same ASS track must not depend on a new video frame.
        overlay.setPrimaryVisible(true)
        assertEquals(2, placementUpdates)
    }
}
