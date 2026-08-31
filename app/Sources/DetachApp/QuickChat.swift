import Foundation
import DetachKit

enum DirectoryPreference {
    static func existingDirectoryURL(
        path: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func configuredOrFallback(
        path: String,
        fallback: URL,
        fileManager: FileManager = .default
    ) -> URL {
        existingDirectoryURL(path: path, fileManager: fileManager)
            ?? fallback
    }
}

@MainActor
enum QuickChatLaunch {
    static func provider(rawValue: String) -> Provider {
        Provider(rawValue: rawValue) ?? .claude
    }

    static func start(
        store: SessionStore,
        providerRawValue: String,
        directoryPath: String,
        fileManager: FileManager = .default,
        onSessionAvailable: (@MainActor (String) -> Void)? = nil,
        discoverySleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) async -> SessionStartResult {
        guard let directory = DirectoryPreference.existingDirectoryURL(
            path: directoryPath,
            fileManager: fileManager) else {
            return SessionStartResult(message: L10n.format(
                "Quick chat folder is unavailable: %@",
                directoryPath))
        }
        let provider = provider(rawValue: providerRawValue)
        guard let onSessionAvailable else {
            return await store.startDetached(
                provider: provider,
                projectDirectory: directory,
                name: nil,
                prompt: nil)
        }

        let existingIDs = Set(store.sessions.map(\.id))
        var launchFinished = false
        let launchTask = Task { @MainActor in
            defer { launchFinished = true }
            return await store.startDetached(
                provider: provider,
                projectDirectory: directory,
                name: nil,
                prompt: nil)
        }
        defer { launchTask.cancel() }

        // The typed `starting` row exists before the CLI finishes its runtime
        // readiness checks. Select it as soon as it is unambiguous.
        var selectedEarly = false
        for delay in [75_000_000, 175_000_000] where !launchFinished {
            do {
                try await discoverySleep(UInt64(delay))
            } catch {
                break
            }
            guard !launchFinished else { break }
            await store.refresh()
            if let sessionID = newSessionID(
                in: store.sessions,
                excluding: existingIDs,
                provider: provider,
                projectDirectory: directory) {
                selectedEarly = true
                onSessionAvailable(sessionID)
                break
            }
        }

        let result = await launchTask.value
        if selectedEarly && result.message != nil {
            await store.refresh()
        }
        return result
    }

    private static func newSessionID(
        in sessions: [Session],
        excluding existingIDs: Set<String>,
        provider: Provider,
        projectDirectory: URL
    ) -> String? {
        let projectPath = canonicalProjectPath(projectDirectory.path)
        let candidates = sessions.filter {
            !existingIDs.contains($0.id)
                && $0.provider == provider
                && $0.projectDir.map(canonicalProjectPath) == projectPath
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    private static func canonicalProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}

struct SidebarShortcutHint: Equatable, Identifiable {
    let shortcut: String
    let title: String

    var id: String { shortcut }
}

enum SidebarShortcutPresentation {
    static var hints: [SidebarShortcutHint] { [
        SidebarShortcutHint(
            shortcut: "⌘N",
            title: L10n.string("New session")),
        SidebarShortcutHint(
            shortcut: "⌘T",
            title: L10n.string("Quick chat")),
        SidebarShortcutHint(
            shortcut: "⌘,",
            title: L10n.string("Settings")),
        SidebarShortcutHint(
            shortcut: "⌘F",
            title: L10n.string("Find output")),
    ] }
}
