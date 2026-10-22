package org.moonfin.nativevideo.subtitle

import android.graphics.Color
import android.graphics.Typeface
import android.text.Layout
import android.view.View
import androidx.media3.common.text.Cue
import androidx.media3.common.MimeTypes
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView

// Pre-parsed text tracks identify their original subtitle format in codecs.
internal fun isSubripPrimaryFormat(sampleMimeType: String?, codecs: String?): Boolean =
    sampleMimeType == MimeTypes.APPLICATION_SUBRIP ||
        (sampleMimeType == MimeTypes.APPLICATION_MEDIA3_CUES && codecs == MimeTypes.APPLICATION_SUBRIP)

// Media3's SRT alignment tags use standard 8%/92% edge anchors. Move those
// anchors inward by the user offset, but never infer SRT from a WebVTT coordinate.
internal fun offsetSubripAlignmentCue(cue: Cue, verticalOffset: Float, isSubrip: Boolean): Cue {
    if (!isSubrip || verticalOffset == 0f || cue.bitmap != null ||
        cue.lineType != Cue.LINE_TYPE_FRACTION) return cue
    val line = when {
        cue.lineAnchor == Cue.ANCHOR_TYPE_START && cue.line in 0.079f..0.081f ->
            cue.line + verticalOffset
        cue.lineAnchor == Cue.ANCHOR_TYPE_END && cue.line in 0.919f..0.921f ->
            cue.line - verticalOffset
        else -> return cue
    }
    return cue.buildUpon().setLine(line.coerceIn(0f, 1f), Cue.LINE_TYPE_FRACTION).build()
}

