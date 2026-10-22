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
    func testSecondaryPositionUsesTopMarginAndFollowsResize() {
        let primary = SubtitleOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let secondary = SubtitleOverlay(frame: primary.bounds)
        secondary.topOffset = 0.1
        primary.setEvents([cue("Primary")])
        secondary.setEvents([cue("Second language")])
        primary.update(currentTime: 2)
        secondary.update(currentTime: 2)
        let primaryLabel = primary.subviews.compactMap { $0 as? UILabel }.last!
        let secondaryLabel = secondary.subviews.compactMap { $0 as? UILabel }.last!
        XCTAssertEqual(primaryLabel.frame.maxY, 400, accuracy: 0.1)
        XCTAssertEqual(secondaryLabel.frame.minY, 40, accuracy: 0.1)
        XCTAssertLessThan(secondaryLabel.frame.maxY, primaryLabel.frame.minY)

        secondary.frame.size.height = 600
        secondary.setNeedsLayout()
        secondary.layoutIfNeeded()
        XCTAssertEqual(secondaryLabel.frame.minY, 60, accuracy: 0.1)
        secondary.topOffset = 1
        secondary.layoutIfNeeded()
        XCTAssertEqual(secondaryLabel.frame.maxY, secondary.bounds.height, accuracy: 0.1)
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
        XCTAssertEqual(secondary.topOffset!, 0.12, accuracy: 0.0001)

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
        XCTAssertEqual(player.secondarySubtitleOverlay.topOffset!, 0.06, accuracy: 0.0001)
        XCTAssertEqual(player.baseSubtitlePos, primaryPosition)
    }

}
