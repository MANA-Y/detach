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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = NSHostingView(rootView: NewSessionSheet(
            detachPath: "/tmp/detach",
            showsAdvanced: true))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        pumpMain()
        XCTAssertNotNil(window.contentView)
    }

    func testPickerRefreshLoadsInstalledAndMissingSelections() {
        let installed = hostPicker(bundleIdentifier: "com.apple.Terminal")
        defer { installed.close() }
        XCTAssertNotNil(installed.contentView)

        let missing = hostPicker(bundleIdentifier: "dev.example.missing-terminal")
        defer { missing.close() }
        XCTAssertNotNil(missing.contentView)
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
        let panel = TerminalApplicationChooser.makeOpenPanel()
        XCTAssertEqual(panel.allowedContentTypes, [.applicationBundle])
        XCTAssertEqual(panel.directoryURL?.path, "/Applications")
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
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
        let panel = ProjectDirectoryChooser.makeOpenPanel(
            startingAt: URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertEqual(panel.directoryURL?.path, "/tmp")
    }

    func testPanelHostPrefersTheKeyWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        XCTAssertEqual(PanelHostWindow.current(), window)
    }

    func testPinWindowTopEdgeReappliesTheStoredTop() {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 160, width: 360, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = NSHostingView(rootView: PinWindowTopEdge()
            .frame(width: 1, height: 1))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        pumpMain()
        let pinnedTop = window.frame.maxY
        var grown = window.frame
        grown.size.height += 90
        grown.origin.y -= 90
        window.setFrame(grown, display: true)
        pumpMain()
        XCTAssertEqual(window.frame.maxY, pinnedTop, accuracy: 1.5)
    }

    private func hostPicker(bundleIdentifier: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = NSHostingView(
            rootView: TerminalPickerHost(bundleIdentifier: bundleIdentifier)
                .frame(width: 400, height: 120))
        window.makeKeyAndOrderFront(nil)
        pumpMain()
        return window
    }

    private func pumpMain() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
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

private struct TerminalPickerHost: View {
    @State var bundleIdentifier: String

    var body: some View {
        TerminalPreferencePicker(bundleIdentifier: $bundleIdentifier)
    }
}
