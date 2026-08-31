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
        fileManager: FileManager = .default
    ) async -> SessionStartResult {
        guard let directory = DirectoryPreference.existingDirectoryURL(
            path: directoryPath,
            fileManager: fileManager) else {
            return SessionStartResult(message: L10n.format(
                "Quick chat folder is unavailable: %@",
                directoryPath))
        }
        return await store.startDetached(
            provider: provider(rawValue: providerRawValue),
            projectDirectory: directory,
            name: nil,
            prompt: nil)
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
