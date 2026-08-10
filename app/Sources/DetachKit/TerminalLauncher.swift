import Foundation

#if canImport(AppKit)
import AppKit

public struct TerminalLaunchFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case terminalUnavailable
        case commandFile
        case openFailed
    }

    public let message: String
    public let reason: Reason

    public var requiresTerminalSelection: Bool {
        reason == .terminalUnavailable
    }

}

public enum TerminalLauncher {
    /// Opens a private, self-deleting command file in the selected terminal.
    /// The bundle identifier is resolved for every launch, so moving or
    /// renaming the application does not invalidate the preference.
    @MainActor
    @discardableResult
    public static func open(
        command: String,
        terminalBundleIdentifier: String
    ) async -> TerminalLaunchFailure? {
        guard let terminal = TerminalCatalog.application(
            bundleIdentifier: terminalBundleIdentifier) else {
            return TerminalLaunchFailure(
                message: L10n.string("The selected terminal was not found. Choose another terminal in Settings."),
                reason: .terminalUnavailable)
        }
        return await open(
            command: command,
            terminal: terminal,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            fileManager: .default,
            openApplication: openApplication)
    }

    @MainActor
    static func open(
        command: String,
        terminal: TerminalApplication,
        temporaryDirectory: URL,
        fileManager: FileManager,
        openApplication: (URL, URL) async throws -> Void
    ) async -> TerminalLaunchFailure? {
        let commandURL: URL
        do {
            commandURL = try writeCommandFile(
                command: command,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager)
        } catch {
            return TerminalLaunchFailure(
                message: L10n.format(
                    "Could not safely prepare the temporary command: %@",
                    error.localizedDescription),
                reason: .commandFile)
        }

        do {
            try await openApplication(commandURL, terminal.applicationURL)
        } catch {
            removeCommandDirectory(containing: commandURL, fileManager: fileManager)
            return TerminalLaunchFailure(
                message: L10n.format(
                    "%@ could not open the command: %@",
                    terminal.displayName,
                    error.localizedDescription),
                reason: .openFailed)
        }

        // A terminal can acknowledge opening the file before its interactive
        // shell is ready to execute it. In particular, shell startup may stop
        // at an oh-my-zsh update prompt for an arbitrary amount of time. The
        // command file must therefore remain available after the workspace
        // handoff; it deletes itself as its first action once execution starts.
        return nil
    }

    @MainActor
    private static func openApplication(
        commandURL: URL,
        applicationURL: URL
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let configuration = openConfiguration(commandURL: commandURL)
            NSWorkspace.shared.open(
                [commandURL],
                withApplicationAt: applicationURL,
                configuration: configuration) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
        }
    }

    @MainActor
    static func openConfiguration(
        commandURL: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        // Terminal runs a .command document by typing its path into a new
        // interactive shell. A startup hook that reads one key, such as the
        // oh-my-zsh update prompt, can otherwise consume the leading slash.
        // A fresh application instance is required because NSWorkspace only
        // applies launch environment variables to a new process.
        configuration.createsNewApplicationInstance = true
        var environment = [
            "ZDOTDIR": commandURL.deletingLastPathComponent().path
        ]
        if let originalZDOTDIR = processEnvironment["ZDOTDIR"] {
            environment["DETACH_TERMINAL_ORIGINAL_ZDOTDIR"] = originalZDOTDIR
        }
        configuration.environment = environment
        return configuration
    }

    static func startupFileContents() -> Data {
        Data("""
        # Detach suppresses startup prompts until Terminal runs run.command.
        detach_outer_zdotdir=${ZDOTDIR:-}
        if [[ -n "$detach_outer_zdotdir" && ! -e "$detach_outer_zdotdir/run.command" ]]; then
            if [[ -n ${DETACH_TERMINAL_ORIGINAL_ZDOTDIR+x} ]]; then
                export ZDOTDIR="$DETACH_TERMINAL_ORIGINAL_ZDOTDIR"
            else
                unset ZDOTDIR
            fi
            unset DETACH_TERMINAL_ORIGINAL_ZDOTDIR
            detach_user_zdotdir=${ZDOTDIR:-${HOME:-/}}
            if [[ "$detach_user_zdotdir" != "$detach_outer_zdotdir" && -r "$detach_user_zdotdir/.zshenv" ]]; then
                source "$detach_user_zdotdir/.zshenv"
            fi
            unset detach_user_zdotdir
        fi
        unset detach_outer_zdotdir

        """.utf8)
    }

    static func commandFileContents(command: String) throws -> Data {
        guard !command.contains("\0") else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let script = """
        #!/bin/zsh
        command_file=${0:A}
        command_dir=${command_file:h}
        builtin cd -q -- "${HOME:-/}" || builtin cd -q -- / || exit 125
        /bin/rm -f -- "$command_file" || exit 125
        [[ ! -e "$command_file" ]] || exit 125
        if [[ -n ${DETACH_TERMINAL_ORIGINAL_ZDOTDIR+x} ]]; then
            export ZDOTDIR="$DETACH_TERMINAL_ORIGINAL_ZDOTDIR"
        else
            unset ZDOTDIR
        fi
        unset command_file command_dir DETACH_TERMINAL_ORIGINAL_ZDOTDIR
        exec /bin/zsh -lic \(shellQuoted(command))

        """
        return Data(script.utf8)
    }

    static func writeCommandFile(
        command: String,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        // The containing directory is private from the moment it is created,
        // so the command (which may contain a prompt) is never briefly exposed
        // with default permissions before chmod runs.
        let directory = temporaryDirectory
            .appendingPathComponent("Detach-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("run.command")
        let startupURL = directory.appendingPathComponent(".zshenv")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            try startupFileContents()
                .write(to: startupURL, options: .withoutOverwriting)
            try commandFileContents(command: command)
                .write(to: url, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: startupURL.path)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: url.path)
            return url
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func removeCommandDirectory(
        containing commandURL: URL,
        fileManager: FileManager
    ) {
        try? fileManager.removeItem(at: commandURL.deletingLastPathComponent())
    }
}
#endif
