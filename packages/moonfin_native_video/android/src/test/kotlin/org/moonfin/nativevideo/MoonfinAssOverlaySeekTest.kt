package org.moonfin.nativevideo

import io.github.peerless2012.ass.media.AssHandler
import io.github.peerless2012.ass.media.type.AssRenderType
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class MoonfinAssOverlaySeekTest {
    @Test
    fun pausedSeekUsesDestinationAndSubtitleDelayWithoutClockTick() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        overlay.timeOffsetUs = 200_000L

        // The ass-media clock may drop the seek's timestamp while paused.
        // The explicit request must use the new playback position instead.
        overlay.renderAtPlaybackPosition(12_345L)
        val presented = overlay.javaClass.getDeclaredField("lastPresentationTimeUs")
            .apply { isAccessible = true }
        val pending = overlay.javaClass.getDeclaredField("pendingTimeUs")
            .apply { isAccessible = true }
        assertEquals(12_345_000L, presented.get(overlay) as Long)
        assertEquals(12_145_000L, pending.getLong(overlay))

        overlay.renderAtPlaybackPosition(-1L)
        assertEquals(12_145_000L, pending.getLong(overlay))
    }

    @Test
    fun hiddenSeekUpdatesTheTimeUsedWhenAssIsReactivated() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        overlay.timeOffsetUs = 250_000L
        overlay.setPrimaryVisible(false)
        overlay.rememberPlaybackPosition(9_500L)

        val presented = overlay.javaClass.getDeclaredField("lastPresentationTimeUs")
            .apply { isAccessible = true }
        val pending = overlay.javaClass.getDeclaredField("pendingTimeUs")
            .apply { isAccessible = true }
        assertEquals(9_500_000L, presented.get(overlay) as Long)
        assertEquals(9_250_000L, pending.getLong(overlay))

        overlay.setPrimaryVisible(true)
        overlay.redrawCurrentAssFrame()
        assertEquals(9_250_000L, pending.getLong(overlay))
    }

    @Test
    fun newerTimeDuringAnInFlightRenderQueuesAnotherFrame() {
        val handler = AssHandler(AssRenderType.OVERLAY_CANVAS)
        val overlay = MoonfinAssOverlayView(RuntimeEnvironment.getApplication(), handler)
        val executor = RecordingExecutor()
        overlay.javaClass.getDeclaredField("executor")
            .apply { isAccessible = true }.set(overlay, executor)

        val scheduled = overlay.javaClass.getDeclaredField("renderScheduled")
            .apply { isAccessible = true }.get(overlay) as AtomicBoolean
        val pending = overlay.javaClass.getDeclaredField("renderPending")
            .apply { isAccessible = true }.get(overlay) as AtomicBoolean
        val pendingTime = overlay.javaClass.getDeclaredField("pendingTimeUs")
            .apply { isAccessible = true }
        val renderTask = overlay.javaClass.getDeclaredField("renderTask")
            .apply { isAccessible = true }.get(overlay) as Runnable

        pendingTime.setLong(overlay, 1_000_000L)
        scheduled.set(true)
        pending.set(true)
        val worker = Thread(renderTask, "ass-pending-time-test")
        synchronized(handler) {
            worker.start()
            // The worker clears pending before it enters the native lock.
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (pending.get() && System.nanoTime() < deadline) Thread.yield()
            assertFalse("render task did not start", pending.get())

            // Same native track, but a seek changes the requested timestamp
            // while the earlier render is still blocked on the handler.
            pendingTime.setLong(overlay, 9_000_000L)
            pending.set(true)
        }
        worker.join(5_000)
        assertFalse("render task did not finish", worker.isAlive)
        assertEquals(1, executor.requests.size)
        assertTrue(scheduled.get())
    }

    @Test
    fun lateDialogueRedrawsPausedSeekButNotAfterResumeOrPrimaryOff() {
        val overlay = MoonfinAssOverlayView(
            RuntimeEnvironment.getApplication(),
            AssHandler(AssRenderType.OVERLAY_CANVAS),
        )
        overlay.syncNativeAssTrack(Any())
        overlay.timeOffsetUs = 100_000L
        overlay.renderAtPlaybackPosition(12_000L, waitForDialogue = true)

        val pending = overlay.javaClass.getDeclaredField("pendingTimeUs")
            .apply { isAccessible = true }
        // Model an initial blank render before the destination's ASS dialogue
        // is extracted. A late chunk must request that same delayed timestamp.
        pending.setLong(overlay, -1L)
        overlay.onAssDialogueLoaded()
        assertEquals(11_900_000L, pending.getLong(overlay))

        // The loader may continue reading once normal playback resumes.
        overlay.stopAwaitingPausedSeekDialogue()
        pending.setLong(overlay, -1L)
        overlay.onAssDialogueLoaded()
        assertEquals(-1L, pending.getLong(overlay))

        // A hidden primary must not wake the renderer for late dialogue.
        overlay.renderAtPlaybackPosition(13_000L, waitForDialogue = true)
        overlay.setPrimaryVisible(false)
        pending.setLong(overlay, -1L)
        overlay.onAssDialogueLoaded()
        assertEquals(-1L, pending.getLong(overlay))
    }

    private class RecordingExecutor : AbstractExecutorService() {
        val requests = mutableListOf<Runnable>()

        override fun execute(command: Runnable) {
            requests.add(command)
        }

        override fun shutdown() = Unit
        override fun shutdownNow(): MutableList<Runnable> = mutableListOf()
        override fun isShutdown() = false
        override fun isTerminated() = false
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = true
    }
}
