import UIKit
import QuartzCore
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
    private func cue(_ text: String, start: Double = 1, end: Double = 3) -> SubtitleEvent {
        SubtitleEvent(
            startTime: start, endTime: end, text: text,
            bitmap: nil, bitmapWidth: 0, bitmapHeight: 0)
    }


    @MainActor
    func testNewSubtitleCuesCanBeEvaluatedWhilePausedIncludingAtZero() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        primary.update(currentTime: 42)
        primary.clear() // Switching primary resets its remembered playback time.
        // Invoke the same presentation method the wrapper's primary publisher
        // uses; the test must not supply its own post-load clock update.
        AetherPlayerWrapper.presentSubtitleEvents(
            [cue("New language", start: 41, end: 45)], in: primary, at: 42)
        XCTAssertEqual(primary.activeText, "New language")

        let secondary = SubtitleOverlay(frame: primary.bounds)
        // The secondary publisher uses this method too, including at time zero.
        AetherPlayerWrapper.presentSubtitleEvents(
            [cue("At start", start: 0, end: 3)], in: secondary, at: 0)
        XCTAssertEqual(secondary.activeText, "At start")
    }

    @MainActor
    func testAppleOffsetUsesPictureHeightAndPreservesControlsLift() {
        let overlay = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        // Letterboxing must not change the offset distance for default or explicitly
        // positioned subtitles.
        overlay.videoRectProvider = { CGRect(x: 0, y: 50, width: 800, height: 300) }
        let label = overlay.subviews.compactMap { $0 as? UILabel }.last!

        func placed(_ alignment: Int, position: CGPoint? = nil) -> CGRect {
            overlay.setEvents([
                SubtitleEvent(startTime: 1, endTime: 3, text: "Caption",
                    bitmap: nil, bitmapWidth: 0, bitmapHeight: 0,
                    alignment: alignment, position: position)
            ])
            overlay.update(currentTime: 2)
            // setSubtitlePosition schedules layout without replacing the cues.
            overlay.layoutIfNeeded()
            return label.frame
        }

        let top = placed(7).minY
        let bottom = placed(2).maxY
        let authoredTop = placed(7, position: CGPoint(x: 0.5, y: 0.08)).minY
        let authoredBottom = placed(2, position: CGPoint(x: 0.5, y: 0.92)).maxY
        overlay.applyStyle(textColor: nil, backgroundColor: nil, strokeColor: nil,
                           fontSize: nil, fontWeight: nil, verticalOffset: 0.04)
        // Four percent of the 300pt picture is 12pt for both placement paths.
        XCTAssertEqual(placed(7).minY, top + 12, accuracy: 0.1)
        XCTAssertEqual(placed(2).maxY, bottom - 12, accuracy: 0.1)
        XCTAssertEqual(placed(7, position: CGPoint(x: 0.5, y: 0.08)).minY,
                       authoredTop + 12, accuracy: 0.1)
        XCTAssertEqual(placed(2, position: CGPoint(x: 0.5, y: 0.92)).maxY,
                       authoredBottom - 12, accuracy: 0.1)
        XCTAssertEqual(placed(5).midY, 200, accuracy: 0.1)

        // Showing playback controls raises the bottom subtitle by 100pt: 25% of the
        // 400pt view on the 40–100 position scale.
        overlay.setSubtitlePosition(basePosition: 70)
        XCTAssertEqual(placed(2).maxY, bottom - 100, accuracy: 0.1)
        XCTAssertEqual(placed(2, position: CGPoint(x: 0.5, y: 0.92)).maxY,
                       authoredBottom - 100, accuracy: 0.1)
        XCTAssertEqual(placed(7, position: CGPoint(x: 0.5, y: 0.08)).minY,
                       authoredTop + 12, accuracy: 0.1)
        overlay.setSubtitlePosition(basePosition: 98)
        XCTAssertEqual(placed(2).maxY, bottom - 12, accuracy: 0.1)
        XCTAssertEqual(placed(2, position: CGPoint(x: 0.5, y: 0.92)).maxY,
                       authoredBottom - 12, accuracy: 0.1)
    }

    @MainActor
    func testPositionedPrimaryUsesScreenRegionForStacking() {
        for (alignment, position) in [
            (2, CGPoint(x: 0.5, y: 0.1)), // line:10%,end
            (8, CGPoint(x: 0.5, y: 0.9)), // line:90%,start
            (2, CGPoint(x: 0.5, y: 0.5)), // line:50%,end
        ] {
            let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
            let secondary = SubtitleOverlay(frame: primary.bounds)
            primary.secondaryForStacking = secondary
            secondary.primaryForStacking = primary
            secondary.stackingEnabled = true
            secondary.secondaryVerticalAdjustment = 0.06
            primary.setEvents([SubtitleEvent(
                startTime: 1, endTime: 3, text: "Primary",
                bitmap: nil, bitmapWidth: 0, bitmapHeight: 0,
                alignment: alignment, position: position)])
            secondary.setEvents([cue("Secondary", end: 8)])
            primary.update(currentTime: 2)
            secondary.update(currentTime: 2)
            let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
            let secondaryLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!
            if position.y < 1.0 / 3 {
                XCTAssertGreaterThan(secondaryLabel.frame.minY, primaryLabel.frame.maxY)
            } else {
                XCTAssertLessThan(secondaryLabel.frame.maxY, primaryLabel.frame.minY)
            }
            if position.y == 0.5 {
                XCTAssertEqual((secondaryLabel.frame.maxY + primaryLabel.frame.minY) / 2,
                               200, accuracy: 0.1)
            }
            let stacked = secondaryLabel.frame
            primary.update(currentTime: 4)
            secondary.update(currentTime: 4)
            XCTAssertEqual(secondaryLabel.frame.minY, stacked.minY, accuracy: 0.1)
            primary.clear()
            XCTAssertEqual(secondaryLabel.frame.maxY, 400, accuracy: 0.1)
        }
    }

    @MainActor
    func testAppleSpacingFollowsPrimaryHeightNotSecondaryDialogue() {
        for alignment in [2, 7] {
            let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
            let secondary = SubtitleOverlay(frame: primary.bounds)
            primary.secondaryForStacking = secondary
            secondary.primaryForStacking = primary
            secondary.stackingEnabled = true

            let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
            let secondaryLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!

            func showPrimary(_ text: String) {
                primary.setEvents([
                    SubtitleEvent(startTime: 1, endTime: 4, text: text,
                        bitmap: nil, bitmapWidth: 0, bitmapHeight: 0,
                        alignment: alignment)
                ])
                primary.update(currentTime: 2)
            }
            secondary.setEvents([cue("Secondary")])
            secondary.update(currentTime: 2)
            showPrimary("One")
            let oneLinePrimary = primaryLabel.frame
            let startingTop = secondaryLabel.frame.minY
            let startingBottom = secondaryLabel.frame.maxY

            // Adding secondary lines keeps the primary in place and preserves the
            // secondary edge nearest it.
            secondary.setEvents([cue("One\nTwo\nThree")])
            secondary.update(currentTime: 2)
            XCTAssertEqual(primaryLabel.frame, oneLinePrimary)
            if alignment == 2 {
                XCTAssertEqual(secondaryLabel.frame.maxY, startingBottom, accuracy: 0.1)
            } else {
                XCTAssertEqual(secondaryLabel.frame.minY, startingTop, accuracy: 0.1)
            }

            // When the primary gains lines, move the secondary to preserve the gap.
            showPrimary("One\nTwo\nThree")
            XCTAssertGreaterThan(primaryLabel.frame.height, oneLinePrimary.height)
            if alignment == 2 {
                XCTAssertLessThan(secondaryLabel.frame.maxY, startingBottom)
            } else {
                XCTAssertGreaterThan(secondaryLabel.frame.minY, startingTop)
            }
            let activeTop = secondaryLabel.frame.minY
            let activeBottom = secondaryLabel.frame.maxY

            // Dialogue gaps must not discard the last known primary placement.
            primary.setEvents([])
            primary.update(currentTime: 2)
            XCTAssertEqual(secondaryLabel.frame.minY, activeTop, accuracy: 0.1)
            XCTAssertEqual(secondaryLabel.frame.maxY, activeBottom, accuracy: 0.1)
            secondary.setEvents([])
            secondary.update(currentTime: 2)
            secondary.setEvents([cue("Another")])
            secondary.update(currentTime: 2)
            if alignment == 2 {
                XCTAssertEqual(secondaryLabel.frame.maxY, activeBottom, accuracy: 0.1)
            } else {
                XCTAssertEqual(secondaryLabel.frame.minY, activeTop, accuracy: 0.1)
            }
        }
    }


    @MainActor
    func testPrimaryTrackClearResetsSecondaryAlignmentButDialogueGapDoesNot() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true

        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        func textAlignment() -> NSTextAlignment? {
            guard let style = label.attributedText?.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            else { return nil }
            return style.alignment
        }

        primary.setEvents([
            SubtitleEvent(startTime: 1, endTime: 3, text: "Top left",
                bitmap: nil, bitmapWidth: 0, bitmapHeight: 0, alignment: 7)
        ])
        secondary.setEvents([cue("Secondary", start: 1, end: 8)])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)
        XCTAssertEqual(textAlignment(), .left)

        // A gap in primary dialogue preserves the secondary text alignment.
        let previousTop = label.frame.minY
        primary.update(currentTime: 4)
        secondary.update(currentTime: 4)
        XCTAssertEqual(primary.activeText, "")
        XCTAssertEqual(secondary.activeText, "Secondary")
        XCTAssertEqual(textAlignment(), .left)
        XCTAssertEqual(label.frame.minY, previousTop, accuracy: 0.1)

        // A real track change uses clear(), resetting the old placement, but
        // not the secondary cue. An ordinary dialogue gap above did not.
        primary.clear()
        XCTAssertEqual(textAlignment(), .center)
        XCTAssertGreaterThan(label.frame.minY, previousTop)
        XCTAssertEqual(secondary.activeText, "Secondary")

        // A newly selected primary track can establish a different alignment.
        primary.setEvents([
            SubtitleEvent(startTime: 1, endTime: 8, text: "Top right",
                bitmap: nil, bitmapWidth: 0, bitmapHeight: 0, alignment: 9)
        ])
        primary.update(currentTime: 4)
        XCTAssertEqual(textAlignment(), .right)
    }


    @MainActor
    func testPrimaryGapFollowsOffsetAndControlsLiftWithoutRedrawingPrimary() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        let picture = CGRect(x: 0, y: 50, width: 800, height: 300)
        primary.videoRectProvider = { picture }
        secondary.videoRectProvider = { picture }
        primary.setEvents([cue("Primary"), cue("Primary", start: 6, end: 8)])
        secondary.setEvents([cue("Secondary", end: 10)])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)
        let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        let originalTop = label.frame.minY
        primary.update(currentTime: 4)
        secondary.update(currentTime: 4)

        primary.applyStyle(textColor: nil, backgroundColor: nil, strokeColor: nil,
                           fontSize: nil, fontWeight: nil, verticalOffset: 0.12)
        secondary.applySecondaryStyle(from: primary, fontSize: nil, textColor: nil)
        primary.layoutIfNeeded()
        secondary.layoutIfNeeded()
        XCTAssertEqual(label.frame.minY, originalTop - 36, accuracy: 0.1)

        for (position, lift) in [(70, 100.0), (93, 36.0), (70, 100.0)] {
            primary.setSubtitlePosition(basePosition: position)
            secondary.setSubtitlePosition(basePosition: position)
            primary.layoutIfNeeded()
            secondary.layoutIfNeeded()
            XCTAssertEqual(label.frame.minY, originalTop - CGFloat(lift), accuracy: 0.1)
            XCTAssertEqual(primary.activeText, "")
            XCTAssertTrue(primaryLabel.isHidden)
        }
        let gapFrame = label.frame
        primary.update(currentTime: 7)
        secondary.update(currentTime: 7)
        XCTAssertEqual(label.frame, gapFrame)
    }

    @MainActor
    func testPrimaryGapRemeasuresStyledTextWhenFontChanges() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        var mainCue = cue("First line\nSecond line")
        mainCue.styledRuns = [SubtitleStyledRun(
            text: mainCue.text!, isBold: true, isItalic: true,
            isUnderlined: false, isStruckThrough: false)]
        primary.setEvents([mainCue])
        secondary.setEvents([cue("Secondary", end: 8)])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        let originalBottom = label.frame.maxY
        primary.update(currentTime: 4)
        secondary.update(currentTime: 4)

        primary.applyStyle(textColor: nil, backgroundColor: nil, strokeColor: nil,
                           fontSize: 48, fontWeight: nil, verticalOffset: nil)
        // Hold the secondary font fixed so only the primary reference grows.
        secondary.applySecondaryStyle(from: primary, fontSize: 24, textColor: nil)
        XCTAssertLessThan(label.frame.maxY, originalBottom)
        let gapFrame = label.frame
        XCTAssertEqual(primary.activeText, "")
        primary.update(currentTime: 2)
        XCTAssertEqual(label.frame, gapFrame)
    }

    @MainActor
    func testCenteredPrimaryGapUsesBothHalvesOfChangedSpacing() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        var centered = cue("Primary")
        centered.alignment = 5
        primary.setEvents([centered])
        secondary.setEvents([cue("Secondary", end: 8)])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        let originalBottom = label.frame.maxY
        primary.update(currentTime: 4)
        secondary.update(currentTime: 4)

        secondary.secondaryVerticalAdjustment = 0.04
        primary.layoutIfNeeded()
        secondary.layoutIfNeeded()
        // A 16pt gap increase moves each half of the centered pair by 8pt.
        XCTAssertEqual(label.frame.maxY, originalBottom - 8, accuracy: 0.1)
        let gapFrame = label.frame
        XCTAssertEqual(primary.activeText, "")
        primary.update(currentTime: 2)
        XCTAssertEqual(label.frame, gapFrame)
    }

    @MainActor
    func testSeekResetsPrimaryPlacementWithoutDiscardingQueuedCues() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        primary.setEvents([
            SubtitleEvent(startTime: 1, endTime: 3, text: "Top left",
                bitmap: nil, bitmapWidth: 0, bitmapHeight: 0, alignment: 7),
            cue("Later primary", start: 10, end: 12),
        ])
        secondary.setEvents([cue("Secondary", start: 0, end: 15)])
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        func update(_ time: Double) {
            primary.update(currentTime: time)
            secondary.update(currentTime: time)
        }

        // Seek forward and backward into a primary gap, then back into its cue.
        // Neither track republishes its file during these seeks.
        for target in [6.0, 0.5] {
            update(2)
            let previousTop = label.frame.minY
            primary.resetPlacement()
            update(target)
            let style = label.attributedText?.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(primary.activeText, "")
            XCTAssertEqual(secondary.activeText, "Secondary")
            XCTAssertEqual(style?.alignment, .center)
            XCTAssertGreaterThan(label.frame.minY, primary.bounds.midY)
            XCTAssertGreaterThan(label.frame.minY, previousTop)

            primary.resetPlacement()
            update(2)
            XCTAssertEqual(primary.activeText, "Top left")
            XCTAssertEqual(label.frame.minY, previousTop, accuracy: 0.1)
        }
        update(11)
        XCTAssertEqual(primary.activeText, "Later primary")
        XCTAssertEqual(secondary.activeText, "Secondary")
    }

    @MainActor
    func testSecondaryAvoidsBitmapAndAssBoundsThroughDialogueGaps() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        primary.videoRectProvider = { CGRect(x: 0, y: 50, width: 800, height: 300) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 40)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        }.cgImage!
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        secondary.setEvents([cue("Secondary", start: 1, end: 8)])
        secondary.update(currentTime: 2)

        primary.setEvents([SubtitleEvent(
            startTime: 1, endTime: 3, text: nil, bitmap: image,
            bitmapWidth: 100, bitmapHeight: 40,
            normalizedRect: CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1),
            canvasSize: CGSize(width: 800, height: 300))])
        primary.update(currentTime: 2)
        XCTAssertLessThan(label.frame.maxY, 290)
        XCTAssertEqual(label.frame.midX, 400, accuracy: 0.1)
        let bitmapTop = label.frame.minY
        primary.update(currentTime: 4)
        XCTAssertEqual(label.frame.minY, bitmapTop, accuracy: 0.1)

        // Retained bitmap placement uses its authored canvas after a geometry change.
        primary.videoRectProvider = { CGRect(x: 100, y: 50, width: 600, height: 300) }
        primary.refreshVideoGeometry()
        primary.layoutIfNeeded()
        let resizedBitmapFrame = label.frame
        XCTAssertEqual(label.frame.minY, bitmapTop - 22.5, accuracy: 0.1)
        primary.update(currentTime: 2)
        XCTAssertEqual(label.frame, resizedBitmapFrame)
        primary.videoRectProvider = { CGRect(x: 0, y: 50, width: 800, height: 300) }

        // An ASS image fills the canvas, but only its visible glyphs reserve space.
        primary.clear()
        primary.showAssImage(image, regions: [CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.1)])
        XCTAssertGreaterThan(label.frame.minY, 110)
        XCTAssertEqual(label.frame.midX, 320, accuracy: 0.1)
        let assTop = label.frame.minY
        primary.showAssImage(nil)
        XCTAssertEqual(label.frame.minY, assTop, accuracy: 0.1)
        primary.clear()
        XCTAssertEqual(label.frame.maxY, 400, accuracy: 0.1)

        // A seek within an unchanged ASS cue keeps its image and remembers its
        // placement for the next dialogue gap, even without another image callback.
        primary.showAssImage(image, regions: [CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.1)])
        primary.resetPlacement()
        primary.rememberPrimaryPlacement()
        XCTAssertTrue(primary.subviews.compactMap { $0 as? UIImageView }
            .contains { !$0.isHidden && $0.image != nil })
        XCTAssertEqual(label.frame.minY, assTop, accuracy: 0.1)
        primary.showAssImage(nil)
        XCTAssertEqual(label.frame.minY, assTop, accuracy: 0.1)

        // A seek into a gap clears the image before remembering placement.
        primary.showAssImage(image, regions: [CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.1)])
        primary.resetPlacement()
        primary.showAssImage(nil)
        primary.rememberPrimaryPlacement()
        XCTAssertEqual(label.frame.maxY, 400, accuracy: 0.1)
    }

    @MainActor
    func testSecondaryFitsBetweenAssRegionsAndKeepsPlacementDuringGap() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        secondary.setEvents([cue("Secondary")])
        secondary.update(currentTime: 2)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            .cgImage!
        let regions = AssRenderer.groupedRegions([
            CGRect(x: 0.2, y: 0.875, width: 0.4, height: 0.1),
            CGRect(x: 0.2, y: 0.025, width: 0.1, height: 0.1),
            CGRect(x: 0.3, y: 0.04, width: 0.3, height: 0.06),
        ])
        XCTAssertEqual(regions.count, 2)
        primary.showAssImage(image, regions: regions)
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        XCTAssertGreaterThan(label.frame.minY, 50)
        XCTAssertLessThan(label.frame.maxY, 350)
        XCTAssertEqual(label.frame.midX, 320, accuracy: 0.1)
        XCTAssertNil(label.layer.mask)
        let frame = label.frame

        // Seeking within the unchanged image must retain both free space and anchor.
        primary.resetPlacement()
        primary.rememberPrimaryPlacement()
        primary.showAssImage(nil)
        XCTAssertEqual(label.frame, frame)
        XCTAssertNil(label.layer.mask)

        // Re-map each retained ASS region into the current canvas without restoring
        // the image. Drawing the same regions again must not move the secondary.
        primary.videoRectProvider = { CGRect(x: 100, y: 50, width: 600, height: 300) }
        primary.refreshVideoGeometry()
        primary.layoutIfNeeded()
        let gapFrame = label.frame
        XCTAssertEqual(label.frame.midX, 340, accuracy: 0.1)
        XCTAssertNotEqual(gapFrame, frame)
        XCTAssertNil(label.layer.mask)
        primary.showAssImage(image, regions: regions)
        XCTAssertEqual(label.frame, gapFrame)
    }

    @MainActor
    func testSecondaryWithoutPrimaryKeepsOffsetAndControlsLift() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        let picture = CGRect(x: 0, y: 50, width: 800, height: 300)
        primary.videoRectProvider = { picture }
        secondary.videoRectProvider = { picture }
        primary.applyStyle(textColor: nil, backgroundColor: nil, strokeColor: nil,
                           fontSize: nil, fontWeight: nil, verticalOffset: 0.12)
        secondary.applySecondaryStyle(from: primary, fontSize: nil, textColor: nil)
        secondary.secondaryVerticalAdjustment = 0.06
        secondary.setEvents([cue("Secondary")])
        secondary.update(currentTime: 2)
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        XCTAssertEqual(label.frame.maxY, 364, accuracy: 0.1)
        secondary.setSubtitlePosition(basePosition: 70)
        secondary.layoutIfNeeded()
        XCTAssertEqual(label.frame.maxY, 300, accuracy: 0.1)
        secondary.setSubtitlePosition(basePosition: 93)
        secondary.layoutIfNeeded()
        XCTAssertEqual(label.frame.maxY, 364, accuracy: 0.1)
    }


    @MainActor
    func testApplePrimaryAndSecondaryPreserveInlineEmphasis() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        secondary.applySecondaryStyle(from: primary, fontSize: 18, textColor: 0xFFFFFF00)

        let runs = [
            SubtitleStyledRun(text: "Normal ", isBold: false, isItalic: false,
                              isUnderlined: false, isStruckThrough: false),
            SubtitleStyledRun(text: "bold italic", isBold: true, isItalic: true,
                              isUnderlined: false, isStruckThrough: false),
            SubtitleStyledRun(text: " and ", isBold: false, isItalic: false,
                              isUnderlined: false, isStruckThrough: false),
            SubtitleStyledRun(text: "underlined", isBold: false, isItalic: false,
                              isUnderlined: true, isStruckThrough: false),
        ]
        var event = cue(runs.map(\.text).joined())
        event.styledRuns = runs
        primary.setEvents([event])
        secondary.setEvents([event])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)

        for overlay in [primary, secondary] {
            let label = overlay.subviews.compactMap { $0 as? UILabel }.last!
            let text = label.attributedText!
            let styleRange = (text.string as NSString).range(of: "bold italic")
            let font = text.attribute(.font, at: styleRange.location,
                                      effectiveRange: nil) as! UIFont
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
            let underline = (text.string as NSString).range(of: "underlined")
            XCTAssertEqual(text.attribute(.underlineStyle, at: underline.location,
                                          effectiveRange: nil) as? Int,
                           NSUnderlineStyle.single.rawValue)
            XCTAssertNil(text.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        }

        let secondaryLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!
        XCTAssertEqual(secondaryLabel.attributedText?.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .yellow)

        // The same cue text and timing can still be restyled during playback.
        event.styledRuns = nil
        primary.setEvents([event])
        let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let reset = primaryLabel.attributedText!.attribute(
            .font, at: 7, effectiveRange: nil) as! UIFont
        XCTAssertFalse(reset.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }


    @MainActor
    func testCrowdedSecondaryUsesTheOtherSideInsteadOfOverlapping() {
        let atTop = CGRect(x: 0, y: 15, width: 300, height: 60)
        let top = SubtitleOverlay.stackedSecondaryTop(
            occupied: [atTop], anchor: atTop, x: 0, width: 300,
            height: 40, gap: 8, preferBelow: false, minimumY: 20, maximumY: 375)
        XCTAssertNil(top.clip)
        XCTAssertEqual(top.top, 83, accuracy: 0.1)

        let atBottom = CGRect(x: 0, y: 300, width: 300, height: 70)
        let bottom = SubtitleOverlay.stackedSecondaryTop(
            occupied: [atBottom], anchor: atBottom, x: 0, width: 300,
            height: 50, gap: 8, preferBelow: true, minimumY: 20, maximumY: 375)
        XCTAssertNil(bottom.clip)
        XCTAssertEqual(bottom.top, 242, accuracy: 0.1)

        let large = CGRect(x: 0, y: 80, width: 300, height: 240)
        let crowded = SubtitleOverlay.stackedSecondaryTop(
            occupied: [large], anchor: large, x: 0, width: 300,
            height: 100, gap: 8, preferBelow: false, minimumY: 0, maximumY: 400)
        XCTAssertNotNil(crowded.clip)
        XCTAssertEqual(crowded.clip!.upperBound, 72, accuracy: 0.1)
    }

    @MainActor
    func testIndependentPrimaryCuePositionsAndInlineStyle() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var top = cue("Top")
        top.alignment = 8
        top.position = CGPoint(x: 0.5, y: 0.1)
        var bottom = cue("Italic")
        bottom.alignment = 2
        bottom.position = CGPoint(x: 0.5, y: 0.85)
        bottom.styledRuns = [SubtitleStyledRun(
            text: "Italic", isBold: false, isItalic: true,
            isUnderlined: false, isStruckThrough: false)]
        primary.setEvents([top, bottom])
        primary.update(currentTime: 2)

        let topLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let positioned = primary.subviews.compactMap { $0 as? SubtitleOverlay }
        XCTAssertEqual(positioned.count, 1)
        let bottomLabel = positioned[0].subviews.compactMap { $0 as? UILabel }.last!
        XCTAssertEqual(topLabel.text, "Top")
        XCTAssertEqual(bottomLabel.text, "Italic")
        XCTAssertLessThan(topLabel.frame.maxY, bottomLabel.frame.minY)
        let font = bottomLabel.attributedText!.attribute(
            .font, at: 0, effectiveRange: nil) as! UIFont
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        primary.clear()
        XCTAssertTrue(primary.subviews.compactMap { $0 as? SubtitleOverlay }.isEmpty)
    }

    @MainActor
    func testSimultaneousBitmapRegionsRemainVisibleAndReserveTheirFullBounds() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 20))
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 60, height: 20))
            }.cgImage!
        func bitmap(_ y: CGFloat) -> SubtitleEvent {
            SubtitleEvent(startTime: 1, endTime: 3, text: nil,
                bitmap: image, bitmapWidth: 60, bitmapHeight: 20,
                normalizedRect: CGRect(x: 0.25, y: y, width: 0.5, height: 0.1),
                canvasSize: CGSize(width: 800, height: 400))
        }
        secondary.setEvents([cue("Secondary")])
        secondary.update(currentTime: 2)
        primary.setEvents([bitmap(0.65), bitmap(0.75)])
        primary.update(currentTime: 2)
        let visible = primary.subviews.compactMap { $0 as? UIImageView }
            .filter { !$0.isHidden && $0.image != nil }
        XCTAssertEqual(visible.count, 2)
        let label = secondary.subviews.compactMap { $0 as? UILabel }.last!
        XCTAssertLessThan(label.frame.maxY, visible.map(\.frame.minY).min()!)
        primary.setEvents([bitmap(0.65)])
        XCTAssertEqual(primary.subviews.compactMap { $0 as? UIImageView }
            .filter { !$0.isHidden && $0.image != nil }.count, 1)
    }


    @MainActor
    func testDefaultAndExplicitBottomCenterShareOneTextBlock() {
        let overlay = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var explicit = cue("Second speaker")
        explicit.alignment = 2
        overlay.setEvents([cue("First speaker"), explicit])
        overlay.update(currentTime: 2)
        XCTAssertTrue(overlay.subviews.compactMap { $0 as? SubtitleOverlay }.isEmpty)
        XCTAssertEqual(overlay.subviews.compactMap { $0 as? UILabel }.last?.text,
                       "First speaker\nSecond speaker")
    }

    @MainActor
    func testSecondaryCanUseSpaceBetweenSeparatedPrimaryCues() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        var top = cue("Top cue")
        top.alignment = 8
        top.position = CGPoint(x: 0.5, y: 0.1)
        var bottom = cue("Bottom cue")
        bottom.alignment = 2
        bottom.position = CGPoint(x: 0.5, y: 0.9)
        primary.setEvents([top, bottom])
        primary.update(currentTime: 2)
        secondary.setEvents([cue("Secondary")])
        secondary.update(currentTime: 2)

        let first = primary.subviews.compactMap { $0 as? UILabel }.last!
        let positioned = primary.subviews.compactMap { $0 as? SubtitleOverlay }.first!
        let second = positioned.subviews.compactMap { $0 as? UILabel }.last!
        let caption = secondary.subviews.compactMap { $0 as? UILabel }.last!
        XCTAssertGreaterThan(caption.frame.minY, first.frame.maxY)
        XCTAssertLessThan(caption.frame.maxY, second.frame.minY)
        XCTAssertNil(caption.layer.mask)
    }

    @MainActor
    func testOversizedSecondaryIsMaskedAndRecoversOnPrimaryOff() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        primary.setEvents([cue("Primary")])
        primary.update(currentTime: 2)
        secondary.setEvents([cue(Array(repeating: "Long subtitle line", count: 40)
            .joined(separator: "\n"))])
        secondary.update(currentTime: 2)
        let caption = secondary.subviews.compactMap { $0 as? UILabel }.last!
        let mask = caption.layer.mask as? CAShapeLayer
        XCTAssertNotNil(mask)
        XCTAssertLessThan(mask!.path!.boundingBox.height, caption.frame.height)
        primary.clear()
        XCTAssertNil(caption.layer.mask)
    }


    @MainActor
    func testExtraPositionedCueFollowsPlaybackControlsWithoutReplacingCues() {
        let overlay = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var top = cue("Top")
        top.alignment = 8
        top.position = CGPoint(x: 0.5, y: 0.1)
        var bottom = cue("Bottom")
        bottom.alignment = 2
        bottom.position = CGPoint(x: 0.5, y: 0.85)
        overlay.setEvents([top, bottom])
        overlay.update(currentTime: 2)

        let topLabel = overlay.subviews.compactMap { $0 as? UILabel }.last!
        let extra = overlay.subviews.compactMap { $0 as? SubtitleOverlay }.first!
        let bottomLabel = extra.subviews.compactMap { $0 as? UILabel }.last!
        let beforeTop = topLabel.frame.minY
        let beforeBottom = bottomLabel.frame.maxY

        overlay.setSubtitlePosition(basePosition: 70)
        overlay.layoutIfNeeded()
        XCTAssertEqual(topLabel.frame.minY, beforeTop, accuracy: 0.1)
        XCTAssertEqual(bottomLabel.frame.maxY, beforeBottom - 100, accuracy: 0.1)
        XCTAssertTrue(overlay.subviews.contains(extra))
        XCTAssertEqual(bottomLabel.text, "Bottom")

        overlay.setSubtitlePosition(basePosition: 100)
        overlay.layoutIfNeeded()
        XCTAssertEqual(bottomLabel.frame.maxY, beforeBottom, accuracy: 0.1)
    }

    @MainActor
    func testSafeAreaFallbackUsesOverlayCoordinates() {
        let full = CGRect(x: 0, y: 0, width: 800, height: 400)
        let safe = SubtitleOverlay.resolvedSafeAreaInsets(
            bounds: full, local: .zero,
            inheritedRects: [CGRect(x: 44, y: 20, width: 736, height: 360)])
        XCTAssertEqual(safe.left, 44, accuracy: 0.1)
        XCTAssertEqual(safe.right, 20, accuracy: 0.1)
        XCTAssertEqual(safe.top, 20, accuracy: 0.1)
        XCTAssertEqual(safe.bottom, 20, accuracy: 0.1)

        // With the entire surface already inside the safe region, no second
        // inset should be applied.
        let inset = CGRect(x: 0, y: 0, width: 736, height: 360)
        let alreadyInset = SubtitleOverlay.resolvedSafeAreaInsets(
            bounds: inset, local: .zero, inheritedRects: [inset])
        XCTAssertEqual(alreadyInset.left, 0, accuracy: 0.1)
        XCTAssertEqual(alreadyInset.right, 0, accuracy: 0.1)

        // If Flutter only applied part of the housing inset, retain the rest.
        let partial = SubtitleOverlay.resolvedSafeAreaInsets(
            bounds: inset, local: UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 0),
            inheritedRects: [CGRect(x: 24, y: 0, width: 712, height: 360)])
        XCTAssertEqual(partial.left, 24, accuracy: 0.1)
    }

    @MainActor
    func testSecondarySubtitleRouteWaitsOrFallsBackAfterLoad() {
        XCTAssertEqual(AetherPlayerWrapper.secondarySubtitleRoute(
            embeddedOrdinal: 2, availableEmbeddedTracks: 2, hasSidecar: true),
            .embedded(index: 1))
        XCTAssertEqual(AetherPlayerWrapper.secondarySubtitleRoute(
            embeddedOrdinal: 2, availableEmbeddedTracks: 1, hasSidecar: true),
            .sidecar)
        XCTAssertEqual(AetherPlayerWrapper.secondarySubtitleRoute(
            embeddedOrdinal: 2, availableEmbeddedTracks: 1, hasSidecar: false),
            .pending)
        XCTAssertEqual(AetherPlayerWrapper.secondarySubtitleRoute(
            embeddedOrdinal: nil, availableEmbeddedTracks: 0, hasSidecar: true),
            .sidecar)
        XCTAssertEqual(AetherPlayerWrapper.secondarySubtitleRoute(
            embeddedOrdinal: nil, availableEmbeddedTracks: 0, hasSidecar: false),
            .disabled)
    }

    @MainActor
    func testPositionedCuesFollowPrimaryDelayWhenChangedWhilePaused() {
        let overlay = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        func positioned(_ text: String, start: Double, end: Double, top: Bool) -> SubtitleEvent {
            var event = cue(text, start: start, end: end)
            event.alignment = top ? 8 : 2
            event.position = CGPoint(x: 0.5, y: top ? 0.1 : 0.85)
            return event
        }
        overlay.setEvents([
            positioned("Early top", start: 8, end: 10, top: true),
            positioned("Early bottom", start: 8, end: 10, top: false),
            positioned("Late top", start: 10, end: 14, top: true),
            positioned("Late bottom", start: 10, end: 14, top: false),
        ])
        func visibleText() -> Set<String> {
            let nested = overlay.subviews.compactMap { $0 as? SubtitleOverlay }.first
            return Set([
                overlay.subviews.compactMap { $0 as? UILabel }.last?.text,
                nested?.subviews.compactMap { $0 as? UILabel }.last?.text,
            ].compactMap { $0 })
        }

        overlay.update(currentTime: 12)
        XCTAssertEqual(visibleText(), Set(["Late top", "Late bottom"]))

        // Simulate changing the delay while paused: the playhead remains at 12.
        overlay.delaySeconds = 4
        overlay.update(currentTime: 12)
        XCTAssertEqual(visibleText(), Set(["Early top", "Early bottom"]))

        let nested = overlay.subviews.compactMap { $0 as? SubtitleOverlay }.first!
        overlay.delaySeconds = 3
        overlay.update(currentTime: 12)
        XCTAssertTrue(overlay.subviews.contains(nested))
        XCTAssertEqual(nested.delaySeconds, 3, accuracy: 0.001)
        XCTAssertEqual(visibleText(), Set(["Early top", "Early bottom"]))
    }

    @MainActor
    func testVideoGeometryRefreshRepositionsPrimaryAndSecondary() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true

        let letterboxed = CGRect(x: 0, y: 60, width: 800, height: 280)
        primary.videoRectProvider = { letterboxed }
        secondary.videoRectProvider = { letterboxed }
        var authored = cue("Primary")
        authored.position = CGPoint(x: 0.5, y: 0.85)
        primary.setEvents([authored])
        secondary.setEvents([cue("Secondary", end: 8)])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)

        let mainLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let secondLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!
        let firstY = mainLabel.frame.midY
        let secondY = secondLabel.frame.midY

        let filled = CGRect(x: 0, y: 0, width: 800, height: 400)
        primary.videoRectProvider = { filled }
        secondary.videoRectProvider = { filled }
        primary.refreshVideoGeometry()
        secondary.refreshVideoGeometry()
        primary.layoutIfNeeded()
        secondary.layoutIfNeeded()

        XCTAssertGreaterThan(mainLabel.frame.midY, firstY)
        XCTAssertGreaterThan(secondLabel.frame.midY, secondY)
        XCTAssertEqual(mainLabel.text, "Primary")
        XCTAssertEqual(secondLabel.text, "Secondary")

        primary.update(currentTime: 4)
        secondary.update(currentTime: 4)
        primary.videoRectProvider = { letterboxed }
        secondary.videoRectProvider = { letterboxed }
        primary.refreshVideoGeometry()
        secondary.refreshVideoGeometry()
        primary.layoutIfNeeded()
        secondary.layoutIfNeeded()
        XCTAssertEqual(secondLabel.frame.midY, secondY, accuracy: 0.1)
        XCTAssertTrue(mainLabel.isHidden)
    }
}
