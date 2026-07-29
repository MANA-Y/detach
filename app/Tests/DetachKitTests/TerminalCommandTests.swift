import XCTest
@testable import DetachKit

final class TerminalCommandTests: XCTestCase {
    let detach = "/Users/me/.local/bin/detach"

    func session(_ status: EffectiveStatus = .running, uuid: String? = "1111-2222") -> Session {
        SessionListParser.parse("""
        {"schema":1,"provider":"codex","session_name":"detach-codex-proj-abcd1234","name":"proj-abcd1234","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":\(uuid.map { "\"\($0)\"" } ?? "null"),"project_dir":"/tmp/p","created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """).sessions[0]
    }

    func testQuotingEscapesSingleQuotes() {
        XCTAssertEqual(shellQuoted("it's; rm -rf *"), "'it'\\''s; rm -rf *'")
    }

    func testCustomSessionNameNormalization() {
        XCTAssertNil(SessionNameValidator.normalizedCustomName(""))
        XCTAssertNil(SessionNameValidator.normalizedCustomName(" \n\t"))
        XCTAssertEqual(
            SessionNameValidator.normalizedCustomName("  Rev-ai \n"),
            "Rev-ai")
    }

    func testCustomSessionNameGrammarMatchesCLI() {
        for name in [
            "a",
            "Rev-ai",
            "rev_ai-2",
            "a" + String(repeating: "b", count: 47),
            "detach-claude-Rev-ai",
        ] {
            XCTAssertTrue(
                SessionNameValidator.isValidCustomName(name, provider: .claude),
                name)
        }

        for name in [
            "",
            "Rev (ai)",
            "-revision",
            "_revision",
            "ревизия",
            "a" + String(repeating: "b", count: 48),
            "detach-claude-",
        ] {
            XCTAssertFalse(
                SessionNameValidator.isValidCustomName(name, provider: .claude),
                name)
        }

        XCTAssertTrue(SessionNameValidator.isValidInput(" \t", provider: .claude))
        XCTAssertTrue(SessionNameValidator.isValidInput("  Rev-ai  ", provider: .claude))
        XCTAssertFalse(SessionNameValidator.isValidInput("  Rev (ai)  ", provider: .claude))
    }

    func testAttach() {
        XCTAssertEqual(
            TerminalCommand.attach(detachPath: detach, session: session()),
            "exec '/Users/me/.local/bin/detach' codex attach 'detach-codex-proj-abcd1234'")
    }

    func testResumeNeedsUUID() {
        XCTAssertEqual(
            TerminalCommand.resume(detachPath: detach, session: session(.stopped)),
            "exec '/Users/me/.local/bin/detach' resume '1111-2222'")
        XCTAssertNil(TerminalCommand.resume(detachPath: detach, session: session(.stopped, uuid: nil)))
    }

    func testRecover() {
        XCTAssertEqual(
            TerminalCommand.recover(detachPath: detach, session: session(.recoverable)),
            "exec '/Users/me/.local/bin/detach' codex recover 'detach-codex-proj-abcd1234'")
    }

    func testStartComposesAllParts() {
        XCTAssertEqual(
            TerminalCommand.start(detachPath: detach, provider: .claude,
                                  projectDir: "/Users/me/dev/it's", name: "migration",
                                  prompt: "fix \"all\" tests"),
            "cd '/Users/me/dev/it'\\''s' && exec '/Users/me/.local/bin/detach' claude --name 'migration' -- 'fix \"all\" tests'")
    }

    func testStartOmitsEmptyParts() {
        XCTAssertEqual(
            TerminalCommand.start(detachPath: detach, provider: .codex,
                                  projectDir: "/tmp/p", name: nil, prompt: nil),
            "cd '/tmp/p' && exec '/Users/me/.local/bin/detach' codex")
    }
}
