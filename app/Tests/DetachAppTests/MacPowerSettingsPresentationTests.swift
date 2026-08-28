import DetachKit
import SwiftUI
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

@MainActor
final class MacPowerLiveSessionTests: XCTestCase {
    func testCountsTreatStartingAndRecoveringAsActive() {
        let sessions = [
            session(status: "starting"),
            session(status: "recovering"),
            session(status: "completed"),
        ]
        XCTAssertEqual(
            MacPowerLiveSessions.live(in: sessions).map(\.effectiveStatus),
            [.starting, .recovering])
        let counts = MacPowerLiveSessions.counts(in: sessions)
        XCTAssertEqual(counts.active, 2)
        XCTAssertEqual(counts.working, 2)
    }

    func testCountsSeparateWaitingRunningSessions() {
        let sessions = [
            session(status: "running", turnState: "waiting"),
            session(status: "starting"),
        ]
        let counts = MacPowerLiveSessions.counts(in: sessions)
        XCTAssertEqual(counts.active, 2)
        XCTAssertEqual(counts.working, 1)
    }

    func testHeartbeatStartsBeforeStorageFinishesAndAwaitsCancel() async {
        var events: [String] = []
        let task = Task {
            await SystemTabHeartbeatRefresh.run(
                refreshPower: { events.append("power") },
                refreshStorage: {
                    events.append("storage-start")
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    events.append("storage-end")
                },
                sleepNanoseconds: 1_000_000_000)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(events.first, "power")
        XCTAssertTrue(events.contains("storage-start"))
        XCTAssertFalse(events.contains("storage-end"))
        task.cancel()
        await task.value
        XCTAssertTrue(events.contains("storage-end"))
    }

    func testHeartbeatRepeatsAfterTheSleepInterval() async {
        var powerCount = 0
        let task = Task {
            await SystemTabHeartbeatRefresh.run(
                refreshPower: { powerCount += 1 },
                refreshStorage: {},
                sleepNanoseconds: 8_000_000)
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
        task.cancel()
        await task.value
        XCTAssertGreaterThanOrEqual(powerCount, 2)
    }

    func testSettingsSystemPaneCountsAStartingSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        try Data(
            #"{"state":"ok","power_state":"allowed","checked_at":"\#(checkedAt)"}"#
                .utf8
        ).write(to: root.appendingPathComponent("watchdog-status.json"))

        let cli = LiveSessionListCLI(stdout: sessionJSON(status: "starting"))
        let sessionStore = SessionStore(cli: cli)
        await sessionStore.refresh()

        let view = SettingsView(
            installation: InstallationStore(
                detachPath: "/tmp/detach-test",
                powerStateRoot: root),
            sessionStore: sessionStore,
            storageStore: StorageStore(cli: cli),
            updater: UpdaterService(),
            notifications: SessionNotificationService(
                center: SilentNotificationCenter(),
                identifierProvider: { "settings-test" }),
            navigation: SettingsNavigation(selectedTab: .system))

        XCTAssertNotEqual(view.macPowerPresentation.reason, .noActiveSessions)
        XCTAssertEqual(view.macPowerPresentation.reason, .sessionsNotHolding(1))
    }
}

private struct SilentNotificationCenter: SessionNotificationCenterBackend {
    func authorizationStatus() async -> SessionNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func deliver(_ payload: SessionNotificationPayload) async throws {}
}

private struct LiveSessionListCLI: DetachCLIRunning {
    let stdout: String

    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        CLIResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false)
    }
}

private func session(status: String, turnState: String? = nil) -> Session {
    SessionListParser.parse(sessionJSON(status: status, turnState: turnState)).sessions[0]
}

private func sessionJSON(status: String, turnState: String? = nil) -> String {
    let turnField = turnState.map { #","agent_turn_state":"\#($0)""# } ?? ""
    return """
    {"schema":1,"provider":"codex","session_name":"detach-codex-\(status)",\
    "name":"\(status)","effective_status":"\(status)","meta_status":"\(status)",\
    "agent_session_id":"\(status)","project_dir":"/tmp/p",\
    "created_at":"2026-07-15T10:00:00Z","last_checkpoint_at":null,\
    "exit_status":null,"finished_at":null\(turnField)}
    """
}
