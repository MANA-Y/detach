import DetachKit
import XCTest
@testable import DetachApp

final class MacPowerSettingsPresentationTests: XCTestCase {
    func testPowerHelperHealthRequiresConfirmedLiveCheck() {
        let unreachable = PowerHelperSettingsPresentation(
            registrationStatus: .enabled,
            readinessConfirmed: false)
        XCTAssertEqual(unreachable.status, .error)
        XCTAssertEqual(
            unreachable.detailLocalizationKey,
            "The native power helper is registered, but its live check failed.")

        let reachable = PowerHelperSettingsPresentation(
            registrationStatus: .enabled,
            readinessConfirmed: true)
        XCTAssertEqual(reachable.status, .ok)
        XCTAssertNil(reachable.detailLocalizationKey)

        let staleReadiness = PowerHelperSettingsPresentation(
            registrationStatus: .notRegistered,
            readinessConfirmed: true)
        XCTAssertEqual(staleReadiness.status, .error)
        XCTAssertEqual(
            staleReadiness.detailLocalizationKey,
            "The native power helper is not registered yet.")
    }

    func testPowerHelperHealthExplainsRegistrationFailures() {
        let expected: [(PowerHelperRegistrationStatus, String)] = [
            (
                .requiresApproval,
                "One-time administrator approval is required for native sleep protection."),
            (
                .notRegistered,
                "The native power helper is not registered yet."),
            (
                .unavailable,
                "The native power helper is unavailable."),
        ]

        for (registrationStatus, detailLocalizationKey) in expected {
            let presentation = PowerHelperSettingsPresentation(
                registrationStatus: registrationStatus,
                readinessConfirmed: false)
            XCTAssertEqual(presentation.status, .error)
            XCTAssertEqual(
                presentation.detailLocalizationKey,
                detailLocalizationKey)
        }
    }

    func testStateLabelsDescribeSleepInWords() {
        let expected: [(PowerProtectionState, String)] = [
            (.protected, "Mac stays awake"),
            (.allowed, "Mac can sleep"),
            (.transitioning, "Enabling sleep protection"),
            (.lowBattery, "Mac can sleep: low battery"),
            (.temperature, "Mac can sleep: temperature"),
            (.unavailable, "Sleep protection unavailable"),
            (.unknown, "Sleep status unknown"),
        ]

        for (state, localizationKey) in expected {
            XCTAssertEqual(
                presentation(state: state).stateLocalizationKey,
                localizationKey)
        }
    }

    func testApprovalActionsTakePriorityOverSetupAndRepair() {
        XCTAssertEqual(
            presentation(
                helper: .requiresApproval,
                watchdog: .notRegistered,
                distributionMatchesBundle: false).action,
            .approveHelper)
        XCTAssertEqual(
            presentation(
                helper: .enabled,
                watchdog: .requiresApproval,
                distributionMatchesBundle: false).action,
            .approveBackground)
    }

    func testMissingComponentOffersSetup() {
        XCTAssertEqual(
            presentation(helper: .notRegistered).action,
            .setup)
        XCTAssertEqual(
            presentation(watchdog: .unavailable).action,
            .setup)
    }

    func testBrokenInstalledConfigurationOffersRepair() {
        XCTAssertEqual(
            presentation(distributionMatchesBundle: false).action,
            .repair)
        XCTAssertEqual(
            presentation(state: .unavailable).action,
            .repair)
    }

    func testUnknownStateOffersRefreshAndHealthyStateNeedsNoAction() {
        XCTAssertEqual(
            presentation(state: .unknown).action,
            .refresh)
        XCTAssertNil(presentation(state: .protected).action)
        XCTAssertNil(presentation(state: .allowed).action)
        XCTAssertNil(presentation(state: .lowBattery).action)
        XCTAssertNil(presentation(state: .temperature).action)
    }

    func testReasonComesFromHeartbeatStateFirst() {
        // Session count enriches the protected case…
        XCTAssertEqual(
            presentation(state: .protected, activeSessionCount: 2).reason,
            .activeSessions(2))
        // …but never contradicts the heartbeat: a cached session list with
        // zero running entries degrades to a generic protected reason.
        XCTAssertEqual(
            presentation(state: .protected, activeSessionCount: 0).reason,
            .protectionActive)
        XCTAssertEqual(
            presentation(state: .protected, activeSessionCount: nil).reason,
            .protectionActive)
        // A stale/unknown heartbeat wins over any live session count.
        XCTAssertEqual(
            presentation(state: .unknown, activeSessionCount: 3).reason,
            .noFreshReport)
        // An allowed heartbeat with visible live sessions must not claim
        // there are none; it names the mismatch instead.
        XCTAssertEqual(
            presentation(state: .allowed, activeSessionCount: 2).reason,
            .sessionsNotHolding(2))
        XCTAssertEqual(
            presentation(state: .allowed, activeSessionCount: 0).reason,
            .noActiveSessions)
        XCTAssertEqual(
            presentation(
                state: .allowed,
                activeSessionCount: 2,
                workingSessionCount: 0).reason,
            .waitingSessions(2))
    }

    func testReasonsForRemainingStates() {
        let expected: [(PowerProtectionState, MacPowerSettingsPresentation.Reason)] = [
            (.allowed, .noActiveSessions),
            (.lowBattery, .lowBattery),
            (.temperature, .temperature),
            (.transitioning, .confirming),
            (.unavailable, .helperUnreachable),
        ]
        for (state, reason) in expected {
            XCTAssertEqual(presentation(state: state).reason, reason)
        }
    }

    private func presentation(
        state: PowerProtectionState = .protected,
        helper: PowerHelperRegistrationStatus = .enabled,
        watchdog: WatchdogStatus = .enabled,
        distributionMatchesBundle: Bool = true,
        activeSessionCount: Int? = nil,
        workingSessionCount: Int? = nil
    ) -> MacPowerSettingsPresentation {
        MacPowerSettingsPresentation(
            state: state,
            helperStatus: helper,
            watchdogStatus: watchdog,
            distributionMatchesBundle: distributionMatchesBundle,
            activeSessionCount: activeSessionCount,
            workingSessionCount: workingSessionCount)
    }
}
