package org.moonfin.nativevideo

import android.graphics.Bitmap
import io.github.peerless2012.ass.AssFrame
import io.github.peerless2012.ass.AssTex
import io.github.peerless2012.ass.media.AssHandler
import io.github.peerless2012.ass.media.type.AssRenderType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
    @Test
    fun firstNewTrackBitmapSurvivesAndUnchangedRetryCannotReplaceIt() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        val generationField = overlay.javaClass.getDeclaredField("primaryTrackGeneration")
            .apply { isAccessible = true }
        val frameField = overlay.javaClass.getDeclaredField("currentFrame")
            .apply { isAccessible = true }
        val publish = overlay.javaClass.getDeclaredMethod(
            "publishFrame", AssFrame::class.java, Int::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }

        overlay.syncNativeAssTrack(Any())
        val previousGeneration = generationField.getInt(overlay)
        val oldFrame = AssFrame(emptyArray(), changed = 1)
        publish.invoke(overlay, oldFrame, previousGeneration)
        assertSame(oldFrame, frameField.get(overlay))

        // B's native selection is now recorded before the render task can
        // snapshot its generation. An already-finished A frame is stale.
        overlay.syncNativeAssTrack(Any())
        val currentGeneration = generationField.getInt(overlay)
        assertTrue(currentGeneration > previousGeneration)
        assertNull(frameField.get(overlay))
        publish.invoke(overlay, oldFrame, previousGeneration)
        assertNull(frameField.get(overlay))

        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val firstB = AssFrame(arrayOf(AssTex(12, 26, 2, 2, 0, bitmap)), changed = 1)
        publish.invoke(overlay, firstB, currentGeneration)
        assertSame(firstB, frameField.get(overlay))
        assertEquals(12f, overlay.visibleFrameBounds().single().left)

        // Native libass returns changed=0 with no image array on retry.
        // That cannot reconstruct a B bitmap lost in the ownership handover.
        publish.invoke(overlay, AssFrame(images = null, changed = 0), currentGeneration)
        assertSame(firstB, frameField.get(overlay))
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
        assertEquals(2, placementUpdates)
        overlay.setPrimaryVisible(true)
        assertTrue(!overlay.syncNativeAssTrack(trackA))
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
