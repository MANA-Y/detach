import AppKit
import XCTest
@testable import DetachApp

@MainActor
final class UIE2EEventWindowResolverTests: XCTestCase {
    func testViewResolvesItsOwningWindowWhenWindowsOverlap() {
        let behind = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let owner = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let view = NSView(frame: NSRect(x: 20, y: 20, width: 40, height: 20))
        owner.contentView?.addSubview(view)
        let point = NSPoint(x: 200, y: 200)

        XCTAssertTrue(behind.frame.intersects(owner.frame))
        XCTAssertIdentical(UIE2EEventWindowResolver.owner(of: view), owner)
        XCTAssertIdentical(
            UIE2EEventWindowResolver.resolve(
                owningWindow: UIE2EEventWindowResolver.owner(of: view),
                at: point,
                candidates: [behind, owner]),
            owner)
    }

    func testDetachedViewHasNoOwningWindow() {
        let view = NSView(frame: .zero)
        let candidate = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let point = NSPoint(x: 200, y: 200)

        XCTAssertNil(UIE2EEventWindowResolver.owner(of: view))
        XCTAssertIdentical(
            UIE2EEventWindowResolver.resolve(
                owningWindow: nil,
                at: point,
                candidates: [candidate]),
            candidate)
    }
}
