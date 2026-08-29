import SwiftUI
import XCTest
import DetachKit
@testable import DetachApp

private struct SidebarNoopCLI: DetachCLIRunning {
    func run(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CLIResult {
        CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}

@MainActor
final class SidebarViewTests: XCTestCase {
    func testBuildsWithFreshFinishedSelectionState() {
        let view = SidebarView(
            store: SessionStore(cli: SidebarNoopCLI()),
            selectedID: .constant(nil),
            navigation: MainNavigation())

        _ = view.body
    }

    func testFormatsEveryFinishedDeletionFailure() {
        let failures = [
            SessionDeletionFailure(
                sessionName: "first",
                displayTitle: "First task",
                message: "still busy"),
            SessionDeletionFailure(
                sessionName: "second",
                displayTitle: "Second task",
                message: "permission denied"),
        ]

        XCTAssertEqual(
            FinishedDeletionPresentation.errorMessage(for: failures),
            "First task: still busy\nSecond task: permission denied")
    }
}
