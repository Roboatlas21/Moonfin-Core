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
    func testAuthoredSrtAlignmentAndNormalizedPosition() {
        let overlay = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        func placed(_ alignment: Int, position: CGPoint? = nil) -> CGRect {
            overlay.setEvents([
                SubtitleEvent(
                    startTime: 1, endTime: 3, text: "Caption",
                    bitmap: nil, bitmapWidth: 0, bitmapHeight: 0,
                    alignment: alignment, position: position)
            ])
            overlay.update(currentTime: 2)
            return overlay.subviews.compactMap { $0 as? UILabel }.last!.frame
        }
        let topLeft = placed(7)
        XCTAssertEqual(topLeft.minY, 20, accuracy: 0.1)
        XCTAssertEqual(topLeft.minX, 40, accuracy: 0.1)
        let topRight = placed(9)
        XCTAssertEqual(topRight.minY, 20, accuracy: 0.1)
        XCTAssertEqual(topRight.maxX, 760, accuracy: 0.1)
        let middle = placed(5)
        XCTAssertEqual(middle.midY, 200, accuracy: 0.1)
        let bottom = placed(2)
        XCTAssertEqual(bottom.maxY, 400, accuracy: 0.1)
        let anchored = placed(5, position: CGPoint(x: 0.3, y: 0.4))
        XCTAssertEqual(anchored.midX, 240, accuracy: 0.1)
        XCTAssertEqual(anchored.midY, 160, accuracy: 0.1)

        // Primary offsets move text inward from either edge, not away from it.
        overlay.applyStyle(
            textColor: nil, backgroundColor: nil, strokeColor: nil,
            fontSize: nil, fontWeight: nil, verticalOffset: 0.02)
        XCTAssertGreaterThan(placed(7).minY, topLeft.minY)
        XCTAssertLessThan(placed(2).maxY, bottom.maxY)
        XCTAssertEqual(placed(5).midY, 200, accuracy: 0.1)
        XCTAssertEqual(placed(5, position: CGPoint(x: 0.3, y: 0.4)).midY,
                       160, accuracy: 0.1)
    }

    @MainActor
    func testSecondaryDelayAndClearLeavePrimaryUntouched() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.setEvents([cue("Primary")])
        secondary.setEvents([cue("Second language")])
        secondary.delaySeconds = 1
        primary.update(currentTime: 1.5)
        secondary.update(currentTime: 1.5)
        XCTAssertEqual(primary.activeText, "Primary")
        XCTAssertEqual(secondary.activeText, "")

        secondary.update(currentTime: 2.5)
        XCTAssertEqual(secondary.activeText, "Second language")
        secondary.update(currentTime: 4)
        XCTAssertEqual(secondary.activeText, "")
        // A backwards seek must recover retained cues.
        secondary.update(currentTime: 2.5)
        XCTAssertEqual(secondary.activeText, "Second language")
        secondary.clear()
        XCTAssertEqual(secondary.activeText, "")
        XCTAssertEqual(primary.activeText, "Primary")
    }

    @MainActor
    func testSecondaryFollowsBottomTopAndCentredPrimary() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.secondaryForStacking = secondary
        secondary.primaryForStacking = primary
        secondary.stackingEnabled = true
        let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let secondaryLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!

        func show(_ alignment: Int) {
            primary.setEvents([
                SubtitleEvent(startTime: 1, endTime: 3, text: "First",
                    bitmap: nil, bitmapWidth: 0, bitmapHeight: 0, alignment: alignment)
            ])
            secondary.setEvents([cue("Second language")])
            primary.update(currentTime: 2)
            secondary.update(currentTime: 2)
        }
        show(2)
        XCTAssertLessThan(secondaryLabel.frame.maxY, primaryLabel.frame.minY)
        XCTAssertEqual(primaryLabel.frame.maxY, 400, accuracy: 0.1)

        show(7)
        XCTAssertGreaterThan(secondaryLabel.frame.minY, primaryLabel.frame.maxY)
        let topSecondary = secondaryLabel.frame.minY
        secondary.secondaryVerticalAdjustment = 0.02
        secondary.layoutIfNeeded()
        XCTAssertGreaterThan(secondaryLabel.frame.minY, topSecondary)
        secondary.secondaryVerticalAdjustment = 0
        secondary.layoutIfNeeded()
        XCTAssertEqual(primaryLabel.frame.minX, secondaryLabel.frame.minX, accuracy: 0.1)
        let leftStyle = secondaryLabel.attributedText?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(leftStyle?.alignment, .left)

        show(2)
        let bottomSecondary = secondaryLabel.frame.minY
        secondary.secondaryVerticalAdjustment = 0.02
        secondary.layoutIfNeeded()
        XCTAssertLessThan(secondaryLabel.frame.minY, bottomSecondary)
        secondary.secondaryVerticalAdjustment = 0
        secondary.layoutIfNeeded()

        show(5)
        XCTAssertLessThan(secondaryLabel.frame.maxY, primaryLabel.frame.minY)
        XCTAssertGreaterThan(primaryLabel.frame.midY, 200)
        XCTAssertLessThan(secondaryLabel.frame.midY, 200)
        func anchorCentre() -> CGFloat {
            (secondaryLabel.frame.maxY + primaryLabel.frame.minY) / 2
        }
        XCTAssertEqual(anchorCentre(), 200, accuracy: 0.1)
        let initialPrimary = primaryLabel.frame.midY
        let initialSecondary = secondaryLabel.frame.midY
        secondary.secondaryVerticalAdjustment = 0.02
        secondary.layoutIfNeeded()
        XCTAssertEqual(primaryLabel.frame.midY, initialPrimary + 4, accuracy: 0.1)
        XCTAssertEqual(secondaryLabel.frame.midY, initialSecondary - 4, accuracy: 0.1)
        XCTAssertEqual(anchorCentre(), 200, accuracy: 0.1)

        // Negative adjustments cannot create overlap or shift the pair.
        secondary.secondaryVerticalAdjustment = -0.06
        secondary.layoutIfNeeded()
        XCTAssertGreaterThan(primaryLabel.frame.minY, secondaryLabel.frame.maxY)
        XCTAssertEqual(anchorCentre(), 200, accuracy: 0.1)

        // Multi-line text with a different size still shares the same centre.
        secondary.applySecondaryStyle(from: primary, fontSize: 36, textColor: nil)
        secondary.layoutIfNeeded()
        XCTAssertEqual(anchorCentre(), 200, accuracy: 0.1)
        secondary.stackingEnabled = false
        secondary.clear()
        primary.layoutIfNeeded()
        XCTAssertEqual(primaryLabel.frame.midY, 200, accuracy: 0.1)
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

            // Secondary text grows away from the primary without changing
            // the primary position or the secondary's adjacent edge.
            secondary.setEvents([cue("One\nTwo\nThree")])
            secondary.update(currentTime: 2)
            XCTAssertEqual(primaryLabel.frame, oneLinePrimary)
            if alignment == 2 {
                XCTAssertEqual(secondaryLabel.frame.maxY, startingBottom, accuracy: 0.1)
            } else {
                XCTAssertEqual(secondaryLabel.frame.minY, startingTop, accuracy: 0.1)
            }

            // The primary's measured size is the only reason to shift the
            // adjacent secondary anchor.
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

        // A normal gap keeps the last primary alignment and its placement.
        primary.update(currentTime: 4)
        secondary.update(currentTime: 4)
        XCTAssertEqual(primary.activeText, "")
        XCTAssertEqual(secondary.activeText, "Secondary")
        XCTAssertEqual(textAlignment(), .left)

        // Turning the primary track Off resets the secondary paragraph style.
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
    func testSecondaryStyleDoesNotChangePrimary() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        primary.setEvents([cue("Primary")])
        secondary.setEvents([cue("Second language")])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)
        let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let secondaryLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!
        let original = primaryLabel.attributedText!
        secondary.applyStyle(
            textColor: 0xFFFFFF00, backgroundColor: nil, strokeColor: nil,
            fontSize: 36, fontWeight: nil, verticalOffset: nil)
        XCTAssertEqual(primaryLabel.attributedText, original)
        XCTAssertEqual(
            secondaryLabel.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                as? UIColor, .yellow)
        let font = secondaryLabel.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let originalFont = original.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(font!.pointSize, originalFont!.pointSize)
    }

    @MainActor
    func testDefaultClearsSecondaryOverridesAndFollowsLaterPrimaryChanges() {
        let player = AetherPlayerWrapper()
        defer { player.shutdown() }
        let primary = player.subtitleOverlay
        let secondary = player.secondarySubtitleOverlay
        primary.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        secondary.frame = primary.bounds
        primary.setEvents([cue("Primary")])
        secondary.setEvents([cue("Second language")])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)
        let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let secondaryLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!
        func color(_ label: UILabel) -> UIColor? {
            label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        }
        func font(_ label: UILabel) -> UIFont? {
            label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        }
        player.applySubtitleStyle(
            textColor: 0xFFFFFFFF, backgroundColor: nil, strokeColor: nil,
            fontSize: 24, fontWeight: nil, verticalOffset: nil)
        player.configureSecondarySubtitleStyle(fontSize: 36, verticalOffset: -0.04, textColor: 0xFFFFFF00)
        // Compare RGB white with RGB white; UIColor.white uses grayscale.
        XCTAssertEqual(color(primaryLabel), UIColor(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(color(secondaryLabel), .yellow)
        XCTAssertGreaterThan(font(secondaryLabel)!.pointSize, font(primaryLabel)!.pointSize)

        // An explicit secondary choice survives changes to the primary style.
        player.applySubtitleStyle(
            textColor: 0xFF00FF00, backgroundColor: nil, strokeColor: nil,
            fontSize: 28, fontWeight: nil, verticalOffset: nil)
        XCTAssertEqual(color(secondaryLabel), .yellow)
        player.configureSecondarySubtitleStyle(fontSize: nil, verticalOffset: nil, textColor: nil)
        XCTAssertEqual(color(secondaryLabel), .green)
        XCTAssertEqual(font(secondaryLabel), font(primaryLabel))
        XCTAssertEqual(secondary.secondaryVerticalAdjustment, -0.04, accuracy: 0.0001)

        // Default remains inherited when the primary appearance changes again.
        player.applySubtitleStyle(
            textColor: 0xFF0000FF, backgroundColor: nil, strokeColor: nil,
            fontSize: 20, fontWeight: nil, verticalOffset: nil)
        XCTAssertEqual(color(secondaryLabel), .blue)
        XCTAssertEqual(font(secondaryLabel), font(primaryLabel))
    }

    @MainActor
    func testSecondaryDelayAddsToPrimaryAndPositionDoesNotMovePrimary() {
        let player = AetherPlayerWrapper()
        defer { player.shutdown() }
        player.setSubtitleDelay(0.5)
        player.setSecondarySubtitleDelay(0.2)
        XCTAssertEqual(player.secondarySubtitleOverlay.delaySeconds, 0.7, accuracy: 0.0001)
        player.setSubtitleDelay(-0.1)
        XCTAssertEqual(player.secondarySubtitleOverlay.delaySeconds, 0.1, accuracy: 0.0001)
        player.setSecondarySubtitleDelay(0)
        XCTAssertEqual(player.secondarySubtitleOverlay.delaySeconds, -0.1, accuracy: 0.0001)
        let primaryPosition = player.baseSubtitlePos
        player.configureSecondarySubtitleStyle(fontSize: nil, verticalOffset: 0.02, textColor: nil)
        XCTAssertEqual(player.secondarySubtitleOverlay.secondaryVerticalAdjustment, 0.02, accuracy: 0.0001)
        XCTAssertEqual(player.baseSubtitlePos, primaryPosition)
    }

}
