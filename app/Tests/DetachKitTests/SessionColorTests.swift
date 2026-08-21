import Foundation
import XCTest
@testable import DetachKit

final class SessionColorTests: XCTestCase {
    func testTmuxStatusTintUsesTheRuntimeBlendFormula() throws {
        let color = try XCTUnwrap(SessionColor(hex: "#C2410C"))

        XCTAssertEqual(color.tmuxStatusTint(percent: 55).hex, "#793219")
        XCTAssertEqual(color.tmuxStatusTint(percent: 45).hex, "#682E1D")
        XCTAssertEqual(color.tmuxStatusTint(percent: 25).hex, "#482823")
    }

    func testTmuxStatusTintPreservesFormulaEndpoints() throws {
        let color = try XCTUnwrap(SessionColor(hex: "#36C5F0"))

        XCTAssertEqual(color.tmuxStatusTint(percent: 0).hex, "#20202B")
        XCTAssertEqual(color.tmuxStatusTint(percent: 100), color)
    }

    func testCodableRoundTripUsesTheCanonicalHexValue() throws {
        let color = try XCTUnwrap(SessionColor(hex: "#c2410c"))

        let encoded = try JSONEncoder().encode(color)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"#C2410C\"")
        XCTAssertEqual(try JSONDecoder().decode(SessionColor.self, from: encoded), color)
    }
}
