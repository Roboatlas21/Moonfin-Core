package org.moonfin.nativevideo

import io.github.peerless2012.ass.media.AssHandler
import io.github.peerless2012.ass.media.type.AssRenderType
import org.junit.Assert.assertEquals
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
    fun differentAssTracksClearCachedPlacementWithoutPlaybackTicks() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        var placementUpdates = 0
        overlay.onFrameChanged = { placementUpdates++ }

        overlay.selectPrimaryAssTrack(1)
        assertEquals(1, placementUpdates)
        overlay.selectPrimaryAssTrack(1)
        assertEquals(1, placementUpdates)

        // Off and reselection of A retain the cache; B invalidates it.
        overlay.setPrimaryVisible(false)
        assertEquals(2, placementUpdates)
        overlay.setPrimaryVisible(true)
        overlay.selectPrimaryAssTrack(1)
        assertEquals(3, placementUpdates)

        overlay.selectPrimaryAssTrack(2)
        assertEquals(4, placementUpdates)
        overlay.selectPrimaryAssTrack(2)
        assertEquals(4, placementUpdates)
        overlay.selectPrimaryAssTrack(null)
        assertEquals(5, placementUpdates)
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
