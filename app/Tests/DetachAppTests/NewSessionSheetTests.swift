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
        let picker = TerminalPreferencePicker(bundleIdentifier: Binding(
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

    func testLaunchPlanOmitsABlankPromptAndKeepsText() {
        XCTAssertNil(NewSessionLaunch.trimmedPrompt("  \n"))
        XCTAssertEqual(NewSessionLaunch.trimmedPrompt("  go\n"), "go")
        let command = NewSessionLaunch.command(
            detachPath: "/tmp/detach",
            provider: .codex,
            projectDir: "/tmp/proj",
            name: "Rev",
            prompt: "  review this  ")
        XCTAssertTrue(command.contains("cd '/tmp/proj'"), command)
        XCTAssertTrue(command.contains("--name 'Rev'"), command)
        XCTAssertTrue(command.contains("-- 'review this'"), command)
        let blank = NewSessionLaunch.command(
            detachPath: "/tmp/detach",
            provider: .claude,
            projectDir: "/tmp/p",
            name: nil,
            prompt: "   ")
        XCTAssertFalse(blank.contains(" -- "), blank)
    }

    func testLaunchLabelCoversBothIdleAndBusyStates() {
        _ = NewSessionLaunch.label(isLaunching: false, terminalDisplayName: "iTerm")
        _ = NewSessionLaunch.label(isLaunching: true, terminalDisplayName: "Terminal")
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

    func testOpenPanelPresentationKeepsOnlyAnOKSelection() {
        let url = URL(fileURLWithPath: "/Applications/Terminal.app")
        XCTAssertEqual(
            OpenPanelPresentation.selectedURL(response: .OK, url: url),
            url)
        XCTAssertNil(OpenPanelPresentation.selectedURL(response: .cancel, url: url))
    }

    func testWindowTopPinStoresAMaxYOnAPlainObject() {
        let storage = NSObject()
        XCTAssertNil(WindowTopPin.associatedMaxY(on: storage))
        WindowTopPin.store(240, on: storage)
        XCTAssertEqual(WindowTopPin.associatedMaxY(on: storage), 240, accuracy: 0.01)
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

    func testPanelHostFallsBackWhenNoWindowIsKey() {
        XCTAssertNil(PanelHostWindow.preferred(keyWindow: nil, windows: []))
    }

    func testPinViewIgnoresHitsWhenDetached() {
        let pin = PinWindowTopEdgeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(pin.hitTest(NSPoint(x: 0, y: 0)))
        pin.viewDidMoveToWindow()
        pin.keepTopPinned()
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
