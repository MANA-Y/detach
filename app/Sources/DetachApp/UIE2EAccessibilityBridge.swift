import AppKit
import DetachKit
import SwiftUI

/// Test-only accessibility locators for SwiftUI's virtual List rows. AppKit's
/// in-process protocol omits identifiers for those rows even though external
/// assistive clients receive them. The bridge exposes only semantics and
/// geometry. It does not invoke application actions. The packaged-app driver
/// uses each locator with a measured real-control frame and dispatches AppKit
/// mouse events through the normal SwiftUI control path.
@MainActor
struct UIE2EAccessibilityBridge: NSViewRepresentable {
    let store: SessionStore
    let selectedID: String?

    func makeNSView(context: Context) -> UIE2EBridgeView {
        UIE2EBridgeView()
    }

    func updateNSView(_ view: UIE2EBridgeView, context: Context) {
        guard AppSettings.uiE2E != nil else {
            view.elements = []
            return
        }
        let sessions = store.sessions
        let selected = sessions.first { $0.id == selectedID }
        view.rebuild(
            sessions: sessions,
            state: store.state,
            selected: selected)
    }
}

@MainActor
final class UIE2EBridgeView: NSView {
    var elements: [Any] = [] {
        didSet { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { elements }

    func rebuild(
        sessions: [Session],
        state: SessionStore.State,
        selected: Session?
    ) {
        guard let window else { return }
        let frame = window.frame
        let sidebarWidth = min(288, frame.width * 0.4)
        let rowWidth = max(1, sidebarWidth - 24)
        var next: [Any] = []

        next.append(UIE2EAXElement(
            parent: self,
            role: .button,
            identifier: "new-session-button",
            label: "New session",
            frame: NSRect(x: frame.minX + sidebarWidth - 80,
                          y: frame.maxY - 52, width: 44, height: 36)))

        for (index, session) in sessions.enumerated() {
            next.append(UIE2EAXElement(
                parent: self,
                role: .button,
                identifier: "session-row-\(session.id)",
                label: session.displayTitle,
                frame: NSRect(x: frame.minX + 12,
                              y: frame.maxY - 100 - CGFloat(index * 64),
                              width: rowWidth, height: 46)))
        }

        if let selected {
            next.append(UIE2EAXElement(
                parent: self,
                role: .group,
                identifier: "session-detail-\(selected.id)",
                label: selected.displayTitle,
                frame: NSRect(x: frame.minX + sidebarWidth,
                              y: frame.minY,
                              width: frame.width - sidebarWidth,
                              height: frame.height)))
            if let action = selected.healthActions?.contains(.stop) == true
                ? SessionAction.stop
                : (selected.healthActions?.contains(.delete) == true ? .delete : nil) {
                next.append(UIE2EAXElement(
                    parent: self,
                    role: .button,
                    identifier: "session-action-\(action.rawValue)",
                    label: action == .stop ? "Stop" : "Delete",
                    frame: NSRect(x: frame.maxX - 100,
                                  y: frame.minY + 16, width: 80, height: 32)))
            }
        }

        if sessions.isEmpty, state == .ok {
            next.append(UIE2EAXElement(
                parent: self,
                role: .group,
                identifier: "empty-sessions-guide",
                label: "No sessions yet",
                frame: NSRect(x: frame.minX + sidebarWidth,
                              y: frame.minY,
                              width: frame.width - sidebarWidth,
                              height: frame.height)))
        }

        elements = next
    }
}

@MainActor
final class UIE2EAXElement: NSAccessibilityElement {
    private let storedRole: NSAccessibility.Role
    private let storedIdentifier: String
    private let storedLabel: String
    private let storedFrame: NSRect
    private let storedEnabled: Bool

    init(
        parent: Any,
        role: NSAccessibility.Role,
        identifier: String,
        label: String,
        frame: NSRect,
        enabled: Bool = true
    ) {
        storedRole = role
        storedIdentifier = identifier
        storedLabel = label
        storedFrame = frame
        storedEnabled = enabled
        super.init()
        setAccessibilityParent(parent)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { storedRole }
    override func accessibilityIdentifier() -> String? { storedIdentifier }
    override func accessibilityLabel() -> String? { storedLabel }
    override func accessibilityFrame() -> NSRect { storedFrame }
    override func isAccessibilityEnabled() -> Bool { storedEnabled }
}
