import AppKit
import SwiftUI

/// Captures the screen frame of a real SwiftUI control for the hermetic UI
/// driver. The probe receives no actions and is dormant outside UI e2e.
@MainActor
enum UIE2EGeometryRegistry {
    private static var frames: [String: CGRect] = [:]

    static func set(_ frame: CGRect, for identifier: String) {
        frames[identifier] = frame
    }

    static func frame(for identifier: String) -> CGRect? {
        frames[identifier]
    }
}

@MainActor
struct UIE2EGeometryProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> UIE2EGeometryView {
        UIE2EGeometryView(identifier: identifier)
    }

    func updateNSView(_ view: UIE2EGeometryView, context: Context) {
        view.identifierValue = identifier
        view.publishFrame()
    }
}

@MainActor
final class UIE2EGeometryView: NSView {
    var identifierValue: String

    init(identifier: String) {
        identifierValue = identifier
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        publishFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishFrame()
    }

    func publishFrame() {
        guard AppSettings.uiE2E != nil, let window, !bounds.isEmpty else { return }
        let windowFrame = convert(bounds, to: nil)
        let screenFrame: CGRect
        if window.sheetParent != nil {
            screenFrame = CGRect(
                x: window.frame.minX + windowFrame.minX,
                y: window.frame.minY + windowFrame.minY,
                width: windowFrame.width,
                height: windowFrame.height)
        } else {
            screenFrame = window.convertToScreen(windowFrame)
        }
        UIE2EGeometryRegistry.set(
            screenFrame, for: identifierValue)
    }
}
