import XCTest
@testable import DetachKit

final class TerminalLauncherTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCommandFileIsPrivateExecutableAndPreservesCommand() throws {
        let command = #"echo "it's $HOME" && exec '/tmp/a b'"#
        let url = try TerminalLauncher.writeCommandFile(
            command: command,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let startupURL = url.deletingLastPathComponent().appendingPathComponent(".zshenv")
        let startupContents = try String(contentsOf: startupURL, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let startupAttributes = try FileManager.default.attributesOfItem(atPath: startupURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)

        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix("Detach-"))
        XCTAssertEqual(url.lastPathComponent, "run.command")
        XCTAssertEqual(url.pathExtension, "command")
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertEqual(
            startupAttributes[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600))
        XCTAssertEqual(
            directoryAttributes[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o700))
        XCTAssertTrue(contents.hasPrefix("#!/bin/zsh\n"))
        XCTAssertLessThan(
            try XCTUnwrap(contents.range(of: "builtin cd -q --")?.lowerBound),
            try XCTUnwrap(contents.range(of: "/bin/rm -f -- \"$command_file\"")?.lowerBound))
        XCTAssertLessThan(
            try XCTUnwrap(contents.range(of: "/bin/rm -f -- \"$command_file\" || exit 125")?.lowerBound),
            try XCTUnwrap(contents.range(of: "exec /bin/zsh -lic")?.lowerBound))
        XCTAssertTrue(contents.contains("[[ ! -e \"$command_file\" ]] || exit 125"))
        XCTAssertTrue(contents.contains("DETACH_TERMINAL_ORIGINAL_ZDOTDIR"))
        XCTAssertFalse(contents.contains("/bin/rmdir -- \"$command_dir\""))
        XCTAssertTrue(contents.contains("exec /bin/zsh -lic \(shellQuoted(command))"))
        XCTAssertTrue(startupContents.contains("! -e \"$detach_outer_zdotdir/run.command\""))
        XCTAssertTrue(startupContents.contains("source \"$detach_user_zdotdir/.zshenv\""))
    }

    @MainActor
    func testLaunchUsesPrivateOuterZshStartupDirectory() throws {
        let url = try TerminalLauncher.writeCommandFile(
            command: "exec /usr/bin/true",
            temporaryDirectory: temporaryDirectory,
            fileManager: .default)
        let configuration = TerminalLauncher.openConfiguration(
            commandURL: url,
            processEnvironment: ["ZDOTDIR": "/Users/test/custom-zdotdir"])

        XCTAssertTrue(configuration.createsNewApplicationInstance)
        XCTAssertEqual(
            configuration.environment["ZDOTDIR"],
            url.deletingLastPathComponent().path)
        XCTAssertEqual(
            configuration.environment["DETACH_TERMINAL_ORIGINAL_ZDOTDIR"],
            "/Users/test/custom-zdotdir")
    }

    func testFailureReasonRequiresSelectionOnlyForMissingTerminal() {
        XCTAssertTrue(TerminalLaunchFailure(
            message: "missing", reason: .terminalUnavailable)
            .requiresTerminalSelection)
        XCTAssertFalse(TerminalLaunchFailure(
            message: "prepare", reason: .commandFile)
            .requiresTerminalSelection)
        XCTAssertFalse(TerminalLaunchFailure(
            message: "open", reason: .openFailed)
            .requiresTerminalSelection)
    }

    @MainActor
    func testMissingSelectedTerminalReturnsActionableFailure() async {
        let failure = await TerminalLauncher.open(
            command: "exec /usr/bin/true",
            terminalBundleIdentifier:
                "dev.tsarev.detach.tests.missing-\(UUID().uuidString)")

        XCTAssertEqual(failure?.reason, .terminalUnavailable)
        XCTAssertTrue(failure?.requiresTerminalSelection == true)
        XCTAssertTrue(failure?.message.contains("Settings") == true)
    }

    @MainActor
    func testUnsafeCommandFailsPreparationAndLeavesNoTemporaryDirectory() async {
        let terminal = TerminalApplication(
            bundleIdentifier: "test.terminal",
            displayName: "Test Terminal",
            applicationURL: URL(fileURLWithPath: "/Applications/Test Terminal.app"))
        var attemptedOpen = false

        let failure = await TerminalLauncher.open(
            command: "printf unsafe\0suffix",
            terminal: terminal,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default,
            openApplication: { _, _ in attemptedOpen = true })

        XCTAssertEqual(failure?.reason, .commandFile)
        XCTAssertTrue(failure?.message.contains("temporary command") == true)
        XCTAssertFalse(attemptedOpen)
        XCTAssertEqual(
            try? FileManager.default.contentsOfDirectory(
                atPath: temporaryDirectory.path),
            [])
    }

