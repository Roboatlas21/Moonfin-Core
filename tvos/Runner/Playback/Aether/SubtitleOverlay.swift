#if canImport(UIKit)
import UIKit

private typealias PlatformColor = UIColor
private typealias PlatformFont = UIFont
private typealias PlatformFontWeight = UIFont.Weight
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit

private typealias PlatformColor = NSColor
private typealias PlatformFont = NSFont
private typealias PlatformFontWeight = NSFont.Weight
private typealias PlatformImage = NSImage
#endif

final class SubtitleOverlay: PlatformView {

    #if canImport(UIKit)
    private let outlineLabel = UILabel()
    private let textLabel = UILabel()
    private let bitmapView = UIImageView()
    private let assImageView = UIImageView()
    #else
    private let outlineLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let bitmapView = NSImageView()
    private let assImageView = NSImageView()
    #endif
    private var eventQueue: [SubtitleEvent] = []
    /// Every text cue covering the playhead, not just one: cues sharing a window
    /// are distinct simultaneous speakers and the engine keeps them all.
    private var activeTextEvents: [SubtitleEvent] = []
    private var activeBitmapEvent: SubtitleEvent?
    private var lastUpdateTime: TimeInterval = 0
    var delaySeconds: TimeInterval = 0
    /// The secondary text follows the primary frame, using its last frame during gaps
    /// in dialogue.
    weak var primaryForStacking: SubtitleOverlay?
    weak var secondaryForStacking: SubtitleOverlay?
    var stackingEnabled = false {
        didSet {
            primaryForStacking?.requestLayout()
            requestLayout()
        }
    }
    // Store the last frame in relative coordinates so dialogue gaps survive a resize.
    private var lastPrimaryFrame: CGRect?
    private var assVisibleBounds: CGRect?
    private var lastPrimaryAlignment = 2
    var secondaryVerticalAdjustment: Double = 0 {
        didSet {
            primaryForStacking?.requestLayout()
            requestLayout()
        }
    }

