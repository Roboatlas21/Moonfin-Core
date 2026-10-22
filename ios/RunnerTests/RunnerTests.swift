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
        XCTAssertEqual(secondaryLabel.frame.minY, 240, accuracy: 0.1)
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
        player.configureSecondarySubtitleStyle(fontSize: 36, verticalOffset: 0.12, textColor: 0xFFFFFF00)
        XCTAssertEqual(color(primaryLabel), .white)
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
        XCTAssertEqual(secondary.topOffset, 0.12)

        // Default remains inherited when the primary appearance changes again.
        player.applySubtitleStyle(
            textColor: 0xFF0000FF, backgroundColor: nil, strokeColor: nil,
            fontSize: 20, fontWeight: nil, verticalOffset: nil)
        XCTAssertEqual(color(secondaryLabel), .blue)
        XCTAssertEqual(font(secondaryLabel), font(primaryLabel))
    }

}
