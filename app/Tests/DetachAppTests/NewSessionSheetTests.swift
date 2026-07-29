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
}