    private var visibleFrame: CGRect? {
        var frame = CGRect.null
        if !textLabel.isHidden { frame = frame.union(textLabel.frame) }
        if !bitmapView.isHidden { frame = frame.union(bitmapView.frame) }
        if !assImageView.isHidden, let rect = assVisibleBounds {
            let canvas = assCanvas
            frame = frame.union(CGRect(
                x: canvas.minX + rect.minX * canvas.width,
                y: canvas.minY + rect.minY * canvas.height,
                width: rect.width * canvas.width, height: rect.height * canvas.height))
        }
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    private var stackingFrame: CGRect? {
        if let frame = visibleFrame { return frame }
        return lastPrimaryFrame.map {
            CGRect(x: $0.minX * bounds.width, y: $0.minY * bounds.height,
                   width: $0.width * bounds.width, height: $0.height * bounds.height)
        }
    }

    private var activeTextPlacement: SubtitleEvent? {
        activeTextEvents.first { $0.alignment != nil || $0.position != nil }
    }

    private var currentAlignment: Int {
        if let primary = primaryForStacking, stackingEnabled {
            return primary.currentAlignment
        }
        if !activeTextEvents.isEmpty {
            let placement = activeTextPlacement
            let authored = placement?.alignment ?? 2
            let alignment = (1...9).contains(authored) ? authored : 2
            guard let position = placement?.position else { return alignment }
            // WebVTT's line alignment is an anchor, not a screen region: a bottom
            // anchor at line:10%,end still needs the secondary below the primary.
            let row = position.y < 1.0 / 3 ? 2 : position.y > 2.0 / 3 ? 0 : 1
            return row * 3 + (alignment - 1) % 3 + 1
        }
        if let frame = visibleFrame {
            let row = frame.midY < bounds.height / 3 ? 2
                : frame.midY > bounds.height * 2 / 3 ? 0 : 1
            return row * 3 + 2
        }
        return lastPrimaryAlignment
    }

    private func rememberPrimaryPlacement() {
        guard secondaryForStacking != nil, let frame = visibleFrame,
              bounds.width > 0, bounds.height > 0 else { return }
        lastPrimaryFrame = CGRect(
            x: frame.minX / bounds.width, y: frame.minY / bounds.height,
            width: frame.width / bounds.width, height: frame.height / bounds.height)
        lastPrimaryAlignment = currentAlignment
    }

    private func updateSecondaryPlacement() {
        rememberPrimaryPlacement()
        guard let secondary = secondaryForStacking else { return }
        if !secondary.activeTextEvents.isEmpty { secondary.setLabelText(secondary.activeText) }
        secondary.layoutTextLabel()
    }

    /// On while a subtitle track is selected. iPadOS 27 can drop these views
    /// from frames when a fullscreen video is the only other thing on screen,
    /// so a near-invisible backing keeps them composited with the picture the
    /// way the OSD does.
    var keepsVideoComposited = false {
        didSet {
            #if canImport(UIKit)
            backgroundColor = keepsVideoComposited ? UIColor(white: 0, alpha: 0.01) : .clear
            #endif
        }
    }

    /// What the label is showing: the covering cues joined in start order.
    var activeText: String {
        activeTextEvents.compactMap(\.text).joined(separator: "\n")
    }

    /// Where the picture sits inside the overlay. A TV gives the video the
    /// whole surface, but a phone letterboxes anything shaped differently, and
    /// bitmap cues are authored against the picture. An empty rect falls back
    /// to the full bounds.
    var videoRectProvider: (() -> CGRect)?

    private var videoBox: CGRect {
        guard let rect = videoRectProvider?(), !rect.isEmpty else { return bounds }
        return rect
    }

    /// ASS positions are authored against the picture, so libass draws into the
    /// video rect. Clamping it to the view leaves fill mode, where the picture runs
    /// past the edges, drawing across the whole view.
    var assCanvas: CGRect {
        let canvas = videoBox.intersection(bounds)
        return canvas.isEmpty ? bounds : canvas
    }

    /// Keep the user font size and native 40–100 position value until layout, when the
    /// view size is known. Font size scales with view height; the user text offset is
    /// handled separately using picture height.
    private var subtitleUserFontSize: CGFloat = 24
    private var subtitlePositionBase = 100
    // The authored cue's vertical position remains the baseline; this offset
    // moves top cues down and bottom cues up, never middle cues.
    private var authoredVerticalOffset: CGFloat = 0
    private var subtitleFontWeight: PlatformFontWeight = .semibold
    private var subtitleTextColor: PlatformColor = .white
    private var subtitleBgColor: PlatformColor = .clear
    private var subtitleStrokeColor: PlatformColor = .black
    private var subtitleStrokeEnabled = true
    /// Point size the label's text was last built at, so layout only rebuilds
    /// it when the height actually changed.
    private var appliedFontSize: CGFloat = 0

    /// The tuned TV mapping (user 24 gives 55pt, floor 24, ceiling 120) held
    /// against a 1080pt canvas. Everything below scales that reference by the
    /// real height, so a 1080pt canvas comes out exactly as it did before.
    private static let referenceHeight: CGFloat = 1080

    private var canvasHeight: CGFloat {
        bounds.height > 0 ? bounds.height : Self.referenceHeight
    }

    private var canvasScale: CGFloat { canvasHeight / Self.referenceHeight }

    private var subtitleFontSize: CGFloat {
        let scale = canvasScale
        let points = subtitleUserFontSize / 24.0 * 55.0 * scale
        return min(max(points, 24 * scale), 120 * scale)
    }

    private var subtitleStrokeWidth: CGFloat {
        subtitleStrokeEnabled ? max(2 * canvasScale, 1) : 0
    }

    /// Keep the 40–100 position scale for the temporary lift above playback controls
    /// and for bitmap fallback. The user's text offset uses a fraction of the picture
    /// height.
    private var positionScaleBottomOffset: CGFloat {
        canvasHeight * 0.5 * CGFloat(100 - subtitlePositionBase) / 60.0
    }

    private var textBottomOffset: CGFloat {
        let normalPosition = 100 - Int((Double(authoredVerticalOffset) * 60).rounded())
        return subtitlePositionBase < normalPosition
            ? positionScaleBottomOffset
            : videoBox.height * authoredVerticalOffset
    }

    /// A bitmap cue that arrives without a canvas rect has nothing tying it to
    /// the picture, so it keeps a margin off the edge on top of the position.
    /// The margin stays absolute rather than scaling with height, since those
    /// cues already sit correctly on a phone.
    private var bitmapBottomOffset: CGFloat {
        40 + positionScaleBottomOffset
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        for label in [outlineLabel, textLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        bitmapView.contentMode = .scaleToFill
        assImageView.contentMode = .scaleToFill
        #else
        wantsLayer = true

        for label in [outlineLabel, textLabel] {
            label.maximumNumberOfLines = 0
            label.alignment = .center
            label.isBezeled = false
            label.drawsBackground = false
        }
        bitmapView.imageScaling = .scaleAxesIndependently
        assImageView.imageScaling = .scaleAxesIndependently
        #endif
        // The outline goes under the fill, so it is added first.
        for label in [outlineLabel, textLabel] {
            label.isHidden = true
            addSubview(label)
        }
        bitmapView.isHidden = true
        addSubview(bitmapView)
        assImageView.isHidden = true
        addSubview(assImageView)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutOverlay()
    }
    #else
    // Keeps the shared top-left layout math valid on AppKit.
    override var isFlipped: Bool { true }

    // The overlay sits above the video but must never eat clicks meant for
    // the Flutter OSD underneath the platform view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutOverlay()
    }
    #endif

    private func layoutOverlay() {
        // The point size follows the height, so it changes on resize and on
        // the first real layout after a style was applied against zero bounds.
        if subtitleFontSize != appliedFontSize, !activeTextEvents.isEmpty {
            setLabelText(activeText)
        }
        // Lay out the primary first: changing the gap in a centred pair moves both
        // tracks.
        primaryForStacking?.layoutTextLabel()
        layoutTextLabel()
        layoutBitmapView()
        assImageView.frame = assCanvas
        updateSecondaryPlacement()
    }

    private func requestLayout() {
        #if canImport(UIKit)
        setNeedsLayout()
        #else
        needsLayout = true
        #endif
    }

    private func setLabelText(_ text: String?) {
        appliedFontSize = subtitleFontSize
        let fill = text.map(fillText)
        let outline = text.map(outlineText)
        #if canImport(UIKit)
        textLabel.attributedText = fill
        outlineLabel.attributedText = outline
        #else
        textLabel.attributedStringValue = fill ?? NSAttributedString()
        outlineLabel.attributedStringValue = outline ?? NSAttributedString()
        #endif
    }

    private static func platformImage(_ image: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: image)
        #else
        return NSImage(
            cgImage: image, size: NSSize(width: image.width, height: image.height))
        #endif
    }

