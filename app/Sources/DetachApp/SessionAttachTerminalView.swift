import AppKit
import Darwin
import SwiftUI
import SwiftTerm
import DetachKit

/// Hosts one ephemeral PTY client for a live managed session.
final class SessionAttachController: NSObject, LocalProcessTerminalViewDelegate {
    let invocation: SessionAttachInvocation
    private(set) weak var terminalView: LocalProcessTerminalView?
    private(set) var lastSize: (cols: Int, rows: Int)?
    private(set) var exitCode: Int32?
    var onTerminated: ((Int32?) -> Void)?

    init(invocation: SessionAttachInvocation) {
        self.invocation = invocation
    }

    func applyFont(pointSize: CGFloat) {
        guard let terminalView else { return }
        applyFont(to: terminalView, pointSize: pointSize)
    }

    func start() {
        guard let terminalView else { return }
        start(on: terminalView)
    }

    func terminateClient() {
        guard let terminalView else { return }
        Self.terminate(process: terminalView.process)
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        terminalView?.process.send(data: bytes[...])
    }

    func copySelection(to pasteboard: NSPasteboard = .general) -> String {
        SessionAttachClipboard.write(
            terminalView?.selection.getSelectedText() ?? "",
            to: pasteboard)
    }

    func selectAllText() {
        terminalView?.selectAll(nil)
    }

    func recordSize(cols: Int, rows: Int) {
        lastSize = (cols, rows)
    }

    func handleProcessExit(_ exitCode: Int32?) {
        self.exitCode = exitCode
        if Thread.isMainThread {
            onTerminated?(exitCode)
        } else {
            DispatchQueue.main.async { [onTerminated] in
                onTerminated?(exitCode)
            }
        }
    }

    static func terminalFont(pointSize: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: max(pointSize, 1), weight: .regular)
    }

    static func terminate(process: LocalProcess, timeout: TimeInterval = 1) {
        let pid = process.shellPid
        process.terminate()
        guard pid > 0 else { return }

        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) {
                    return
                }
                guard result == 0 else { return }
                usleep(10_000)
            }

            guard waitpid(pid, &status, WNOHANG) == 0 else { return }
            _ = Darwin.kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

// quality-coverage:begin swiftterm-metal
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        recordSize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        handleProcessExit(exitCode)
    }

    func configure(_ view: LocalProcessTerminalView, fontPointSize: CGFloat) {
        view.processDelegate = self
        view.font = Self.terminalFont(pointSize: fontPointSize)
        view.nativeBackgroundColor = ANSIParser.terminalBackground
        view.nativeForegroundColor = NSColor(white: 0.85, alpha: 1)
        view.setAccessibilityIdentifier("session-preview-terminal")
        view.setAccessibilityLabel(L10n.string("Live session terminal"))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        terminalView = view
    }

    func applyFont(to view: LocalProcessTerminalView, pointSize: CGFloat) {
        let font = Self.terminalFont(pointSize: pointSize)
        guard view.font.pointSize != font.pointSize else { return }
        view.font = font
    }

    func start(on view: LocalProcessTerminalView) {
        view.startProcess(
            executable: invocation.executable,
            args: invocation.arguments,
            environment: invocation.environment)
    }
// quality-coverage:end swiftterm-metal
}

enum SessionAttachClipboard {
    @discardableResult
    static func write(_ text: String, to pasteboard: NSPasteboard) -> String {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }
}

struct SessionAttachTerminalView: NSViewRepresentable {
    let detachPath: String
    let session: Session
    let fontPointSize: CGFloat
    var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var onTerminated: (Int32?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: SessionAttachController(
                invocation: SessionAttachInvocation(
                    detachPath: detachPath,
                    session: session,
                    baseEnvironment: baseEnvironment)),
            onTerminated: onTerminated)
    }

// quality-coverage:begin swiftterm-host
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        context.coordinator.controller.onTerminated = context.coordinator.onTerminated
        context.coordinator.controller.configure(view, fontPointSize: fontPointSize)
        context.coordinator.controller.start()
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onTerminated = onTerminated
        context.coordinator.controller.onTerminated = onTerminated
        context.coordinator.controller.applyFont(pointSize: fontPointSize)
    }

    static func dismantleNSView(
        _ view: LocalProcessTerminalView,
        coordinator: Coordinator
    ) {
        coordinator.controller.terminateClient()
    }
// quality-coverage:end swiftterm-host

    final class Coordinator {
        let controller: SessionAttachController
        var onTerminated: (Int32?) -> Void

        init(controller: SessionAttachController, onTerminated: @escaping (Int32?) -> Void) {
            self.controller = controller
            self.onTerminated = onTerminated
        }
    }
}
