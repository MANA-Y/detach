import XCTest
@testable import DetachKit

final class SessionAttachTests: XCTestCase {
    func testPublicAttachUsesArgvAndNeverCallsTmux() {
        let invocation = SessionAttachInvocation(
            detachPath: "/Users/me/.local/bin/detach",
            session: session(),
            baseEnvironment: [
                "PATH": "/bin",
                "HOME": "/Users/me",
                "TMUX": "/tmp/foreign.sock,123,0",
                "TMUX_PANE": "%9",
            ])

        XCTAssertEqual(invocation.executable, "/Users/me/.local/bin/detach")
        XCTAssertEqual(
            invocation.arguments,
            ["codex", "attach", "detach-codex-proj-abcd1234"])
        XCTAssertFalse(invocation.arguments.contains { $0.contains("tmux") })
        XCTAssertFalse(invocation.environment.contains { $0.hasPrefix("TMUX=") })
        XCTAssertFalse(invocation.environment.contains { $0.hasPrefix("TMUX_PANE=") })
        XCTAssertTrue(invocation.environment.contains("TERM=xterm-256color"))
        XCTAssertTrue(
            invocation.environment.contains {
                $0.hasPrefix("PATH=") && $0.contains("/Users/me/.local/bin")
            })
    }

    func testClaudeAttachKeepsTheProviderAndInternalName() {
        XCTAssertEqual(
            SessionAttachInvocation.arguments(for: session(
                provider: .claude,
                name: "detach-claude-review")),
            ["claude", "attach", "detach-claude-review"])
    }

    func testOnlyLiveAttachableSessionsAreEligible() {
        XCTAssertTrue(SessionAttachInvocation.isEligible(session(status: .running)))
        XCTAssertTrue(SessionAttachInvocation.isEligible(session(status: .starting)))
        XCTAssertTrue(SessionAttachInvocation.isEligible(session(status: .hung)))
        XCTAssertFalse(SessionAttachInvocation.isEligible(session(status: .stopped)))
        XCTAssertFalse(SessionAttachInvocation.isEligible(session(status: .recoverable)))
        XCTAssertFalse(SessionAttachInvocation.isEligible(session(status: .collision)))
        XCTAssertTrue(
            SessionAttachInvocation.shouldEmbed(session(status: .running), clientActive: true))
        XCTAssertFalse(
            SessionAttachInvocation.shouldEmbed(session(status: .running), clientActive: false))
        XCTAssertFalse(
            SessionAttachInvocation.shouldEmbed(session(status: .stopped), clientActive: true))
    }

    private func session(
        status: EffectiveStatus = .running,
        provider: Provider = .codex,
        name: String = "detach-codex-proj-abcd1234"
    ) -> Session {
        SessionListParser.parse("""
        {"schema":1,"provider":"\(provider.rawValue)","session_name":"\(name)","name":"proj","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":"1111-2222","project_dir":"/tmp/p","created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """).sessions[0]
    }
}