    func testUnsafeCommandFileContentIsRejectedDirectly() {
        XCTAssertThrowsError(try TerminalLauncher.commandFileContents(
            command: "echo before\0after")) { error in
                XCTAssertEqual(
                    (error as? CocoaError)?.code,
                    .fileWriteInapplicableStringEncoding)
            }
    }

    func testCommandFileRemovesPayloadAndKeepsStartupGuard() throws {
        let safeHome = temporaryDirectory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: safeHome, withIntermediateDirectories: false)
        let url = try TerminalLauncher.writeCommandFile(
            command: "exec /bin/pwd",
            temporaryDirectory: temporaryDirectory,
            fileManager: .default)
        let commandDirectory = url.deletingLastPathComponent()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["./run.command"]
        process.currentDirectoryURL = commandDirectory
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = safeHome.path
        environment["ZDOTDIR"] = commandDirectory.path
        environment.removeValue(forKey: "DETACH_TERMINAL_ORIGINAL_ZDOTDIR")
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), safeHome.path)
        XCTAssertFalse(stderr.contains("getcwd"), stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: commandDirectory.appendingPathComponent(".zshenv").path))
    }

    func testStartupGuardRestoresUserStartupFilesInLaterShells() throws {
        let safeHome = temporaryDirectory.appendingPathComponent("later-home", isDirectory: true)
        try FileManager.default.createDirectory(at: safeHome, withIntermediateDirectories: false)
        for (name, marker) in [
            (".zshenv", "user-zshenv"),
            (".zprofile", "user-zprofile"),
            (".zshrc", "user-zshrc"),
            (".zlogin", "user-zlogin")
        ] {
            try Data("print -r -- \(marker)\n".utf8).write(
                to: safeHome.appendingPathComponent(name),
                options: .withoutOverwriting)
        }
        let commandURL = try TerminalLauncher.writeCommandFile(
            command: "exec /usr/bin/true",
            temporaryDirectory: temporaryDirectory,
            fileManager: .default)
        let commandDirectory = commandURL.deletingLastPathComponent()

        let initial = try runLoginZsh(home: safeHome, zdotdir: commandDirectory)
        XCTAssertEqual(initial.status, 0, initial.stderr)
        XCTAssertFalse(initial.stdout.contains("user-zsh"), initial.stdout)

        try FileManager.default.removeItem(at: commandURL)
        let later = try runLoginZsh(home: safeHome, zdotdir: commandDirectory)
        XCTAssertEqual(later.status, 0, later.stderr)
        XCTAssertTrue(later.stdout.contains("user-zshenv"), later.stdout)
        XCTAssertTrue(later.stdout.contains("user-zprofile"), later.stdout)
        XCTAssertTrue(later.stdout.contains("user-zshrc"), later.stdout)
        XCTAssertTrue(later.stdout.contains("user-zlogin"), later.stdout)
    }

    @MainActor
    func testSuccessfulLaunchLeavesCommandQueuedUntilTerminalExecutesIt() async throws {
        let terminal = TerminalApplication(
            bundleIdentifier: "test.terminal",
            displayName: "Test Terminal",
            applicationURL: URL(fileURLWithPath: "/Applications/Test Terminal.app"))
        var openedApplicationURL: URL?
        var commandURL: URL?
        let failure = await TerminalLauncher.open(
            command: "exec /usr/bin/true",
            terminal: terminal,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default,
            openApplication: { url, applicationURL in
                openedApplicationURL = applicationURL
                commandURL = url
                XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
            })

        XCTAssertNil(failure)
        XCTAssertEqual(openedApplicationURL, terminal.applicationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commandURL?.path ?? ""))
    }

    private func runLoginZsh(home: URL, zdotdir: URL) throws -> (
        status: Int32,
        stdout: String,
        stderr: String
    ) {
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "exec /usr/bin/true"]
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["ZDOTDIR"] = zdotdir.path
        environment.removeValue(forKey: "DETACH_TERMINAL_ORIGINAL_ZDOTDIR")
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @MainActor
    func testWorkspaceOpenErrorRemovesCommandFile() async {
        struct OpenError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let terminal = TerminalApplication(
            bundleIdentifier: "test.terminal",
            displayName: "Test Terminal",
            applicationURL: URL(fileURLWithPath: "/Applications/Test Terminal.app"))
        var commandURL: URL?
        let failure = await TerminalLauncher.open(
            command: "exec /usr/bin/true",
            terminal: terminal,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default,
            openApplication: { url, _ in
                commandURL = url
                throw OpenError()
            })

        XCTAssertEqual(failure?.reason, .openFailed)
        XCTAssertTrue(failure?.message.contains("boom") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandURL?.path ?? ""))
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path))?.isEmpty
                == true)
    }
}