/** Places and styles cues decoded by the second Media3 text renderer. */
@androidx.media3.common.util.UnstableApi
internal class SecondarySubtitleOverlay(
    private val view: SubtitleView,
    private val primaryView: SubtitleView,
) {
    companion object {
        private const val MIN_GAP_DP = 8f
    }

    private var disposed = false
    private var secondaryCues: List<Cue>? = null
    private var baseTextColor = Color.WHITE
    private var baseBackgroundColor = Color.TRANSPARENT
    private var baseStrokeColor = Color.TRANSPARENT
    private var baseFontSize = 20f
    private var baseFontWeight = 400
    private var fontSizeOverride: Float? = null
    private var textColorOverride: Int? = null
    private var offsetDelta = 0f
    private var primaryBottomPaddingFraction = 0.04f
    private var primaryCues: List<Cue> = emptyList()
    private var unmodifiedPrimaryCues: List<Cue> = emptyList()
    private var primaryIsSubrip = false
    private var lastPrimaryForStacking: Cue? = null
    private var lastPrimaryWasCentred = false

    init {
        view.setApplyEmbeddedStyles(false)
        view.setApplyEmbeddedFontSizes(false)
        view.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            renderCues()
        }
        applyStyle()
        view.setCues(emptyList())
    }

    /** A track switch clears old cues; Media3 owns loading, timing and seeking. */
    fun select(enabled: Boolean) {
        val alreadySelected = secondaryCues != null
        secondaryCues = if (enabled) emptyList() else null
        if (!enabled || !alreadySelected) {
            // Switching the slot on needs a fresh primary anchor; switching
            // secondary languages keeps its last placement through cue gaps.
            lastPrimaryForStacking = null
            lastPrimaryWasCentred = false
        }
        renderCues()
    }

    fun updateCues(cues: List<Cue>) {
        if (secondaryCues == null || disposed) return
        secondaryCues = cues.filter { it.text != null }
        renderCues()
    }

    fun configureBaseStyle(
        textColor: Int,
        backgroundColor: Int,
        strokeColor: Int,
        fontSize: Float?,
        fontWeight: Int,
        verticalOffset: Float?,
    ) {
        baseTextColor = textColor
        baseBackgroundColor = backgroundColor
        baseStrokeColor = strokeColor
        if (fontSize != null) baseFontSize = fontSize
        baseFontWeight = fontWeight
        if (verticalOffset != null) {
            primaryBottomPaddingFraction = verticalOffset.coerceIn(0f, 0.95f)
        }
        applyStyle()
        renderCues()
    }

    fun updatePrimaryCues(cues: List<Cue>, isSubrip: Boolean) {
        unmodifiedPrimaryCues = cues
        primaryIsSubrip = isSubrip
        renderCues()
    }

    /** Font size and vertical offset use the same units as the primary subtitle style. */
    fun configureAppearance(
        fontSize: Float?,
        verticalOffset: Float?,
        textColor: Int? = null,
    ) {
        fontSizeOverride = fontSize?.coerceIn(6f, 72f)
        textColorOverride = textColor
        offsetDelta = (verticalOffset ?: 0f).coerceIn(-0.4f, 0.2f)
        applyStyle()
        renderCues()
    }

    private fun renderCues() {
        val active = secondaryCues.orEmpty()
        val width = view.width
        val height = view.height
        // Keep a fixed centre anchor while the secondary track is selected,
        // even through gaps in its dialogue. Size changes grow away from the
        // centre rather than shifting the primary with each secondary cue.
        val gapPx = MIN_GAP_DP * view.resources.displayMetrics.density
        val minimumGapPx = 2f * view.resources.displayMetrics.density
        val middleGapPx = SubtitleLayoutPlanner.middleGap(
            gapPx, offsetDelta, height, minimumGapPx)
        primaryCues = unmodifiedPrimaryCues.map { cue ->
            val positioned = offsetSubripAlignmentCue(
                cue, primaryBottomPaddingFraction, primaryIsSubrip,
            )
            if (secondaryCues != null && height > 0 &&
                positioned.lineType == Cue.LINE_TYPE_FRACTION &&
                positioned.lineAnchor == Cue.ANCHOR_TYPE_MIDDLE &&
                positioned.line in 0.35f..0.65f
            ) positioned.buildUpon()
                .setLine((positioned.line + middleGapPx / (2f * height)).coerceAtMost(1f), Cue.LINE_TYPE_FRACTION)
                .setLineAnchor(Cue.ANCHOR_TYPE_START)
                .build()
            else positioned
        }
        val currentPrimary = primaryCues.firstOrNull { it.text != null }
        if (currentPrimary != null) {
            lastPrimaryForStacking = currentPrimary
            val authored = unmodifiedPrimaryCues.firstOrNull { it.text != null }
            lastPrimaryWasCentred = authored != null &&
                authored.lineType == Cue.LINE_TYPE_FRACTION &&
                authored.lineAnchor == Cue.ANCHOR_TYPE_MIDDLE &&
                authored.line in 0.35f..0.65f
        }
        primaryView.setCues(primaryCues)
        if (active.isEmpty()) {
            view.visibility = View.VISIBLE
            view.setCues(emptyList())
            return
        }
        if (width <= 0 || height <= 0) {
            view.visibility = View.VISIBLE
            view.setCues(active.map(::buildCue))
            return
        }
        val primaryFontPx = (baseFontSize / 24f) * 0.06f * height
        val secondaryFontPx = ((fontSizeOverride ?: baseFontSize) / 24f) * 0.06f * height
        val primaryBoxes = primaryCues.map { estimatePrimaryBox(it, width, height, primaryFontPx) }
        val reference = currentPrimary ?: lastPrimaryForStacking
        // The primary's authored anchor determines the secondary's placement.
        val fixed = if (reference == null) active.filter { it.line != Cue.DIMEN_UNSET } else emptyList()
        val automatic = if (reference == null) active.filter { it.line == Cue.DIMEN_UNSET } else active
        val rendered = ArrayList<Cue>()
        val occupied = ArrayList<SubtitleBox>(primaryBoxes)
        val topFallback = ArrayList<Pair<String, Cue>>()
        for (sourceCue in fixed) {
            var cue = buildCue(sourceCue)
            val originalBox = estimateSecondaryBox(
                cue,
                width,
                height,
                estimateTextHeight(sourceCue.text.toString(), width * (sourceCue.size.takeUnless { it == Cue.DIMEN_UNSET } ?: 0.9f), secondaryFontPx),
            )
            val inward = if (SubtitleLayoutPlanner.verticalAlignmentFor(originalBox, height) ==
                SubtitleLayoutPlanner.ALIGN_TOP) offsetDelta else -offsetDelta
            val shift = (inward * height)
                .coerceAtLeast(-originalBox.top).coerceAtMost(height - originalBox.bottom)
            val box = originalBox.copy(top = originalBox.top + shift, bottom = originalBox.bottom + shift)
            cue = cue.buildUpon().setLine(box.bottom / height, Cue.LINE_TYPE_FRACTION)
                .setLineAnchor(Cue.ANCHOR_TYPE_END).build()
            if (occupied.none { SubtitleLayoutPlanner.intersects(box, it, gapPx) }) {
                rendered += cue
                occupied += box
                continue
            }

            val verticalAlignment = SubtitleLayoutPlanner.verticalAlignmentFor(box, height)
            val placed = SubtitleLayoutPlanner.placePositionedSecondary(
                primary = occupied,
                viewportWidth = width,
                viewportHeight = height,
                desired = box,
                verticalAlignment = verticalAlignment,
                gapPx = gapPx,
                stepPx = gapPx,
            )
            if (placed != null) {
                cue = cue.buildUpon()
                    .setLine(placed.bottom / height, Cue.LINE_TYPE_FRACTION)
                    .build()
                rendered += cue
                occupied += placed
            } else if (verticalAlignment == SubtitleLayoutPlanner.ALIGN_TOP) {
                topFallback.add(sourceCue.text.toString() to cue)
            }
        }

        // Top-aligned captions that don't fit in the upper half fall back to
        // the normal bottom placement.
        for ((text, cue) in topFallback) {
            placeAutomaticCue(cue, text, width, height, secondaryFontPx, occupied, gapPx)
                ?.let(rendered::add)
        }

        val automaticGroups = automatic.groupBy {
            listOf(it.position, it.positionAnchor, it.size, it.textAlignment)
        }.values
        for (group in automaticGroups) {
            val text = group.joinToString("\n") { it.text.toString() }
            placeAutomaticCue(
                buildCue(group.first()).buildUpon().setText(text).build(), text, width, height, secondaryFontPx, occupied, gapPx,
            )?.let(rendered::add)
        }

        view.visibility = if (rendered.isEmpty()) View.INVISIBLE else View.VISIBLE
        view.setCues(rendered)
    }

    private fun buildCue(cue: Cue): Cue = cue.buildUpon().apply {
        if (cue.line != Cue.DIMEN_UNSET) {
            setLine(cue.line, if (cue.lineType == Cue.LINE_TYPE_NUMBER) Cue.LINE_TYPE_NUMBER else Cue.LINE_TYPE_FRACTION)
            if (cue.lineAnchor == Cue.TYPE_UNSET) {
                setLineAnchor(if (cue.line < 0f) Cue.ANCHOR_TYPE_END else Cue.ANCHOR_TYPE_START)
            }
        }
        if (cue.position != Cue.DIMEN_UNSET && cue.positionAnchor == Cue.TYPE_UNSET) {
            setPositionAnchor(Cue.ANCHOR_TYPE_MIDDLE)
        }
        setTextAlignment(cue.textAlignment ?: Layout.Alignment.ALIGN_CENTER)
    }.build()

    private fun placeAutomaticCue(
        cue: Cue,
        text: String,
        width: Int,
        height: Int,
        fontPx: Float,
        occupied: MutableList<SubtitleBox>,
        gapPx: Float,
    ): Cue? {
        val cueWidth = if (cue.size == Cue.DIMEN_UNSET) width * 0.9f else cue.size * width
        val textHeight = estimateTextHeight(text, cueWidth, fontPx.coerceAtLeast(1f))
        val reference = primaryCues.firstOrNull { it.text != null } ?: lastPrimaryForStacking
        val refBox = reference?.let {
            estimatePrimaryBox(it, width, height, (baseFontSize / 24f) * 0.06f * height)
        }
        val primaryBottom = height * (1f - primaryBottomPaddingFraction)
        val centred = reference != null && lastPrimaryWasCentred
        val minimumGapPx = 2f * view.resources.displayMetrics.density
        val desiredBottom = when {
            refBox == null -> primaryBottom - gapPx - offsetDelta * height
            centred -> refBox.top - SubtitleLayoutPlanner.middleGap(
                gapPx, offsetDelta, height, minimumGapPx)
            else -> SubtitleLayoutPlanner.stackedDesiredBottom(
                refBox, height, textHeight, gapPx, offsetDelta)
        }
        val placement = if (refBox != null && reference != null) {
            val left = if (reference.position != Cue.DIMEN_UNSET)
                (reference.position * width - when (reference.positionAnchor) {
                    Cue.ANCHOR_TYPE_START -> 0f
                    Cue.ANCHOR_TYPE_END -> cueWidth
                    else -> cueWidth / 2f
                }).coerceIn(0f, (width - cueWidth).coerceAtLeast(0f))
                else (width - cueWidth) / 2f
            val desired = SubtitleBox(left, desiredBottom - textHeight, left + cueWidth, desiredBottom)
            val alignment = if (centred) SubtitleLayoutPlanner.ALIGN_MIDDLE
                else SubtitleLayoutPlanner.verticalAlignmentFor(refBox, height)
            SubtitleLayoutPlanner.placePositionedSecondary(
                occupied, width, height, desired, alignment,
                if (centred) minimumGapPx / 2f else gapPx, gapPx,
            )
        } else SubtitleLayoutPlanner.placeSecondary(
            primary = occupied,
            viewportWidth = width,
            viewportHeight = height,
            secondaryHeight = textHeight,
            desiredBottom = desiredBottom,
            gapPx = gapPx,
            stepPx = gapPx,
        )
        if (placement == null) return null
        val topAligned = reference != null &&
            SubtitleLayoutPlanner.verticalAlignmentFor(refBox!!, height) == SubtitleLayoutPlanner.ALIGN_TOP
        val placedCue = cue.buildUpon()
            .setLine(
                ((if (topAligned) placement.top else placement.bottom) / height).coerceIn(0f, 1f),
                Cue.LINE_TYPE_FRACTION,
            )
            .setLineAnchor(if (topAligned) Cue.ANCHOR_TYPE_START else Cue.ANCHOR_TYPE_END)
            .apply {
                if (reference != null) {
                    setPosition(placement.left / width)
                    setPositionAnchor(Cue.ANCHOR_TYPE_START)
                    setTextAlignment(reference.textAlignment ?: Layout.Alignment.ALIGN_CENTER)
                }
            }
            .build()
        occupied += placement
        return placedCue
    }

    private fun estimatePrimaryBox(cue: Cue, width: Int, height: Int, fontPx: Float): SubtitleBox {
        val bitmap = cue.bitmap
        val nominalWidth = if (cue.size != Cue.DIMEN_UNSET) cue.size * width else width * 0.9f
        val boxHeight = if (bitmap != null) {
            (cue.bitmapHeight * height).coerceAtLeast(1f)
        } else {
            estimateTextHeight(cue.text?.toString().orEmpty(), nominalWidth, fontPx.coerceAtLeast(1f))
        }
        val cueWidth = if (bitmap != null) {
            (boxHeight * bitmap.width / bitmap.height).coerceAtMost(width.toFloat())
        } else {
            nominalWidth
        }
        val left = cueLeft(cue, width, cueWidth)
        val top = when {
            cue.line == Cue.DIMEN_UNSET -> height * (1f - primaryBottomPaddingFraction) - boxHeight
            cue.lineType == Cue.LINE_TYPE_FRACTION -> when (cue.lineAnchor) {
                Cue.ANCHOR_TYPE_END -> cue.line * height - boxHeight
                Cue.ANCHOR_TYPE_MIDDLE -> cue.line * height - boxHeight / 2f
                else -> cue.line * height
            }
            cue.line < 0f -> height * (1f - primaryBottomPaddingFraction) + cue.line * fontPx - boxHeight
            else -> cue.line * fontPx
        }
        return SubtitleBox(left, top, left + cueWidth, top + boxHeight)
    }

    private fun estimateSecondaryBox(
        cue: Cue,
        width: Int,
        height: Int,
        boxHeight: Float,
    ): SubtitleBox {
        val cueWidth = if (cue.size != Cue.DIMEN_UNSET) cue.size * width else width * 0.9f
        val left = cueLeft(cue, width, cueWidth)
        val top = if (cue.line == Cue.DIMEN_UNSET) {
            height * (1f - primaryBottomPaddingFraction) - boxHeight
        } else if (cue.lineType == Cue.LINE_TYPE_NUMBER) {
            if (cue.line < 0f) height * (1f - primaryBottomPaddingFraction) + cue.line * (boxHeight / 2f)
            else cue.line * (boxHeight / 2f)
        } else when (cue.lineAnchor) {
            Cue.ANCHOR_TYPE_END -> cue.line * height - boxHeight
            Cue.ANCHOR_TYPE_MIDDLE -> cue.line * height - boxHeight / 2f
            else -> cue.line * height
        }
        return SubtitleBox(left, top, left + cueWidth, top + boxHeight)
    }

    private fun cueLeft(cue: Cue, width: Int, cueWidth: Float): Float {
        if (cue.position == Cue.DIMEN_UNSET) return (width - cueWidth) / 2f
        val anchorPosition = cue.position * width
        return when (cue.positionAnchor) {
            Cue.ANCHOR_TYPE_START -> anchorPosition
            Cue.ANCHOR_TYPE_END -> anchorPosition - cueWidth
            else -> anchorPosition - cueWidth / 2f
        }
    }

    private fun estimateTextHeight(text: String, availableWidth: Float, fontPx: Float): Float {
        val charsPerLine = (availableWidth / (fontPx * 0.52f)).toInt().coerceAtLeast(1)
        val lines = text.split('\n').sumOf { line ->
            maxOf(1, kotlin.math.ceil(line.length.toFloat() / charsPerLine).toInt())
        }
        return lines * fontPx * 1.25f
    }

    fun clear() {
        unmodifiedPrimaryCues = emptyList()
        primaryCues = emptyList()
        lastPrimaryForStacking = null
        lastPrimaryWasCentred = false
        primaryView.setCues(emptyList())
        select(false)
    }

    fun dispose() {
        disposed = true
        clear()
    }

    private fun applyStyle() {
        val weight = if (baseFontWeight >= 600) Typeface.BOLD else Typeface.NORMAL
        val edgeType = if (baseStrokeColor == Color.TRANSPARENT) {
            CaptionStyleCompat.EDGE_TYPE_NONE
        } else {
            CaptionStyleCompat.EDGE_TYPE_OUTLINE
        }
        view.setStyle(
            CaptionStyleCompat(
                textColorOverride ?: baseTextColor,
                baseBackgroundColor,
                Color.TRANSPARENT,
                edgeType,
                baseStrokeColor,
                Typeface.create(Typeface.DEFAULT, weight),
            ),
        )
        val size = fontSizeOverride ?: baseFontSize
        view.setFractionalTextSize(((size / 24f) * 0.06f).coerceAtLeast(0.01f))
        view.setBottomPaddingFraction(0f)
    }

}