    func showAssImage(_ image: CGImage?, bounds: CGRect? = nil) {
        assVisibleBounds = image == nil ? nil : bounds
        if let image {
            // A zoom change moves the picture without a layout pass, so the frame
            // follows each render instead of waiting for one.
            assImageView.frame = assCanvas
            assImageView.image = Self.platformImage(image)
            assImageView.isHidden = false
        } else {
            assImageView.image = nil
            assImageView.isHidden = true
        }
        updateSecondaryPlacement()
    }

    /// The engine republishes the full active-cue set, so replace the queue
    /// wholesale and re-evaluate at the last known clock so a cue swap shows
    /// without waiting for the next tick. The only writer of `eventQueue`: the
    /// overlay never drops a cue itself, because for a sidecar track this queue
    /// is the only copy there is. The engine publishes such a file once and
    /// clears its drain target, so a cue discarded here never comes back and the
    /// rest of the session plays with holes in it. Retention belongs to the
    /// engine, which prunes the tracks it actually drains.
    func setEvents(_ events: [SubtitleEvent]) {
        eventQueue = events.sorted { $0.startTime < $1.startTime }
        if lastUpdateTime > 0 {
            evaluate(at: lastUpdateTime)
        } else if events.isEmpty {
            hideAll()
        }
    }

    func update(currentTime: TimeInterval) {
        lastUpdateTime = currentTime
        evaluate(at: currentTime)
    }

    /// Every cue whose window covers `adjustedTime`. Static and pure for unit
    /// tests: a clock that jumps forward and back, and two speakers sharing a
    /// window, are both decided here.
    static func activeEvents(
        in events: [SubtitleEvent], at adjustedTime: TimeInterval
    ) -> [SubtitleEvent] {
        events.filter { adjustedTime >= $0.startTime && adjustedTime < $0.endTime }
    }

