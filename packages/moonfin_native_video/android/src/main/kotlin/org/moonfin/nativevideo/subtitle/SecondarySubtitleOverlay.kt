package org.moonfin.nativevideo.subtitle

import android.graphics.Color
import android.graphics.Typeface
import android.text.Layout
import android.view.View
import androidx.media3.common.text.Cue
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView

/**
 * Apply the primary offset inward: top cues move down and bottom cues move up. Leave
 * middle cues unchanged here. Automatically positioned cues use Media3 bottom padding.
 * Convert numbered WebVTT lines only when applying an offset; at zero, preserve their
 * original line numbers.
 */
internal fun offsetPrimaryCue(
    cue: Cue,
    verticalOffset: Float,
    lineHeightFraction: Float,
): Cue {
    if (verticalOffset <= 0f || cue.bitmap != null || cue.line == Cue.DIMEN_UNSET) return cue
    val line = when (cue.lineType) {
        Cue.LINE_TYPE_FRACTION -> cue.line
        Cue.LINE_TYPE_NUMBER -> if (cue.line < 0f)
            1f + (cue.line + 1f) * lineHeightFraction
        else cue.line * lineHeightFraction
        else -> return cue
    }
    val direction = when {
        line < 1f / 3f -> 1f
        line > 2f / 3f -> -1f
        else -> return cue
    }
    val builder = cue.buildUpon().setLine(
        (line + direction * verticalOffset).coerceIn(0f, 1f),
        Cue.LINE_TYPE_FRACTION,
    )
    if (cue.lineType == Cue.LINE_TYPE_NUMBER) {
        builder.setLineAnchor(if (cue.line < 0f) Cue.ANCHOR_TYPE_END else Cue.ANCHOR_TYPE_START)
    }
    return builder.build()
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
    private var lastPrimaryForStacking: Cue? = null
    private var lastPrimaryWasCentred = false
    private var primaryEnabled = true

    init {
        view.setApplyEmbeddedStyles(true)
        view.setApplyEmbeddedFontSizes(false)
        view.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            renderCues()
        }
        applyStyle()
        view.setCues(emptyList())
    }

    /** Clear the previous track's cues. Media3 handles loading, timing and seeking. */
    fun select(enabled: Boolean) {
        val alreadySelected = secondaryCues != null
        secondaryCues = if (enabled) emptyList() else null
        if (!enabled || !alreadySelected) {
            // Clear the saved primary placement when secondary subtitles are enabled or
            // disabled. Keep it when switching secondary tracks so gaps in dialogue do
            // not reset the layout.
            lastPrimaryForStacking = null
            lastPrimaryWasCentred = false
        }
        renderCues()
    }

    /** Remove an old secondary cue before retiming without disturbing primary placement. */
    fun clearSecondaryCues() {
        if (secondaryCues == null) return
        secondaryCues = emptyList()
        renderCues()
    }

    fun updateCues(cues: List<Cue>) {
        if (secondaryCues == null || disposed) return
        secondaryCues = cues.filter { it.text != null }.map { cue ->
            cue.buildUpon()
                .setText(keepSubtitleEmphasis(requireNotNull(cue.text)))
                .clearWindowColor()
                .build()
        }
        renderCues()
    }

    fun configureBaseStyle(
        textColor: Int,
        backgroundColor: Int,
        strokeColor: Int,
        fontSize: Float?,
        fontWeight: Int,
        verticalOffset: Float?,
        embeddedStylesEnabled: Boolean = true,
    ) {
        view.setApplyEmbeddedStyles(embeddedStylesEnabled)
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

    /**
     * A seek or new primary track must not reuse the previous primary cue's
     * placement. Clearing secondary cues on seek keeps the track selected.
     */
    fun resetPrimaryCues(clearSecondary: Boolean = false) {
        unmodifiedPrimaryCues = emptyList()
        primaryCues = emptyList()
        lastPrimaryForStacking = null
        lastPrimaryWasCentred = false
        if (clearSecondary && secondaryCues != null) secondaryCues = emptyList()
        renderCues()
    }

    /** Switching primary On/Off resets placement; ordinary dialogue gaps do not. */
    fun setPrimaryEnabled(enabled: Boolean) {
        if (primaryEnabled == enabled) return
        primaryEnabled = enabled
        resetPrimaryCues()
    }

    fun updatePrimaryCues(cues: List<Cue>) {
        if (!primaryEnabled) return
        unmodifiedPrimaryCues = cues
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
        if (!primaryEnabled) {
            // With the primary off, use the normal bottom position without the extra
            // gap. Keep the saved spacing for when the primary is enabled again.
            primaryView.setCues(emptyList())
            view.visibility = View.VISIBLE
            view.setCues(if (active.isEmpty()) emptyList() else listOf(
                Cue.Builder()
                    .setText(joinKeepingSpans(active.map { requireNotNull(it.text) }))
                    .setLine((1f - primaryBottomPaddingFraction).coerceIn(0f, 1f), Cue.LINE_TYPE_FRACTION)
                    .setLineAnchor(Cue.ANCHOR_TYPE_END)
                    .build(),
            ))
            return
        }
        val width = view.width
        val height = view.height
        // Keep the gap centred on the original cue position while secondary subtitles
        // are enabled, even when no secondary cue is visible. Added lines grow away
        // from the gap instead of moving the primary.
        val gapPx = MIN_GAP_DP * view.resources.displayMetrics.density
        val minimumGapPx = 2f * view.resources.displayMetrics.density
        val middleGapPx = SubtitleLayoutPlanner.middleGap(
            gapPx, offsetDelta, height, minimumGapPx)
        primaryCues = unmodifiedPrimaryCues.map { cue ->
            val positioned = offsetPrimaryCue(
                cue, primaryBottomPaddingFraction,
                (baseFontSize / 24f) * 0.06f * 1.25f,
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
        // Position secondary cues relative to the primary's current or last known
        // placement.
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
            val text = joinKeepingSpans(group.map { requireNotNull(it.text) })
            placeAutomaticCue(
                buildCue(group.first()).buildUpon().setText(text).build(), text.toString(), width, height, secondaryFontPx, occupied, gapPx,
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
            val clearance = if (centred) minimumGapPx / 2f else gapPx
            SubtitleLayoutPlanner.placePositionedSecondary(
                occupied, width, height, desired, alignment, clearance, gapPx,
            ) ?: if (alignment == SubtitleLayoutPlanner.ALIGN_MIDDLE) null
            else {
                // At high primary offsets, both subtitle rows may not fit in one
                // half. Preserve their order and gap rather than hiding a row.
                SubtitleLayoutPlanner.placePositionedSecondary(
                    occupied, width, height, desired, alignment, clearance, gapPx,
                    lowerHalfTop = if (alignment == SubtitleLayoutPlanner.ALIGN_TOP)
                        height.toFloat() else 0f,
                )
            }
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
                    // Media3 fits an unspecified cue width to the text. Keep the
                    // primary anchor instead of anchoring that smaller box at the
                    // left edge of the rectangle used for collision checks.
                    setPosition(if (reference.position == Cue.DIMEN_UNSET) 0.5f else reference.position)
                    setPositionAnchor(if (reference.position == Cue.DIMEN_UNSET)
                        Cue.ANCHOR_TYPE_MIDDLE else reference.positionAnchor)
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
