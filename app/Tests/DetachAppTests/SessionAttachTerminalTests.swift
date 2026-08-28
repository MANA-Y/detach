import AppKit
import Darwin
import SwiftUI
import XCTest
import SwiftTerm
import DetachKit
@testable import DetachApp

private final class SilentDetachCLI: DetachCLIRunning, @unchecked Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}

final class SessionAttachTerminalTests: XCTestCase {
    func testPublicAttachRoundTripResizeCopyAndTermination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = root.appendingPathComponent("args")
        let detach = root.appendingPathComponent("detach")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" > '\(record.path)'
        case "$*" in
          "codex attach detach-codex-proj-abcd1234")
            exec /bin/cat
            ;;
        esac
        exit 2
        """.write(to: detach, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: detach.path)

        let session = try XCTUnwrap(Self.session())
        let invocation = SessionAttachInvocation(
            detachPath: detach.path,
            session: session,
            baseEnvironment: [
                "PATH": "/bin:/usr/bin",
                "HOME": root.path,
                "TMUX": "/tmp/foreign.sock,1,0",
                "TMUX_PANE": "%1",
            ])

        var exitCode: Int32?
        let terminal = HeadlessTerminal { exitCode = $0 }
        terminal.process.startProcess(
            executable: invocation.executable,
            args: invocation.arguments,
            environment: invocation.environment,
            currentDirectory: root.path)

        try waitUntil {
            (try? String(contentsOf: record, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "codex attach detach-codex-proj-abcd1234"
        }
        XCTAssertGreaterThan(terminal.process.shellPid, 0)
        XCTAssertTrue(terminal.process.running)

        terminal.send("round-trip\n")
        try waitUntil {
            bufferText(terminal).contains("round-trip")
        }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let copied = SessionAttachClipboard.write(bufferText(terminal), to: pasteboard)
        XCTAssertTrue(copied.contains("round-trip"), copied)
        XCTAssertEqual(pasteboard.string(forType: .string), copied)

        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(ioctl(terminal.process.childfd, TIOCSWINSZ, &size), 0)
        var current = winsize()
        XCTAssertEqual(ioctl(terminal.process.childfd, TIOCGWINSZ, &current), 0)
        XCTAssertEqual(current.ws_col, 120)
        XCTAssertEqual(current.ws_row, 40)

        let childPID = terminal.process.shellPid
        SessionAttachController.terminate(process: terminal.process)
        try waitUntil { exitCode != nil || !terminal.process.running }
        try waitUntil {
            errno = 0
            return Darwin.kill(childPID, 0) == -1 && errno == ESRCH
        }

        XCTAssertFalse(terminal.process.running)
        XCTAssertEqual(
            try String(contentsOf: record, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "codex attach detach-codex-proj-abcd1234")
    }

    func testTerminationEscalatesWhenTheClientIgnoresTerm() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-attach-kill-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ready = root.appendingPathComponent("ready")
        let terminal = HeadlessTerminal { _ in }
        terminal.process.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "trap '' TERM; : > '\(ready.path)'; exec /bin/sleep 5",
            ],
            environment: ["PATH=/bin:/usr/bin"],
            currentDirectory: root.path)

        try waitUntil {
            FileManager.default.fileExists(atPath: ready.path)
                && terminal.process.running
        }
        let childPID = terminal.process.shellPid
        XCTAssertGreaterThan(childPID, 0)

        SessionAttachController.terminate(
            process: terminal.process,
            timeout: 0.02)

        try waitUntil {
            errno = 0
            return Darwin.kill(childPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertFalse(terminal.process.running)
    }

    func testIdleControllerDoesNotTouchATerminalView() {
        let controller = SessionAttachController(invocation: Self.invocation())
        controller.applyFont(pointSize: 12)
        controller.start()
        controller.terminateClient()
        controller.send("noop")
        controller.selectAllText()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(controller.copySelection(to: pasteboard), "")
        XCTAssertNil(controller.terminalView)
        XCTAssertNil(controller.lastSize)
        XCTAssertNil(controller.exitCode)
        controller.recordSize(cols: 80, rows: 24)
        XCTAssertEqual(controller.lastSize?.cols, 80)
        XCTAssertEqual(controller.lastSize?.rows, 24)
    }

    func testProcessExitDeliversOnTheMainQueue() {
        let controller = SessionAttachController(invocation: Self.invocation())
        let onMain = expectation(description: "main-thread exit")
        var seen: Int32?
        controller.onTerminated = { code in
            XCTAssertTrue(Thread.isMainThread)
            seen = code
            onMain.fulfill()
        }
        controller.handleProcessExit(0)
        wait(for: [onMain], timeout: 1)
        XCTAssertEqual(controller.exitCode, 0)
        XCTAssertEqual(seen, 0)

        let offMain = expectation(description: "off-main exit")
        controller.onTerminated = { code in
            XCTAssertTrue(Thread.isMainThread)
            seen = code
            offMain.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            controller.handleProcessExit(9)
        }
        wait(for: [offMain], timeout: 1)
        XCTAssertEqual(controller.exitCode, 9)
        XCTAssertEqual(seen, 9)
    }

    func testCoordinatorOwnsThePublicAttachInvocation() throws {
        let session = try XCTUnwrap(Self.session())
        let view = SessionAttachTerminalView(
            detachPath: "/tmp/detach",
            session: session,
            fontPointSize: 14,
            baseEnvironment: [
                "PATH": "/bin",
                "HOME": "/tmp",
                "TMUX": "/tmp/foreign.sock,1,0",
            ])
        let coordinator = view.makeCoordinator()
        XCTAssertEqual(coordinator.controller.invocation.executable, "/tmp/detach")
        XCTAssertEqual(
            coordinator.controller.invocation.arguments,
            ["codex", "attach", "detach-codex-proj-abcd1234"])
        XCTAssertFalse(
            coordinator.controller.invocation.environment.contains {
                $0.hasPrefix("TMUX=")
            })
    }

    @MainActor
    func testStoppedSessionDetailUsesTheLogFallback() throws {
        let session = try XCTUnwrap(Self.session(status: "stopped"))
        _ = SessionDetailView(
            session: session,
            store: SessionStore(cli: SilentDetachCLI()),
            detachPath: "/tmp/detach").body
    }

    @MainActor
    func testRunningSessionDetailEmbedsTheAttachClient() throws {
        let session = try XCTUnwrap(Self.session(status: "running"))
        XCTAssertTrue(SessionAttachInvocation.shouldEmbed(session, clientActive: true))
        _ = SessionDetailView(
            session: session,
            store: SessionStore(cli: SilentDetachCLI()),
            detachPath: "/tmp/detach").body
    }

    func testTerminalFontMatchesTheAppSize() {
        XCTAssertEqual(SessionAttachController.terminalFont(pointSize: 17).pointSize, 17)
        XCTAssertTrue(SessionAttachController.terminalFont(pointSize: 14).isFixedPitch)
    }

    func testClipboardWriteCopiesUTF8Selection() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(
            SessionAttachClipboard.write("selected text", to: pasteboard),
            "selected text")
        XCTAssertEqual(pasteboard.string(forType: .string), "selected text")
    }

    @MainActor
    func testControlVReachesTheProviderAsTheRawClipboardImageShortcut() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-attach-control-v-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ready = root.appendingPathComponent("ready")
        let received = root.appendingPathComponent("received")
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "stty raw -echo; : > '\(ready.path)'; "
                    + "dd bs=1 count=1 of='\(received.path)' 2>/dev/null",
            ],
            environment: ["PATH=/bin:/usr/bin"])
        defer { SessionAttachController.terminate(process: terminal.process) }

        try waitUntil {
            FileManager.default.fileExists(atPath: ready.path)
                && terminal.process.running
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))

        XCTAssertTrue(SessionAttachKeyboard.routeProviderShortcut(
            from: event,
            send: terminal.send))

        try waitUntil {
            (try? Data(contentsOf: received).count) == 1
        }
        XCTAssertEqual(try Data(contentsOf: received), Data([0x16]))
    }

    func testProviderClipboardShortcutRequiresUnmodifiedControlV() throws {
        let controlV = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .capsLock],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "м",
            isARepeat: false,
            keyCode: 9))
        let commandV = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))

        XCTAssertEqual(
            SessionAttachKeyboard.providerInput(for: controlV),
            [0x16])
        XCTAssertNil(SessionAttachKeyboard.providerInput(for: commandV))
    }

    @MainActor
    func testScopedKeyboardRouting() throws {
        let terminal = LocalProcessTerminalView(frame: .zero)
        let coordinator = SessionAttachTerminalView.Coordinator(
            controller: SessionAttachController(invocation: Self.invocation()),
            onTerminated: { _ in })

        let controlV = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))
        var received: [UInt8] = []

        XCTAssertNil(coordinator.routeKeyboardEvent(
            controlV,
            window: nil,
            firstResponder: terminal,
            in: terminal,
            send: { received = $0 }))
        XCTAssertEqual(received, [0x16])

        XCTAssertTrue(coordinator.routeKeyboardEvent(
            controlV,
            window: nil,
            firstResponder: nil,
            in: terminal,
            send: { _ in }) === controlV)
    }

    private func bufferText(_ terminal: HeadlessTerminal) -> String {
        String(data: terminal.terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ predicate: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        struct Timeout: Error {}
        throw Timeout()
    }

    private static func session(status: String = "running") -> Session? {
        SessionListParser.parse("""
        {"schema":1,"provider":"codex","session_name":"detach-codex-proj-abcd1234","name":"proj-abcd1234","effective_status":"\(status)","meta_status":null,"agent_session_id":"1111-2222","project_dir":"/tmp/p","created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """).sessions.first
    }

    private static func invocation() -> SessionAttachInvocation {
        SessionAttachInvocation(
            detachPath: "/tmp/detach",
            session: session()!,
            baseEnvironment: [
                "PATH": "/bin",
                "HOME": "/tmp",
            ])
    }
}
