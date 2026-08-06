import XCTest
@testable import DetachKit

final class TmuxExtendedKeysClientTests: XCTestCase {
    func testErrorDescriptionsCoverTimeoutCommandAndEmptyResponse() {
        XCTAssertEqual(
            TmuxExtendedKeysClientError.timedOut.errorDescription,
            L10n.string("detach config timed out"))
        XCTAssertEqual(
            TmuxExtendedKeysClientError.commandFailed("denied").errorDescription,
            "denied")
        XCTAssertEqual(
            TmuxExtendedKeysClientError.invalidResponse("").errorDescription,
            L10n.format(
                "detach returned an unsupported tmux extended-keys setting: %@",
                L10n.string("<empty>")))
        XCTAssertEqual(
            TmuxExtendedKeysClientError.invalidResponse("custom").errorDescription,
            L10n.format(
                "detach returned an unsupported tmux extended-keys setting: %@", "custom"))
    }

    func testLoadsSettingThroughConfigGetter() async throws {
        let cli = FakeCLI()
        cli.responses["config tmux-extended-keys"] = .success(CLIResult(
            exitCode: 0, stdout: "off\n", stderr: "", timedOut: false))

        let setting = try await TmuxExtendedKeysClient(cli: cli).loadSetting()

        XCTAssertEqual(setting, .off)
        XCTAssertFalse(setting.isEnabled)
        XCTAssertEqual(cli.calls, [["config", "tmux-extended-keys"]])
    }

    func testSavesSettingThroughConfigSetter() async throws {
        let cli = FakeCLI()

        try await TmuxExtendedKeysClient(cli: cli).setSetting(.on)

        XCTAssertEqual(cli.calls, [["config", "tmux-extended-keys", "on"]])
    }

    func testRejectsUnsupportedGetterOutput() async {
        let cli = FakeCLI()
        cli.responses["config tmux-extended-keys"] = .success(CLIResult(
            exitCode: 0, stdout: "always\n", stderr: "", timedOut: false))

        do {
            _ = try await TmuxExtendedKeysClient(cli: cli).loadSetting()
            XCTFail("expected invalid response")
        } catch {
            XCTAssertEqual(
                error as? TmuxExtendedKeysClientError, .invalidResponse("always"))
        }
    }

    func testReportsCLIErrorAndTimeout() async {
        let failing = FakeCLI()
        failing.responses["config tmux-extended-keys off"] = .success(CLIResult(
            exitCode: 2, stdout: "", stderr: "config is read-only\n", timedOut: false))
        do {
            try await TmuxExtendedKeysClient(cli: failing).setSetting(.off)
            XCTFail("expected command failure")
        } catch {
            XCTAssertEqual(
                error as? TmuxExtendedKeysClientError,
                .commandFailed("config is read-only"))
        }

        let timedOut = FakeCLI()
        timedOut.responses["config tmux-extended-keys"] = .success(CLIResult(
            exitCode: 15, stdout: "", stderr: "", timedOut: true))
        do {
            _ = try await TmuxExtendedKeysClient(cli: timedOut).loadSetting()
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? TmuxExtendedKeysClientError, .timedOut)
        }
    }

    func testCommandFailureWithoutStderrFallsBackToExitStatus() async {
        let cli = FakeCLI()
        cli.responses["config tmux-extended-keys on"] = .success(CLIResult(
            exitCode: 23, stdout: "", stderr: " \n", timedOut: false))

        do {
            try await TmuxExtendedKeysClient(cli: cli).setSetting(.on)
            XCTFail("expected command failure")
        } catch {
            XCTAssertEqual(
                error as? TmuxExtendedKeysClientError,
                .commandFailed(L10n.format("detach config exited with status %d", 23)))
        }
    }
}
