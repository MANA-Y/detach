import DetachKit
import Foundation

/// Loads and persists the tmux extended-keys setting for Settings → Terminal.
/// The orchestration lives here (not inline in the view) so its load, save,
/// optimistic rollback, and stale-path guarding are unit-testable, mirroring the
/// tmux style toggle's behavior.
@MainActor
final class TmuxExtendedKeysSettingsController: ObservableObject {
    @Published private(set) var setting: TmuxExtendedKeys?
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let makeClient: (String) -> TmuxExtendedKeysClient
    private var activePath: String?

    init(
        makeClient: @escaping (String) -> TmuxExtendedKeysClient = { path in
            TmuxExtendedKeysClient(
                cli: ProcessDetachCLI(executable: URL(fileURLWithPath: path)))
        }
    ) {
        self.makeClient = makeClient
    }

    var isEnabled: Bool { setting?.isEnabled ?? false }

    func load(detachPath: String) async {
        activePath = detachPath
        isUpdating = true
        errorMessage = nil
        defer {
            if activePath == detachPath {
                isUpdating = false
            }
        }
        do {
            let value = try await makeClient(detachPath).loadSetting()
            guard !Task.isCancelled, activePath == detachPath else { return }
            setting = value
        } catch {
            guard !Task.isCancelled, activePath == detachPath else { return }
            setting = nil
            errorMessage = L10n.format(
                "Couldn't read the tmux setting: %@", error.localizedDescription)
        }
    }

    func save(_ newValue: TmuxExtendedKeys, detachPath: String) async {
        guard !isUpdating, let previous = setting, newValue != previous else { return }
        activePath = detachPath
        setting = newValue
        isUpdating = true
        errorMessage = nil
        defer {
            if activePath == detachPath {
                isUpdating = false
            }
        }
        do {
            try await makeClient(detachPath).setSetting(newValue)
        } catch {
            guard !Task.isCancelled, activePath == detachPath else { return }
            setting = previous
            errorMessage = L10n.format(
                "Couldn't save the tmux setting: %@", error.localizedDescription)
        }
    }
}
