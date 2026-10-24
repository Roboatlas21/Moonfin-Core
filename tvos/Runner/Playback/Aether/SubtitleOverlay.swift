#if canImport(UIKit)
import UIKit

private typealias PlatformColor = UIColor
private typealias PlatformFont = UIFont
private typealias PlatformFontWeight = UIFont.Weight
private typealias PlatformImage = UIImage
private typealias PlatformImageView = UIImageView
#elseif canImport(AppKit)
import AppKit

private typealias PlatformColor = NSColor
private typealias PlatformFont = NSFont
private typealias PlatformFontWeight = NSFont.Weight
private typealias PlatformImage = NSImage
private typealias PlatformImageView = NSImageView
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
    private var baseTextEvents: [SubtitleEvent] = []
    private var extraTextOverlays: [SubtitleOverlay] = []
    private var activeBitmapEvents: [SubtitleEvent] = []
    private var extraBitmapViews: [PlatformImageView] = []
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
        for overlay in extraTextOverlays {
            if let region = overlay.visibleFrame { frame = frame.union(region) }
        }
        if !bitmapView.isHidden { frame = frame.union(bitmapView.frame) }
        for view in extraBitmapViews where !view.isHidden {
            frame = frame.union(view.frame)
        }
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
        baseTextEvents.first { $0.alignment != nil || $0.position != nil }
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
        if !secondary.baseTextEvents.isEmpty { secondary.setLabelText(secondary.baseText) }
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

    private var baseText: String {
        baseTextEvents.compactMap(\.text).joined(separator: "\n")
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
        if subtitleFontSize != appliedFontSize, !baseTextEvents.isEmpty {
            setLabelText(baseText)
        }
        for overlay in extraTextOverlays {
            overlay.frame = bounds
            overlay.layoutOverlay()
        }
        // Lay out the primary first: changing the gap in a centred pair moves both
        // tracks.
        primaryForStacking?.layoutTextLabel()
        layoutTextLabel()
        layoutBitmapViews()
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
        let fill = text.map { applyInlineEmphasis(to: fillText($0)) }
        let outline = text.map { applyInlineEmphasis(to: outlineText($0)) }
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
                    && $0.styledRuns == $1.styledRuns
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

        let bitmaps = covering.filter { $0.bitmap != nil }
        if !Self.drawsTheSameBitmaps(bitmaps, activeBitmapEvents) {
            showBitmaps(bitmaps)
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
            secondary.setLabelText(secondary.baseText)
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

    /// A separate authored position needs a separate label. Ordinary dialogue at
    /// the same position still joins into one multiline caption.
    private static func textGroups(_ events: [SubtitleEvent]) -> [[SubtitleEvent]] {
        var groups: [[SubtitleEvent]] = []
        for event in events {
            if let index = groups.firstIndex(where: {
                $0[0].alignment == event.alignment && $0[0].position == event.position
            }) {
                groups[index].append(event)
            } else {
                groups.append([event])
            }
        }
        if let normal = groups.firstIndex(where: {
            $0[0].alignment == nil && $0[0].position == nil
        }) {
            groups.swapAt(0, normal)
        }
        return groups
    }

    private func copyAppearance(to overlay: SubtitleOverlay) {
        overlay.subtitleUserFontSize = subtitleUserFontSize
        overlay.subtitlePositionBase = subtitlePositionBase
        overlay.authoredVerticalOffset = authoredVerticalOffset
        overlay.subtitleFontWeight = subtitleFontWeight
        overlay.subtitleTextColor = subtitleTextColor
        overlay.subtitleBgColor = subtitleBgColor
        overlay.subtitleStrokeColor = subtitleStrokeColor
        overlay.subtitleStrokeEnabled = subtitleStrokeEnabled
    }

    private func showText(_ events: [SubtitleEvent]) {
        activeTextEvents = events
        for overlay in extraTextOverlays { overlay.removeFromSuperview() }
        extraTextOverlays.removeAll()
        guard !events.isEmpty else {
            baseTextEvents = []
            setTextHidden(true)
            setLabelText(nil)
            primaryForStacking?.layoutTextLabel()
            secondaryForStacking?.layoutTextLabel()
            return
        }
        // The secondary follows the primary position instead of reusing its own
        // authored positions. Primary text can have independent positioned cues.
        let groups = primaryForStacking != nil && stackingEnabled
            ? [events] : Self.textGroups(events)
        baseTextEvents = groups[0]
        for group in groups.dropFirst() {
            let overlay = SubtitleOverlay(frame: bounds)
            copyAppearance(to: overlay)
            overlay.videoRectProvider = { [weak self] in self?.videoBox ?? .zero }
            addSubview(overlay)
            overlay.setEvents(group)
            overlay.update(currentTime: lastUpdateTime)
            extraTextOverlays.append(overlay)
        }
        setLabelText(baseText)
        setTextHidden(false)
        layoutTextLabel()
        if let primary = primaryForStacking {
            primary.layoutTextLabel()
            layoutTextLabel()
        } else if let secondary = secondaryForStacking {
            // Both the text styling and the secondary position may have changed.
            if !secondary.baseTextEvents.isEmpty {
                secondary.setLabelText(secondary.baseText)
            }
            secondary.layoutTextLabel()
        }
        updateSecondaryPlacement()
    }

    private static func drawsTheSameBitmaps(
        _ lhs: [SubtitleEvent], _ rhs: [SubtitleEvent]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.startTime == $1.startTime && $0.endTime == $1.endTime
                && $0.normalizedRect == $1.normalizedRect
                && $0.canvasSize == $1.canvasSize
                && $0.bitmapWidth == $1.bitmapWidth
                && $0.bitmapHeight == $1.bitmapHeight
                && $0.bitmap === $1.bitmap
        }
    }

    private func showBitmaps(_ events: [SubtitleEvent]) {
        defer { updateSecondaryPlacement() }
        activeBitmapEvents = events
        while extraBitmapViews.count < max(0, events.count - 1) {
            let view = PlatformImageView()
            #if canImport(UIKit)
            view.contentMode = .scaleToFill
            insertSubview(view, belowSubview: assImageView)
            #else
            view.imageScaling = .scaleAxesIndependently
            addSubview(view, positioned: .below, relativeTo: assImageView)
            #endif
            extraBitmapViews.append(view)
        }
        for (index, view) in ([bitmapView] + extraBitmapViews).enumerated() {
            let bitmap = index < events.count ? events[index].bitmap : nil
            view.image = bitmap.map(Self.platformImage)
            view.isHidden = bitmap == nil
        }
        layoutBitmapViews()
    }

    private func hideAll() {
        showText([])
        showBitmaps([])
    }

    private func setTextHidden(_ hidden: Bool) {
        textLabel.isHidden = hidden
        outlineLabel.isHidden = hidden
    }

    /// Return a non-overlapping position for the secondary's full measured height.
    static func stackedSecondaryTop(
        primary: CGRect, height: CGFloat, gap: CGFloat, preferBelow: Bool,
        minimumY: CGFloat, maximumY: CGFloat
    ) -> (top: CGFloat, fits: Bool) {
        let above = primary.minY - gap - height
        let below = primary.maxY + gap
        let aboveFits = above >= minimumY
        let belowFits = below + height <= maximumY
        if preferBelow {
            if belowFits { return (below, true) }
            if aboveFits { return (above, true) }
        } else {
            if aboveFits { return (above, true) }
            if belowFits { return (below, true) }
        }
        // If both blocks cannot fit, clip the roomier edge rather than overlap.
        let aboveRoom = max(0, primary.minY - gap - minimumY)
        let belowRoom = max(0, maximumY - primary.maxY - gap)
        return aboveRoom >= belowRoom ? (above, false) : (below, false)
    }

    private func layoutTextLabel() {
        guard !textLabel.isHidden else { return }
        let placement = primaryForStacking != nil && stackingEnabled ? nil
            : activeTextPlacement
        let safeWidth = placement == nil
            ? bounds.width - safeAreaInsets.left - safeAreaInsets.right : bounds.width
        let maxWidth = max(1, safeWidth * 0.9)
        let size = textLabel.sizeThatFits(
            CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
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
        let minimumX: CGFloat = placement == nil ? safeAreaInsets.left : 0
        let maximumX: CGFloat = placement == nil
            ? bounds.width - safeAreaInsets.right : bounds.width
        let minimumY: CGFloat = placement == nil ? safeAreaInsets.top : 0
        let maximumY: CGFloat = placement == nil
            ? bounds.height - safeAreaInsets.bottom : bounds.height
        var requiresEdgeClipping = false
        if let primary = primaryForStacking, stackingEnabled,
           let parentFrame = primary.stackingFrame {
            // Align with the primary, but use final measured rectangles to avoid overlap.
            let parentAlignment = primary.currentAlignment
            let parentColumn = (parentAlignment - 1) % 3
            let parentRow = (parentAlignment - 1) / 3
            x = parentColumn == 0 ? parentFrame.minX
                : parentColumn == 2 ? parentFrame.maxX - size.width
                : parentFrame.midX - size.width / 2
            let pairGap = max(2 * canvasScale, gap +
                CGFloat(secondaryVerticalAdjustment) * bounds.height)
            let resolved = Self.stackedSecondaryTop(
                primary: parentFrame, height: size.height, gap: pairGap,
                preferBelow: parentRow == 2,
                minimumY: minimumY, maximumY: maximumY)
            y = resolved.top
            requiresEdgeClipping = !resolved.fits
        } else if (currentAlignment - 1) / 3 == 1, let secondary = secondaryForStacking,
                  secondary.stackingEnabled {
            // Keep the midpoint of a centred pair fixed.
            let pairGap = max(2 * canvasScale, gap +
                CGFloat(secondary.secondaryVerticalAdjustment) * bounds.height)
            y = yAnchor + pairGap / 2
        }
        x = min(max(x, minimumX), max(minimumX, maximumX - size.width))
        if !requiresEdgeClipping {
            y = min(max(y, minimumY), max(minimumY, maximumY - size.height))
        }
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        textLabel.frame = frame
        outlineLabel.frame = frame
        rememberPrimaryPlacement()
    }

    private func layoutBitmapViews() {
        let box = videoBox
        for (index, event) in activeBitmapEvents.enumerated() {
            let view = index == 0 ? bitmapView : extraBitmapViews[index - 1]
            if let rect = event.normalizedRect, let canvas = event.canvasSize,
                canvas.width > 0, canvas.height > 0
            {
                // Authored image regions share one composition canvas.
                let scale = box.width / canvas.width
                let canvasHeight = canvas.height * scale
                let yOrigin = box.midY - canvasHeight / 2
                view.frame = CGRect(
                    x: box.minX + rect.origin.x * box.width,
                    y: yOrigin + rect.origin.y * canvasHeight,
                    width: rect.size.width * box.width,
                    height: rect.size.height * canvasHeight
                )
            } else if event.bitmapWidth > 0 {
                let scale = min(bounds.width / CGFloat(event.bitmapWidth), 1.0)
                let w = CGFloat(event.bitmapWidth) * scale
                let h = CGFloat(event.bitmapHeight) * scale
                view.frame = CGRect(
                    x: (bounds.width - w) / 2,
                    y: bounds.height - h - bitmapBottomOffset,
                    width: w, height: h
                )
            }
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

    private func styledFont(for run: SubtitleStyledRun) -> PlatformFont {
        let font = PlatformFont.systemFont(
            ofSize: appliedFontSize, weight: run.isBold ? .bold : subtitleFontWeight)
        guard run.isItalic else { return font }
        #if canImport(UIKit)
        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return PlatformFont(descriptor: descriptor, size: appliedFontSize)
        #else
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #endif
    }

    private func applyInlineEmphasis(to text: NSAttributedString) -> NSAttributedString {
        guard baseTextEvents.contains(where: { $0.styledRuns != nil }) else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        var location = 0
        for (index, event) in baseTextEvents.enumerated() {
            if index > 0 { location += 1 }  // Joined cues have one newline between them.
            let length = event.text?.utf16.count ?? 0
            if let runs = event.styledRuns,
               runs.reduce(0, { $0 + $1.text.utf16.count }) == length {
                var runStart = location
                for run in runs {
                    let runLength = run.text.utf16.count
                    let range = NSRange(location: runStart, length: runLength)
                    if runLength > 0 {
                        if run.isBold || run.isItalic {
                            result.addAttribute(.font, value: styledFont(for: run), range: range)
                        }
                        if run.isUnderlined {
                            result.addAttribute(
                                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                        }
                        if run.isStruckThrough {
                            result.addAttribute(
                                .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                        }
                    }
                    runStart += runLength
                }
            }
            location += length
        }
        return result
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