    /// Whether two cue sets would draw the same block. Keyed on the window as
    /// well as the text, since the engine rewrites a cue's end time in place to
    /// close an open-ended line (a teletext page replacement, a PGS trim), and a
    /// start-only comparison leaves the retired line on screen.
    private static func drawsTheSame(_ lhs: [SubtitleEvent], _ rhs: [SubtitleEvent]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy {
                $0.startTime == $1.startTime && $0.endTime == $1.endTime
                    && $0.text == $1.text && $0.alignment == $1.alignment
                    && $0.position == $1.position
            }
    }

    private func evaluate(at currentTime: TimeInterval) {
        let adjusted = currentTime - delaySeconds
        let covering = Self.activeEvents(in: eventQueue, at: adjusted)

        // Text and bitmap are tracked apart so neither hides the other.
        let texts = covering.filter { $0.text != nil }
        if !Self.drawsTheSame(texts, activeTextEvents) {
            showText(texts)
        }

        let bitmap = covering.first { $0.bitmap != nil }
        if bitmap?.startTime != activeBitmapEvent?.startTime {
            showBitmap(bitmap)
        }
    }

    func clear() {
        eventQueue.removeAll()
        lastUpdateTime = 0
        assImageView.image = nil
        assImageView.isHidden = true
        assVisibleBounds = nil
        hideAll()
        lastPrimaryFrame = nil
        lastPrimaryAlignment = 2
        // Clearing the primary track resets the secondary text alignment. A gap in
        // dialogue calls showText([]) and preserves it.
        if let secondary = secondaryForStacking,
           secondary.stackingEnabled, !secondary.activeTextEvents.isEmpty {
            secondary.setLabelText(secondary.activeText)
            secondary.layoutTextLabel()
        }
    }

    /// Applies the Dart subtitle style. Colours are ARGB integers and fontSize uses the
    /// 24-based scale. verticalOffset is a fraction of picture height: it moves top
    /// text down and bottom text up, leaving middle text unchanged.
    func applyStyle(
        textColor: Int?,
        backgroundColor: Int?,
        strokeColor: Int?,
        fontSize: Double?,
        fontWeight: Int?,
        verticalOffset: Double?
    ) {
        if let textColor { subtitleTextColor = Self.colorFromARGB(textColor) }
        if let backgroundColor { subtitleBgColor = Self.colorFromARGB(backgroundColor) }
        if let strokeColor {
            subtitleStrokeColor = Self.colorFromARGB(strokeColor)
            subtitleStrokeEnabled = Self.colorFromARGB(strokeColor) != .clear
        }
        if let fontSize, fontSize > 0 {
            subtitleUserFontSize = CGFloat(fontSize)
        }
        if let fontWeight {
            subtitleFontWeight = fontWeight >= 600 ? .bold : .semibold
        }
        if let verticalOffset {
            authoredVerticalOffset = CGFloat(min(max(verticalOffset, 0), 1))
            setSubtitlePosition(basePosition: 100 - Int((verticalOffset * 60).rounded()))
        }
        if !activeTextEvents.isEmpty {
            showText(activeTextEvents)
        }
    }

    /// Use the primary size and colour when the secondary override is nil. Leave
    /// extra spacing and delay unchanged.
    func applySecondaryStyle(from primary: SubtitleOverlay, fontSize: Double?, textColor: Int?) {
        subtitleUserFontSize = fontSize.map { CGFloat(min(max($0, 6), 72)) }
            ?? primary.subtitleUserFontSize
        subtitleTextColor = textColor.map { Self.colorFromARGB($0) } ?? primary.subtitleTextColor
        subtitleFontWeight = primary.subtitleFontWeight
        subtitleBgColor = primary.subtitleBgColor
        subtitleStrokeColor = primary.subtitleStrokeColor
        subtitleStrokeEnabled = primary.subtitleStrokeEnabled
        authoredVerticalOffset = primary.authoredVerticalOffset
        subtitlePositionBase = primary.subtitlePositionBase
        if !activeTextEvents.isEmpty { showText(activeTextEvents) }
    }

    /// Sets the native 40–100 position scale used for the temporary controls lift and
    /// bitmap fallback. A value of 100 adds no bottom offset; visible controls use
    /// min(base, 70).
    func setSubtitlePosition(basePosition: Int) {
        subtitlePositionBase = min(max(basePosition, 40), 100)
        requestLayout()
    }

