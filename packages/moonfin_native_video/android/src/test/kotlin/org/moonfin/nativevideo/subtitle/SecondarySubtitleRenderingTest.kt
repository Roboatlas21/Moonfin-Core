package org.moonfin.nativevideo.subtitle

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.text.Html
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.text.style.UnderlineSpan
import android.view.View
import androidx.media3.common.text.Cue
import androidx.media3.ui.SubtitleView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SecondarySubtitleRenderingTest {
    private fun inkBounds(view: SubtitleView): Rect {
        val bitmap = Bitmap.createBitmap(1280, 720, Bitmap.Config.ARGB_8888)
        view.measure(View.MeasureSpec.makeMeasureSpec(1280, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(720, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, 1280, 720)
        view.draw(Canvas(bitmap))
        val bounds = Rect(1280, 720, 0, 0)
        for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
            if (Color.alpha(bitmap.getPixel(x, y)) > 32) {
                bounds.left = minOf(bounds.left, x)
                bounds.top = minOf(bounds.top, y)
                bounds.right = maxOf(bounds.right, x + 1)
                bounds.bottom = maxOf(bounds.bottom, y + 1)
            }
        }
        bitmap.recycle()
        assertTrue("Subtitle must draw visible pixels", bounds.width() > 0)
        return bounds
    }

    @Test
    fun automaticSecondaryRemainsCenteredForLatinAndArabic() {
        val context = RuntimeEnvironment.getApplication()
        val primary = SubtitleView(context)
        val secondary = SubtitleView(context)
        secondary.layout(0, 0, 1280, 720)
        val overlay = SecondarySubtitleOverlay(secondary, primary)
        overlay.select(true)
        overlay.updatePrimaryCues(listOf(Cue.Builder().setText("Primary subtitle").build()))
        for (text in listOf("Short subtitle", "الترجمة العربية")) {
            overlay.updateCues(listOf(Cue.Builder().setText(text).build()))
            val pixels = inkBounds(secondary)
            assertEquals("Text must use the centre anchor, not the collision box's left edge",
                640f, pixels.exactCenterX(), 12f)
        }
    }

    @Test
    fun secondaryKeepsExplicitLeftAndRightAnchors() {
        val context = RuntimeEnvironment.getApplication()
        val primary = SubtitleView(context)
        val secondary = SubtitleView(context)
        secondary.layout(0, 0, 1280, 720)
        val overlay = SecondarySubtitleOverlay(secondary, primary)
        overlay.select(true)
        for ((position, anchor) in listOf(0.1f to Cue.ANCHOR_TYPE_START,
                0.9f to Cue.ANCHOR_TYPE_END)) {
            overlay.updatePrimaryCues(listOf(Cue.Builder().setText("Primary")
                .setPosition(position).setPositionAnchor(anchor).build()))
            overlay.updateCues(listOf(Cue.Builder().setText("Secondary").build()))
            val pixels = inkBounds(secondary)
            val edge = if (anchor == Cue.ANCHOR_TYPE_START) pixels.left else pixels.right
            assertEquals(position * 1280, edge.toFloat(), 12f)
        }
    }

    @Test
    fun increasedSpacingKeepsMultilineSecondaryVisibleWhenItFits() {
        val context = RuntimeEnvironment.getApplication()
        val primary = SubtitleView(context).apply {
            setFractionalTextSize(0.06f)
            setBottomPaddingFraction(0.04f)
        }
        val secondary = SubtitleView(context)
        secondary.layout(0, 0, 1280, 720)
        val overlay = SecondarySubtitleOverlay(secondary, primary)
        overlay.configureBaseStyle(Color.WHITE, Color.TRANSPARENT, Color.TRANSPARENT, 24f, 400, 0.04f)
        overlay.select(true)
        overlay.updatePrimaryCues(listOf(Cue.Builder().setText("Primary").build()))
        overlay.updateCues(listOf(Cue.Builder().setText("One\nTwo\nThree").build()))
        for (spacing in listOf(0f, 0.06f)) {
            overlay.configureAppearance(36f, spacing)
            assertEquals(View.VISIBLE, secondary.visibility)
            val pixels = inkBounds(secondary)
            assertTrue(pixels.top >= 360)
            assertTrue(pixels.bottom < inkBounds(primary).top)
        }
    }
    @Test
    fun twentyPercentPrimaryOffsetKeepsMultilinePairVisible() {
        val context = RuntimeEnvironment.getApplication()
        val primary = SubtitleView(context).apply {
            setFractionalTextSize(0.06f)
            setBottomPaddingFraction(0.20f)
        }
        val secondary = SubtitleView(context).apply { layout(0, 0, 1280, 720) }
        val overlay = SecondarySubtitleOverlay(secondary, primary)
        overlay.configureBaseStyle(Color.WHITE, Color.TRANSPARENT, Color.TRANSPARENT, 24f, 400, 0.20f)
        overlay.select(true)
        overlay.updatePrimaryCues(listOf(Cue.Builder().setText("First line\nSecond line").build()))
        overlay.updateCues(listOf(Cue.Builder().setText("Translation one\nTranslation two").build()))
        overlay.configureAppearance(null, 0.06f)
        assertEquals(View.VISIBLE, secondary.visibility)
        val secondPixels = inkBounds(secondary)
        val primaryPixels = inkBounds(primary)
        assertTrue("Secondary should remain above primary at maximum spacing",
            secondPixels.bottom < primaryPixels.top)
    }


    @Test
    fun secondaryKeepsEmphasisInBothStackedAndPrimaryOffModes() {
        val context = RuntimeEnvironment.getApplication()
        val primary = SubtitleView(context)
        val secondary = SubtitleView(context).apply { layout(0, 0, 1280, 720) }
        val overlay = SecondarySubtitleOverlay(secondary, primary)
        val styled = Html.fromHtml(
            "<i>italic</i> <b>bold</b> <u>underlined</u> <font color='#ff0000'>red</font> <big>large</big>",
            Html.FROM_HTML_MODE_COMPACT,
        )
        val second = Html.fromHtml("<u>second line</u>", Html.FROM_HTML_MODE_COMPACT)
        overlay.select(true)
        overlay.updatePrimaryCues(listOf(Cue.Builder().setText("Primary").build()))
        overlay.updateCues(listOf(
            Cue.Builder().setText(styled).setWindowColor(Color.BLUE).build(),
            Cue.Builder().setText(second).build(),
        ))

        // SubtitleView has no public cue getter. Read its input cues rather than
        // depending on renderer-specific drawing internals.
        val field = SubtitleView::class.java.getDeclaredField("cues").apply { isAccessible = true }
        fun displayed(): Spanned {
            val cues = field.get(secondary) as List<*>
            return (cues.single() as Cue).text as Spanned
        }
        fun check(text: Spanned) {
            val italicAt = text.indexOf("italic")
            val boldAt = text.indexOf("bold")
            val underlinedAt = text.indexOf("underlined")
            val secondAt = text.indexOf("second line")
            assertTrue(text.getSpans(italicAt, italicAt + 6, StyleSpan::class.java)
                .any { it.style and Typeface.ITALIC != 0 })
            assertTrue(text.getSpans(boldAt, boldAt + 4, StyleSpan::class.java)
                .any { it.style and Typeface.BOLD != 0 })
            assertTrue(text.getSpans(underlinedAt, underlinedAt + 10, UnderlineSpan::class.java).isNotEmpty())
            assertTrue(text.getSpans(secondAt, secondAt + 11, UnderlineSpan::class.java).isNotEmpty())
            assertTrue(text.getSpans(0, text.length, ForegroundColorSpan::class.java).isEmpty())
            assertTrue(text.getSpans(0, text.length, RelativeSizeSpan::class.java).isEmpty())
        }
        check(displayed())
        assertFalse(((field.get(secondary) as List<*>).single() as Cue).windowColorSet)
        overlay.setPrimaryEnabled(false)
        check(displayed())
    }

}
