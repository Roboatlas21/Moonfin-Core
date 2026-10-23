import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
    private func cue(_ text: String, start: Double = 1, end: Double = 3) -> SubtitleEvent {
        SubtitleEvent(
            startTime: start, endTime: end, text: text,
            bitmap: nil, bitmapWidth: 0, bitmapHeight: 0)
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
        overlay.setSubtitlePosition(basePosition: 98)
        XCTAssertEqual(placed(2).maxY, bottom - 12, accuracy: 0.1)
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
        primary.update(currentTime: 4)
        secondary.update(currentTime: 4)
        XCTAssertEqual(primary.activeText, "")
        XCTAssertEqual(secondary.activeText, "Secondary")
        XCTAssertEqual(textAlignment(), .left)

        // Turning the primary track off resets secondary text alignment to centre.
        primary.clear()
        XCTAssertEqual(textAlignment(), .center)

        // A newly selected primary track can establish a different alignment.
        primary.setEvents([
            SubtitleEvent(startTime: 1, endTime: 8, text: "Top right",
                bitmap: nil, bitmapWidth: 0, bitmapHeight: 0, alignment: 9)
        ])
        primary.update(currentTime: 4)
        XCTAssertEqual(textAlignment(), .right)
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

        // An ASS image fills the canvas, but only its visible glyphs reserve space.
        primary.clear()
        primary.showAssImage(image, bounds: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.1))
        XCTAssertGreaterThan(label.frame.minY, 110)
        XCTAssertEqual(label.frame.midX, 320, accuracy: 0.1)
        let assTop = label.frame.minY
        primary.showAssImage(nil)
        XCTAssertEqual(label.frame.minY, assTop, accuracy: 0.1)
        primary.clear()
        XCTAssertEqual(label.frame.maxY, 400, accuracy: 0.1)
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

}
