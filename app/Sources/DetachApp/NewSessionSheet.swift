import SwiftUI
import UniformTypeIdentifiers
import DetachKit

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontPointSize) private var fontPointSize
    @AppStorage(AppSettings.terminalBundleIdentifierKey, store: AppSettings.defaults)
    private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier

    let detachPath: String

    @State private var projectDir: URL?
    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var prompt = ""
    @State private var showPicker = false
    @State private var launchFailure: TerminalLaunchFailure?
    @State private var isLaunching = false

    init(detachPath: String, initialName: String = "") {
        self.detachPath = detachPath
        _name = State(initialValue: initialName)
    }

    private var normalizedName: String? {
        SessionNameValidator.normalizedCustomName(name)
    }

    private var isNameValid: Bool {
        SessionNameValidator.isValidInput(name, provider: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("New session")).appFont(.title3, weight: .bold)

            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text(L10n.string("Project"))
                    HStack {
                        Text(projectDir?.path ?? L10n.string("not selected"))
                            .foregroundStyle(projectDir == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L10n.string("Choose…")) { showPicker = true }
                    }
                }
                GridRow {
                    Text(L10n.string("Provider"))
                    Picker("", selection: $provider) {
                        ForEach(Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .gridCellAnchor(.leading)
                }
                GridRow {
                    Text(L10n.string("Name"))
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L10n.string("optional, for example Rev (ai)"), text: $name)
                            .accessibilityIdentifier("new-session-name")
                        if !isNameValid {
                            Text(L10n.string(
                                "Use printable text up to 100 UTF-8 bytes."))
                                .appFont(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("new-session-name-validation")
                        }
                    }
                }
            }

            Text(L10n.string("Initial prompt (optional)"))
                .appFont(.caption).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .appFont(.body)
                .frame(height: max(70, fontPointSize * 5.5))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            if let launchFailure {
                VStack(alignment: .leading, spacing: 6) {
                    Text(launchFailure.message).appFont(.caption).foregroundStyle(.red)
                    if launchFailure.requiresTerminalSelection {
                        SettingsLink {
                            Text(L10n.string("Choose another terminal"))
                        }
                        .appFont(.caption)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("new-session-cancel")
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(identifier: "new-session-cancel")
                    }
#endif
                Button(L10n.string("Launch in Terminal")) {
                    Task { await launch() }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                    .disabled(projectDir == nil || !isNameValid || isLaunching)
                    .accessibilityIdentifier("new-session-launch")
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(identifier: "new-session-launch")
                    }
#endif
            }
        }
        .padding(20)
        .frame(width: max(460, fontPointSize * 32))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-session-sheet")
#if !DEBUG
        .background {
            uiE2EGeometryProbe(identifier: "new-session-sheet")
        }
#endif
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { projectDir = url }
        }
    }

#if !DEBUG
    @ViewBuilder
    private func uiE2EGeometryProbe(identifier: String) -> some View {
        if AppSettings.uiE2E != nil {
            UIE2EGeometryProbe(identifier: identifier)
        }
    }
#endif

    @MainActor
    private func launch() async {
        guard !isLaunching, isNameValid, let projectDir else { return }
        isLaunching = true
        defer { isLaunching = false }
        let command = TerminalCommand.start(
            detachPath: detachPath,
            provider: provider,
            projectDir: projectDir.path,
            name: normalizedName,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt)
        launchFailure = nil
        let failure = await TerminalLauncher.open(
            command: command,
            terminalBundleIdentifier: terminalBundleIdentifier)
        if let failure {
            launchFailure = failure
        } else {
            dismiss()
        }
    }
}