    // MARK: - Display

    /// Draws active text cues as one block, joined in start order, using the selected
    /// cue alignment.
    private func showText(_ events: [SubtitleEvent]) {
        activeTextEvents = events
        guard !events.isEmpty else {
            setTextHidden(true)
            setLabelText(nil)
            primaryForStacking?.layoutTextLabel()
            secondaryForStacking?.layoutTextLabel()
            return
        }
        setLabelText(activeText)
        setTextHidden(false)
        layoutTextLabel()
        if let primary = primaryForStacking {
            primary.layoutTextLabel()
            layoutTextLabel()
        } else if let secondary = secondaryForStacking {
            // A new primary alignment also changes secondary paragraph alignment.
            if !secondary.activeTextEvents.isEmpty {
                secondary.setLabelText(secondary.activeText)
            }
            secondary.layoutTextLabel()
        }
    }

    private func showBitmap(_ event: SubtitleEvent?) {
        defer { updateSecondaryPlacement() }
        activeBitmapEvent = event
        guard let bitmap = event?.bitmap else {
            bitmapView.isHidden = true
            bitmapView.image = nil
            return
        }
        bitmapView.image = Self.platformImage(bitmap)
        bitmapView.isHidden = false
        layoutBitmapView()
    }

    private func hideAll() {
        showText([])
        showBitmap(nil)
    }

    private func setTextHidden(_ hidden: Bool) {
        textLabel.isHidden = hidden
        outlineLabel.isHidden = hidden
    }

    private func layoutTextLabel() {
        guard !textLabel.isHidden else { return }
        let maxWidth = bounds.width * 0.9
        let size = textLabel.sizeThatFits(CGSize(width: maxWidth, height: bounds.height * 0.4))
        let placement = primaryForStacking != nil && stackingEnabled ? nil
            : activeTextPlacement
        let authoredAlignment = (1...9).contains(placement?.alignment ?? 2)
            ? (placement?.alignment ?? 2) : 2
        let alignment = primaryForStacking != nil && stackingEnabled
            ? currentAlignment : authoredAlignment
        let column = (alignment - 1) % 3
        let row = (alignment - 1) / 3
        let picture = videoBox
        let xAnchor = placement?.position.map { picture.minX + $0.x * picture.width }
            ?? bounds.width * ([0.05, 0.5, 0.95][column])
        let yAnchor = placement?.position.map { position -> CGFloat in
            let direction: CGFloat = position.y < 1.0 / 3 ? 1
                : position.y > 2.0 / 3 ? -1 : 0
            // Bottom cues keep their authored baseline while using the same
            // temporary controls lift as unpositioned text.
            let offset = direction < 0 ? textBottomOffset
                : picture.height * authoredVerticalOffset
            let y = position.y * picture.height + direction * offset
            return picture.minY + min(max(y, 0), picture.height)
        } ?? (row == 0 ? bounds.height - textBottomOffset
                : row == 1 ? bounds.height / 2
                    : bounds.height * 0.05 + textBottomOffset)
        var x = xAnchor - size.width * CGFloat(column) / 2
        var y = yAnchor - size.height * CGFloat(2 - row) / 2
        let gap = 8 * canvasScale
        if let primary = primaryForStacking, stackingEnabled,
           let parentFrame = primary.stackingFrame {
            // Use the primary's top, middle or bottom alignment and match its
            // horizontal anchor.
            let parentAlignment = primary.currentAlignment
            let parentColumn = (parentAlignment - 1) % 3
            let parentRow = (parentAlignment - 1) / 3
            x = parentColumn == 0 ? parentFrame.minX
                : parentColumn == 2 ? parentFrame.maxX - size.width
                : parentFrame.midX - size.width / 2
            if parentRow == 1 {
                let pairGap = max(2 * canvasScale, gap +
                    CGFloat(secondaryVerticalAdjustment) * bounds.height)
                y = parentFrame.minY - size.height - pairGap
            } else {
                y = parentRow == 2 ? parentFrame.maxY + gap
                    : parentFrame.minY - size.height - gap
                y += (parentRow == 2 ? 1 : -1) *
                    CGFloat(secondaryVerticalAdjustment) * bounds.height
            }
        } else if (currentAlignment - 1) / 3 == 1, let secondary = secondaryForStacking,
                  secondary.stackingEnabled {
            // Keep the gap centred on the original cue position so adding or removing
            // secondary lines does not move the primary.
            let pairGap = max(2 * canvasScale, gap +
                CGFloat(secondary.secondaryVerticalAdjustment) * bounds.height)
            y = yAnchor + pairGap / 2
        }
        x = min(max(x, 0), max(0, bounds.width - size.width))
        y = min(max(y, 0), max(0, bounds.height - size.height))
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        textLabel.frame = frame
        outlineLabel.frame = frame
        rememberPrimaryPlacement()
    }

