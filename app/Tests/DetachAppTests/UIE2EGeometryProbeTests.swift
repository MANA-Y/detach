import AppKit
import XCTest
@testable import DetachApp

@MainActor
final class UIE2EGeometryProbeTests: XCTestCase {
    func testGeometryOnlyProbeDoesNotBecomeALocator() {
        let view = UIE2EGeometryView(
            identifier: "new-session-button",
            semanticLabel: nil,
            semanticRole: nil,
            semanticEnabled: true)

        XCTAssertFalse(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityIdentifier(), "")
        XCTAssertNil(view.accessibilityLabel())
        XCTAssertNil(view.accessibilityRole())
        XCTAssertNil(view.hitTest(.zero))
    }

    func testSemanticProbeExposesNoActionOrHitTarget() {
        let expectedFrame = CGRect(x: 40, y: 80, width: 120, height: 32)
        UIE2EGeometryRegistry.set(
            expectedFrame,
            for: "settings-show-tips")
        let view = UIE2EGeometryView(
            identifier: "settings-show-tips",
            semanticLabel: "Show tips",
            semanticRole: .checkBox,
            semanticEnabled: true)

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityIdentifier(), "settings-show-tips")
        XCTAssertEqual(view.accessibilityLabel(), "Show tips")
        XCTAssertEqual(view.accessibilityRole(), .checkBox)
        XCTAssertEqual(view.accessibilityFrame(), expectedFrame)
        XCTAssertTrue(view.isAccessibilityEnabled())
        XCTAssertNil(view.hitTest(.zero))
        XCTAssertFalse(view.accessibilityPerformPress())
    }
}
