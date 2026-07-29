import XCTest
@testable import DetachApp

@MainActor
final class NewSessionSheetTests: XCTestCase {
    func testBuildsFormWithOptionalEmptyName() {
        _ = NewSessionSheet(detachPath: "/tmp/detach").body
    }

    func testBuildsInlineValidationForRejectedCLIName() {
        _ = NewSessionSheet(
            detachPath: "/tmp/detach",
            initialName: "Rev (ai)").body
    }
}
