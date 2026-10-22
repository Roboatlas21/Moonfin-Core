package org.moonfin.nativevideo.subtitle

import androidx.media3.common.MimeTypes
import androidx.media3.common.text.Cue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubripPrimaryPositionTest {
    @Test
    fun parsedSubripFormatsAreIdentifiedWithoutGuessingFromCoordinates() {
        assertTrue(isSubripPrimaryFormat(MimeTypes.APPLICATION_SUBRIP, null))
        assertTrue(isSubripPrimaryFormat(MimeTypes.APPLICATION_MEDIA3_CUES, MimeTypes.APPLICATION_SUBRIP))
        assertFalse(isSubripPrimaryFormat(MimeTypes.TEXT_VTT, null))
        assertFalse(isSubripPrimaryFormat(MimeTypes.APPLICATION_MEDIA3_CUES, MimeTypes.TEXT_VTT))
        assertFalse(isSubripPrimaryFormat(MimeTypes.APPLICATION_MEDIA3_CUES, null))
        assertFalse(isSubripPrimaryFormat(MimeTypes.APPLICATION_CEA608, null))
    }

    private fun edgeCue(line: Float, anchor: Int): Cue =
        Cue.Builder()
            .setText("Primary")
            .setLine(line, Cue.LINE_TYPE_FRACTION)
            .setLineAnchor(anchor)
            .setPosition(0.3f)
            .setPositionAnchor(Cue.ANCHOR_TYPE_START)
            .build()

    @Test
    fun onlySubripTopAndBottomAlignmentAnchorsFollowVerticalOffset() {
        val top = edgeCue(0.08f, Cue.ANCHOR_TYPE_START)
        val bottom = edgeCue(0.92f, Cue.ANCHOR_TYPE_END)
        val movedTop = offsetSubripAlignmentCue(top, 0.04f, true)
        val movedBottom = offsetSubripAlignmentCue(bottom, 0.04f, true)
        assertEquals(0.12f, movedTop.line, 0.0001f)
        assertEquals(0.88f, movedBottom.line, 0.0001f)
        assertEquals(top.lineAnchor, movedTop.lineAnchor)
        assertEquals(bottom.lineAnchor, movedBottom.lineAnchor)
        assertEquals(top.position, movedTop.position, 0.0001f)
        assertEquals(bottom.position, movedBottom.position, 0.0001f)
        assertSame(top, offsetSubripAlignmentCue(top, 0f, true))
    }

    @Test
    fun explicitWebvttCoordinatesAreUntouchedEvenAtSubripAnchorValues() {
        val top = edgeCue(0.08f, Cue.ANCHOR_TYPE_START)
        val bottom = edgeCue(0.92f, Cue.ANCHOR_TYPE_END)
        assertSame(top, offsetSubripAlignmentCue(top, 0.04f, false))
        assertSame(bottom, offsetSubripAlignmentCue(bottom, 0.04f, false))
    }

    @Test
    fun unpositionedAndMiddleSubripCuesKeepExistingPlacement() {
        val automatic = Cue.Builder().setText("Automatic").build()
        val middle = edgeCue(0.5f, Cue.ANCHOR_TYPE_MIDDLE)
        val other = edgeCue(0.1f, Cue.ANCHOR_TYPE_START)
        assertSame(automatic, offsetSubripAlignmentCue(automatic, 0.04f, true))
        assertSame(middle, offsetSubripAlignmentCue(middle, 0.04f, true))
        assertSame(other, offsetSubripAlignmentCue(other, 0.04f, true))
    }
}
