import Foundation

public enum TmuxExtendedKeys: String, Equatable, Sendable, CaseIterable {
    /// Forward ghostty's CSI-u key encodings (for example Shift+Return) to the
    /// managed pane by enabling tmux extended keys on the private server.
    case on
    /// Leave managed sessions with default tmux key handling.
    case off

    public var isEnabled: Bool { self == .on }
}

public enum TmuxExtendedKeysClientError: LocalizedError, Equatable {
    case timedOut
    case commandFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            L10n.string("detach config timed out")
        case .commandFailed(let message):
            message
        case .invalidResponse(let value):
            L10n.format(
                "detach returned an unsupported tmux extended-keys setting: %@",
                value.isEmpty ? L10n.string("<empty>") : value)
        }
    }
}

/// Typed access to the CLI-backed tmux extended-keys setting.
public struct TmuxExtendedKeysClient: Sendable {
    private let cli: any DetachCLIRunning

    public init(cli: any DetachCLIRunning) {
        self.cli = cli
    }

    public func loadSetting() async throws -> TmuxExtendedKeys {
        let result = try await cli.run(arguments: ["config", "tmux-extended-keys"], timeout: 5)
        try validate(result)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let setting = TmuxExtendedKeys(rawValue: value) else {
            throw TmuxExtendedKeysClientError.invalidResponse(value)
        }
        return setting
    }

    public func setSetting(_ setting: TmuxExtendedKeys) async throws {
        let result = try await cli.run(
            arguments: ["config", "tmux-extended-keys", setting.rawValue],
            timeout: 5)
        try validate(result)
    }

    private func validate(_ result: CLIResult) throws {
        if result.timedOut {
            throw TmuxExtendedKeysClientError.timedOut
        }
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TmuxExtendedKeysClientError.commandFailed(
                stderr.isEmpty
                    ? L10n.format("detach config exited with status %d", result.exitCode)
                    : stderr)
        }
    }
}
