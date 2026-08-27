import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import DetachApp

@MainActor
final class NewSessionSheetTests: XCTestCase {
    func testBuildsFormWithOptionalEmptyName() {
        _ = NewSessionSheet(detachPath: "/tmp/detach").body
    }

    func testBuildsFormWithHumanReadableName() {
        _ = NewSessionSheet(
            detachPath: "/tmp/detach",
            initialName: "Rev (ai)").body
    }

    func testBuildsInlineValidationForOversizedName() {
        _ = NewSessionSheet(
            detachPath: "/tmp/detach",
            initialName: String(repeating: "a", count: 101)).body
    }

    func testBuildsExpandedAdvancedSection() {
        _ = NewSessionSheet(
            detachPath: "/tmp/detach",
            showsAdvanced: true).body
    }

    func testPickerRefreshLoadsInstalledAndMissingSelections() {
        var installed = "com.apple.Terminal"
        _ = TerminalPreferencePicker(bundleIdentifier: Binding(
            get: { installed },
            set: { installed = $0 })).body

        var missing = "dev.example.missing-terminal"
        _ = TerminalPreferencePicker(
            bundleIdentifier: Binding(
                get: { missing },
                set: { missing = $0 }),
            accessibilityIdentifier: "new-session-terminal").body
    }

    func testPickerChooseAcceptsATerminalURL() throws {
        let terminal = try XCTUnwrap(Self.terminalApplicationURL())
        let box = IdentifierBox()
        var picker = TerminalPreferencePicker(bundleIdentifier: Binding(
            get: { box.value },
            set: { box.value = $0 }))
        picker.choose(at: terminal)
        XCTAssertEqual(box.value, "com.apple.Terminal")
        picker.choose(at: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(box.value, "com.apple.Terminal")
    }

    func testPreferenceSelectionAcceptsTerminalAndRejectsABareFolder() throws {
        let terminal = try XCTUnwrap(Self.terminalApplicationURL())
        XCTAssertEqual(
            TerminalPreferenceSelection.outcome(for: terminal).bundleIdentifier,
            "com.apple.Terminal")

        let rejected = TerminalPreferenceSelection.outcome(
            for: URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(rejected.bundleIdentifier)
        XCTAssertTrue(rejected.error?.contains("tmp") == true)
    }

    func testLaunchTitleAndDisplayNameUseTheSelectedTerminal() {
        XCTAssertEqual(
            TerminalLaunchPresentation.title(terminalDisplayName: "iTerm"),
            "Launch in iTerm")
        XCTAssertEqual(
            TerminalLaunchPresentation.displayName(for: "com.apple.Terminal"),
            "Terminal")
        XCTAssertEqual(
            TerminalLaunchPresentation.displayName(for: "dev.example.missing-terminal"),
            "Terminal")
    }

    func testOtherAppChooserOpensApplicationBundles() {
        let rules = TerminalApplicationChooser.applicationBundleRules
        XCTAssertEqual(rules.allowedContentTypes, [.applicationBundle])
        XCTAssertEqual(rules.directoryURL?.path, "/Applications")
        XCTAssertTrue(rules.canChooseFiles)
        XCTAssertFalse(rules.canChooseDirectories)
        XCTAssertFalse(rules.allowsMultipleSelection)
        XCTAssertFalse(rules.canCreateDirectories)
    }

    func testProjectChooserStartsInTheSelectedProjectParent() {
        let project = URL(fileURLWithPath: "/Users/me/Projects/detach", isDirectory: true)
        XCTAssertEqual(
            ProjectDirectoryChooser.startingDirectory(selectedProject: project).path,
            "/Users/me/Projects")
        XCTAssertEqual(
            ProjectDirectoryChooser.startingDirectory(selectedProject: nil),
            FileManager.default.homeDirectoryForCurrentUser)
    }

    func testWindowTopPinKeepsTheTopEdgeFixedWhenHeightGrows() {
        let original = CGRect(x: 100, y: 200, width: 520, height: 300)
        let grown = CGRect(x: 100, y: 150, width: 520, height: 400)
        let pinned = WindowTopPin.frameKeepingTop(of: grown, pinnedMaxY: original.maxY)
        XCTAssertEqual(pinned.maxY, original.maxY, accuracy: 0.01)
        XCTAssertEqual(pinned.height, 400, accuracy: 0.01)
    }

    func testOpenPanelDirectoryMemoryRestoresThePreviousRoot() {
        let defaults = UserDefaults(suiteName: "DetachOpenPanelMemoryTests")!
        defaults.removePersistentDomain(forName: "DetachOpenPanelMemoryTests")
        let key = OpenPanelDirectoryMemory.keys[1]
        defaults.set("file:///Users/me/Projects/", forKey: key)
        let snapshot = OpenPanelDirectoryMemory.snapshot(defaults: defaults)
        defaults.set("file:///Applications/", forKey: key)
        OpenPanelDirectoryMemory.restore(snapshot, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: key), "file:///Users/me/Projects/")
        OpenPanelDirectoryMemory.restore([:], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testProjectChooserPanelPicksDirectories() {
        let rules = ProjectDirectoryChooser.directoryRules(
            startingAt: URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertTrue(rules.canChooseDirectories)
        XCTAssertFalse(rules.canChooseFiles)
        XCTAssertFalse(rules.canCreateDirectories)
        XCTAssertEqual(rules.directoryURL?.path, "/tmp")
    }

    func testPanelHostPrefersTheKeyWindowThenFallsBack() {
        let key = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        defer { key.close() }
        XCTAssertTrue(PanelHostWindow.preferred(keyWindow: key, windows: []) === key)
        XCTAssertNil(PanelHostWindow.preferred(keyWindow: nil, windows: []))
        _ = PanelHostWindow.current()
    }

    func testPinWindowTopEdgeReappliesTheStoredTop() {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 160, width: 360, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        let pin = PinWindowTopEdgeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView = pin
        defer { window.close() }
        XCTAssertNil(pin.hitTest(NSPoint(x: 0, y: 0)))
        pin.viewDidMoveToWindow()
        let pinnedTop = WindowTopPin.storedMaxY(for: window)
        var grown = window.frame
        grown.size.height += 90
        grown.origin.y -= 90
        window.setFrame(grown, display: false)
        pin.keepTopPinned()
        XCTAssertEqual(window.frame.maxY, pinnedTop, accuracy: 1.5)
        pin.schedulePin()
        pin.layout()
    }

    private static func terminalApplicationURL() -> URL? {
        [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app",
        ]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private final class IdentifierBox {
    var value = "dev.example.missing-terminal"
}
