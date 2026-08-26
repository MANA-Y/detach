import Foundation
import Observation

public struct SessionDeletionFailure: Equatable, Sendable {
    public var sessionName: String
    public var displayTitle: String
    public var message: String

    public init(sessionName: String, displayTitle: String, message: String) {
        self.sessionName = sessionName
        self.displayTitle = displayTitle
        self.message = message
    }
}

@Observable @MainActor
public final class SessionStore {
    private enum Mutation {
        case stop
        case delete
    }

    public enum State: Equatable, Sendable {
        case ok
        case cliMissing
        case incompatible
        case error(String)
    }

    public private(set) var sessions: [Session] = []
    public private(set) var lastUpdated: Date?
    public private(set) var state: State = .ok

    /// Called after every successful poll — including an unchanged list — so
    /// a transition detector can advance its baseline. The store is the single
    /// app-level `list --json` poller; notifications and the menu bar consume
    /// these snapshots instead of running their own subprocess loops.
    @ObservationIgnored public var onSnapshot: (@MainActor ([Session]) async -> Void)?

    private var cli: DetachCLIRunning
    private var pollTask: Task<Void, Never>?
    private var baseInterval: TimeInterval = 2
    private var foreground = true
    private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private let pollSleep: @Sendable (UInt64) async throws -> Void

    public init(cli: DetachCLIRunning) {
        self.cli = cli
        self.pollSleep = { try await Task.sleep(nanoseconds: $0) }
    }

    init(
        cli: DetachCLIRunning,
        pollSleep: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.cli = cli
        self.pollSleep = pollSleep
    }

    /// Swaps the CLI (for example after the installed payload activates) and
    /// refreshes immediately. The polling cadence is unchanged.
    public func configure(cli: DetachCLIRunning) async {
        self.cli = cli
        await refresh()
    }

    public func startPolling(interval: TimeInterval) {
        baseInterval = max(interval, 0.5)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let delay = self?.currentInterval else { return }
                try? await self?.pollSleep(UInt64(delay * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Foreground (a visible window or open menu wants fresh data) polls at
    /// the base interval. Idle polling slows down but never stops, so
    /// notifications and the menu bar stay truthful after the last window
    /// closes.
    public func updateCadence(foreground: Bool) {
        self.foreground = foreground
    }

    private var currentInterval: TimeInterval {
        foreground ? baseInterval : max(baseInterval * 5, 10)
    }

    public func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let cli = self.cli
        do {
            let result = try await cli.run(arguments: ["list", "--json"], timeout: 5)
            // Polling, explicit refreshes, and CLI reconfiguration may overlap
            // while their subprocesses are suspended. Only the latest request
            // may publish state or notify transition consumers.
            guard generation == refreshGeneration else { return }
            guard result.exitCode == 0, !result.timedOut else {
                state = .error(result.timedOut ? L10n.string("detach list timed out")
                               : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            let parsed = SessionListParser.parse(result.stdout)
            if parsed.hadInvalidLines {
                state = .incompatible // spec: never update the list from bad data
                return
            }
            sessions = parsed.sessions.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            lastUpdated = Date()
            state = .ok
            if let onSnapshot { await onSnapshot(sessions) }
        } catch {
            guard generation == refreshGeneration else { return }
            state = .cliMissing
        }
    }

    /// Runs a non-interactive action (stop/delete). Returns an error message or nil.
    public func perform(_ action: SessionAction, on session: Session) async -> String? {
        guard action == .stop || action == .delete else {
            return L10n.format(
                "Internal error: %@ must run in Terminal",
                action.rawValue)
        }
        let mutation: Mutation = action == .stop ? .stop : .delete
        let result = await run(mutation, on: session)
        if result.launched { await refresh() }
        return result.message
    }

    /// Deletes every selected finished session and reports failures without
    /// stopping the remaining operations. One final refresh publishes the
    /// resulting list instead of polling between individual removals.
    public func deleteFinished(
        _ selectedSessions: [Session]
    ) async -> [SessionDeletionFailure] {
        var failures: [SessionDeletionFailure] = []
        var seen: Set<String> = []
        for session in selectedSessions where seen.insert(session.id).inserted {
            guard let current = sessions.first(where: { $0.id == session.id }),
                  current.canDeleteFromFinishedList else {
                failures.append(SessionDeletionFailure(
                    sessionName: session.sessionName,
                    displayTitle: session.displayTitle,
                    message: L10n.string(
                        "Session is not eligible for deletion from Finished.")))
                continue
            }
            if let message = await run(.delete, on: current).message {
                failures.append(SessionDeletionFailure(
                    sessionName: current.sessionName,
                    displayTitle: current.displayTitle,
                    message: message))
            }
        }
        await refresh()
        return failures
    }

    private func run(
        _ mutation: Mutation,
        on session: Session
    ) async -> (message: String?, launched: Bool) {
        let arguments: [String]
        switch mutation {
        case .stop:
            arguments = [session.provider.rawValue, "stop", session.sessionName]
        case .delete:
            arguments = [session.provider.rawValue, "delete", "--force", session.sessionName]
        }
        do {
            let result = try await cli.run(arguments: arguments, timeout: 30)
            if result.exitCode == 0 { return (nil, true) }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stderr.isEmpty
                ? L10n.format("detach exited with status %d", result.exitCode)
                : stderr, true)
        } catch {
            return (L10n.format(
                "Could not run detach: %@",
                error.localizedDescription), false)
        }
    }
}