    private func layoutBitmapView() {
        guard !bitmapView.isHidden, let event = activeBitmapEvent else { return }
        let box = videoBox
        if let rect = event.normalizedRect, let canvas = event.canvasSize,
            canvas.width > 0, canvas.height > 0
        {
            // Map the authored composition canvas onto the picture
            // width-aligned and center-anchored (the canvas may be taller than
            // the coded video for cropped rips), then place the cue inside it.
            let scale = box.width / canvas.width
            let canvasHeight = canvas.height * scale
            let yOrigin = box.midY - canvasHeight / 2
            bitmapView.frame = CGRect(
                x: box.minX + rect.origin.x * box.width,
                y: yOrigin + rect.origin.y * canvasHeight,
                width: rect.size.width * box.width,
                height: rect.size.height * canvasHeight
            )
        } else if event.bitmapWidth > 0 {
            // No canvas means nothing ties the cue to the picture, so it keeps
            // measuring from the surface.
            let scale = min(bounds.width / CGFloat(event.bitmapWidth), 1.0)
            let w = CGFloat(event.bitmapWidth) * scale
            let h = CGFloat(event.bitmapHeight) * scale
            bitmapView.frame = CGRect(
                x: (bounds.width - w) / 2,
                y: bounds.height - h - bitmapBottomOffset,
                width: w,
                height: h
            )
        }
    }

    private func labelFont() -> PlatformFont {
        PlatformFont.systemFont(ofSize: appliedFontSize, weight: subtitleFontWeight)
    }

    /// Set paragraph alignment on the attributed string from the cue alignment. Use the
    /// glyph height for line spacing so background fills do not leave gaps between
    /// lines.
    private func paragraphStyle(for font: PlatformFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let column = (currentAlignment - 1) % 3
        style.alignment = column == 0 ? .left : (column == 2 ? .right : .center)
        let glyphBox = font.ascender - font.descender
        style.minimumLineHeight = glyphBox
        style.maximumLineHeight = glyphBox
        return style
    }

    private func fillText(_ text: String) -> NSAttributedString {
        let font = labelFont()
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: subtitleTextColor,
                .paragraphStyle: paragraphStyle(for: font),
            ])
    }

    /// What sits under the text: the background box, and the outline when one
    /// is wanted. The outline is its own copy of the line rather than a stroke
    /// on the glyphs, since a stroke traces every contour a glyph is built from
    /// and letters made of overlapping pieces come out with the seams drawn
    /// across them. The fill on top covers those, leaving only the half of the
    /// line that falls outside the letter.
    private func outlineText(_ text: String) -> NSAttributedString {
        let font = labelFont()
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            // Nothing to fill here, or this copy shows through as a second set
            // of glyphs whenever there is no outline to draw.
            .foregroundColor: PlatformColor.clear,
            // Must match the fill, or the outline drifts off the letters.
            .paragraphStyle: paragraphStyle(for: font),
        ]
        if subtitleStrokeWidth > 0 {
            attrs[.strokeColor] = subtitleStrokeColor
            // Doubled, since only the outer half survives the fill on top.
            attrs[.strokeWidth] = subtitleStrokeWidth * 2
        }
        if subtitleBgColor != .clear {
            attrs[.backgroundColor] = subtitleBgColor
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static func colorFromARGB(_ argb: Int) -> PlatformColor {
        let alpha = (argb >> 24) & 0xFF
        if alpha == 0 { return .clear }
        return PlatformColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255.0,
            green: CGFloat((argb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(argb & 0xFF) / 255.0,
            alpha: CGFloat(alpha) / 255.0
        )
    }

}
