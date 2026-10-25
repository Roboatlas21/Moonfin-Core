package org.moonfin.nativevideo.subtitle

import androidx.media3.common.text.Cue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class PrimaryVerticalOffsetTest {
    @Test
    fun negativeAndPositiveWebvttLineNumbersShiftInwardAndRestoreAtZero() {
        val bottom = Cue.Builder().setText("Bottom")
            .setLine(-1f, Cue.LINE_TYPE_NUMBER).build()
        val top = Cue.Builder().setText("Top")
            .setLine(0f, Cue.LINE_TYPE_NUMBER).build()
        val shiftedBottom = offsetPrimaryCue(bottom, 0.04f, 0.06f)
        val shiftedTop = offsetPrimaryCue(top, 0.04f, 0.06f)
        assertEquals(Cue.LINE_TYPE_FRACTION, shiftedBottom.lineType)
        assertEquals(Cue.LINE_TYPE_FRACTION, shiftedTop.lineType)
        assertEquals(0.96f, shiftedBottom.line, 0.0001f)
        assertEquals(0.04f, shiftedTop.line, 0.0001f)
        assertEquals(Cue.ANCHOR_TYPE_END, shiftedBottom.lineAnchor)
        assertEquals(Cue.ANCHOR_TYPE_START, shiftedTop.lineAnchor)
        assertSame(bottom, offsetPrimaryCue(bottom, 0f, 0.06f))
        assertSame(top, offsetPrimaryCue(top, 0f, 0.06f))
    }
}
