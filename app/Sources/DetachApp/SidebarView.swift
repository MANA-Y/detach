import SwiftUI
import DetachKit

enum FinishedDeletionPresentation {
    static func errorMessage(for failures: [SessionDeletionFailure]) -> String {
        failures
            .map { "\($0.displayTitle): \($0.message)" }
            .joined(separator: "\n")
    }
}

struct SidebarView: View {
    @Environment(\.appFontPointSize) private var fontPointSize
    let store: SessionStore
    let detachPath: String
    @Binding var selectedID: String?
    @ObservedObject var navigation: MainNavigation
    @State private var showNewSession = false
    @State private var isSelectingFinished = false
    @State private var selectedFinishedIDs: Set<String> = []
    @State private var confirmFinishedDelete = false
    @State private var isDeletingFinished = false
    @State private var finishedDeleteError: String?

    private func sessions(in section: SessionSection) -> [Session] {
        store.sessions.filter { $0.section == section }
    }

    private var deletableFinishedSessions: [Session] {
        sessions(in: .finished).filter(\.canDeleteFromFinishedList)
    }

    private var selectedFinishedSessions: [Session] {
        deletableFinishedSessions.filter { selectedFinishedIDs.contains($0.id) }
    }

    var body: some View {
        List(selection: $selectedID) {
            ForEach(SessionSection.allCases, id: \.self) { section in
                let items = sessions(in: section)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { session in
                            sessionRow(session)
                        }
                    } header: {
                        sectionHeader(section, count: items.count)
                    }
                }
            }
        }
        .overlay {
            if store.sessions.isEmpty && store.state == .ok {
                ContentUnavailableView {
                    Label {
                        Text(L10n.string("No sessions yet"))
                    } icon: {
                        Image(systemName: "terminal").foregroundStyle(Brand.gradient)
                    }
                } description: {
                    Text(L10n.string("Launch Codex or Claude in Terminal"))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if isSelectingFinished {
                    finishedSelectionBar
                    Divider()
                }
                StatusBar(store: store)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewSession = true
                } label: {
                    Label(L10n.string("New session"), systemImage: "plus")
                        .foregroundStyle(Brand.indigo)
                }
                .accessibilityIdentifier("new-session-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    if AppSettings.uiE2E != nil {
                        UIE2EGeometryProbe(identifier: "new-session-button")
                    }
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(detachPath: detachPath)
        }
        .confirmationDialog(
            L10n.format(
                "Delete selected sessions (%d)?",
                selectedFinishedSessions.count),
            isPresented: $confirmFinishedDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Delete"), role: .destructive) {
                deleteSelectedFinishedSessions()
            }
        } message: {
            Text(L10n.string(
                "The selected Detach state directories and checkpoints will be permanently deleted. Provider transcripts in ~/.claude and ~/.codex will not be affected."))
        }
        .alert(
            L10n.string("Could not delete some sessions"),
            isPresented: .init(
                get: { finishedDeleteError != nil },
                set: { if !$0 { finishedDeleteError = nil } })
        ) {
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(finishedDeleteError ?? "")
        }
        // The menu can request a sheet before reopening the main window, so
        // consume an already-pending request on the sidebar's first render.
        .onChange(of: navigation.requestsNewSession, initial: true) { _, requested in
            guard requested else { return }
            showNewSession = true
            navigation.requestsNewSession = false
        }
        .onChange(of: deletableFinishedSessions.map(\.id)) { _, currentIDs in
            selectedFinishedIDs.formIntersection(currentIDs)
            if currentIDs.isEmpty && !isDeletingFinished {
                isSelectingFinished = false
            }
        }
        .navigationSplitViewColumnWidth(
            min: max(230, fontPointSize * 18),
            ideal: max(260, fontPointSize * 20))
    }

    @ViewBuilder
    private func sectionHeader(_ section: SessionSection, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(L10n.format("%@ · %d", section.displayName, count))
                .foregroundStyle(
                    section == .answerReady ? Color.orange : Color.secondary)
            Spacer(minLength: 0)
            if section == .finished && !deletableFinishedSessions.isEmpty {
                Button(L10n.string(isSelectingFinished ? "Done" : "Select")) {
                    if isSelectingFinished {
                        selectedFinishedIDs.removeAll()
                    }
                    isSelectingFinished.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.indigo)
                .disabled(isDeletingFinished)
                .accessibilityIdentifier("finished-selection-mode-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    if AppSettings.uiE2E != nil {
                        UIE2EGeometryProbe(
                            identifier: "finished-selection-mode-button",
                            semanticLabel: isSelectingFinished ? "Done" : "Select",
                            semanticRole: .button,
                            semanticEnabled: !isDeletingFinished)
                    }
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
                .padding(.trailing, 12)
            }
        }
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        .background {
            if AppSettings.uiE2E != nil && section == .finished {
                UIE2EGeometryProbe(identifier: "finished-section-header")
            }
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        if isSelectingFinished && session.canDeleteFromFinishedList {
            HStack(spacing: 8) {
                Button {
                    if selectedFinishedIDs.contains(session.id) {
                        selectedFinishedIDs.remove(session.id)
                    } else {
                        selectedFinishedIDs.insert(session.id)
                    }
                } label: {
                    Image(systemName: selectedFinishedIDs.contains(session.id)
                          ? "checkmark.square.fill" : "square")
                        .foregroundStyle(
                            selectedFinishedIDs.contains(session.id)
                                ? Brand.indigo : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDeletingFinished)
                .accessibilityLabel(L10n.format(
                    selectedFinishedIDs.contains(session.id)
                        ? "Deselect %@ from deletion" : "Select %@ for deletion",
                    session.displayTitle))
                .accessibilityIdentifier("finished-selection-\(session.id)")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    if AppSettings.uiE2E != nil {
                        UIE2EGeometryProbe(
                            identifier: "finished-selection-\(session.id)",
                            semanticLabel: selectedFinishedIDs.contains(session.id)
                                ? "Deselect \(session.displayTitle) from deletion"
                                : "Select \(session.displayTitle) for deletion",
                            semanticRole: .button,
                            semanticEnabled: !isDeletingFinished)
                    }
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
                SessionRow(session: session)
            }
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background { uiE2EGeometryProbe(for: session) }
#endif
// quality-coverage:end ui-e2e-instrumentation
            .tag(session.id)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(session.displayTitle)
            .accessibilityIdentifier("session-row-\(session.id)")
            .listRowBackground(
                session.isWaitingForUser ? Color.orange.opacity(0.10) : nil)
        } else {
            Button {
                selectedID = session.id
            } label: {
                SessionRow(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background { uiE2EGeometryProbe(for: session) }
#endif
// quality-coverage:end ui-e2e-instrumentation
            .tag(session.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(session.displayTitle)
            .accessibilityIdentifier("session-row-\(session.id)")
            .listRowBackground(
                session.isWaitingForUser ? Color.orange.opacity(0.10) : nil)
        }
    }

    private var finishedSelectionBar: some View {
        HStack(spacing: 8) {
            Button(L10n.string(
                selectedFinishedIDs.count == deletableFinishedSessions.count
                    ? "Clear selection" : "Select all")) {
                if selectedFinishedIDs.count == deletableFinishedSessions.count {
                    selectedFinishedIDs.removeAll()
                } else {
                    selectedFinishedIDs = Set(deletableFinishedSessions.map(\.id))
                }
            }
            .buttonStyle(.borderless)
            .disabled(isDeletingFinished || deletableFinishedSessions.isEmpty)
            .accessibilityIdentifier("finished-select-all-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background {
                if AppSettings.uiE2E != nil {
                    UIE2EGeometryProbe(
                        identifier: "finished-select-all-button",
                        semanticLabel: selectedFinishedIDs.count
                            == deletableFinishedSessions.count
                            ? "Clear selection" : "Select all",
                        semanticRole: .button,
                        semanticEnabled: !isDeletingFinished
                            && !deletableFinishedSessions.isEmpty)
                }
            }
#endif
// quality-coverage:end ui-e2e-instrumentation

            Spacer()

            if isDeletingFinished {
                ProgressView().controlSize(.small)
            }
            Button(role: .destructive) {
                confirmFinishedDelete = true
            } label: {
                Label(
                    L10n.format("Delete %d", selectedFinishedSessions.count),
                    systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isDeletingFinished || selectedFinishedSessions.isEmpty)
            .accessibilityIdentifier("finished-delete-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background {
                if AppSettings.uiE2E != nil {
                    UIE2EGeometryProbe(
                        identifier: "finished-delete-button",
                        semanticLabel: "Delete \(selectedFinishedSessions.count)",
                        semanticRole: .button,
                        semanticEnabled: !isDeletingFinished
                            && !selectedFinishedSessions.isEmpty)
                }
            }
#endif
// quality-coverage:end ui-e2e-instrumentation
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func deleteSelectedFinishedSessions() {
        let selected = selectedFinishedSessions
        guard !selected.isEmpty else { return }
        isDeletingFinished = true
        Task { @MainActor in
            let failures = await store.deleteFinished(selected)
            selectedFinishedIDs = Set(failures.map(\.sessionName))
            isDeletingFinished = false
            if failures.isEmpty {
                isSelectingFinished = false
            } else {
                finishedDeleteError = FinishedDeletionPresentation.errorMessage(
                    for: failures)
            }
        }
    }

// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
    @ViewBuilder
    private func uiE2EGeometryProbe(for session: Session) -> some View {
        if AppSettings.uiE2E != nil {
            UIE2EGeometryProbe(identifier: "session-row-\(session.id)")
        }
    }
#endif
// quality-coverage:end ui-e2e-instrumentation
}

struct SessionRow: View {
    let session: Session

    private var dotColor: Color {
        SessionIdentity.statusColor(for: session)
    }

    private var isCustomName: Bool {
        guard session.displayName == nil else { return false }
        // Default names end with the 8-hex project-dir digest; custom ones don't.
        return session.name.range(
            of: "-[0-9a-f]{8}$",
            options: .regularExpression) == nil
    }

    private var subtitle: String {
        var parts: [String] = []
        if isCustomName { parts.append(session.name) }
        parts.append(session.displayStatus)
        if let exit = session.exitStatus { parts.append(L10n.format("exit %d", exit)) }
        if let created = session.createdAt {
            parts.append(created.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            if session.isWaitingForUser {
                Capsule(style: .continuous)
                    .fill(Color.orange)
                    .frame(width: 3, height: 30)
                    .accessibilityHidden(true)
            }
            if let sessionColor = session.sessionColor {
                Capsule(style: .continuous)
                    .fill(SessionIdentity.color(sessionColor).opacity(
                        SessionIdentity.emphasis(for: session.effectiveStatus)))
                    .frame(width: 4, height: 34)
                    .help(L10n.format("Session color: %@", sessionColor.hex))
                    .accessibilityHidden(true)
            }
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle).appFont(.body, weight: .semibold).lineLimit(1)
                    Text(session.provider.rawValue)
                        .appFont(.caption2)
                        .foregroundStyle(Brand.tint(for: session.provider))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Brand.tint(for: session.provider).opacity(0.35)))
                }
                Text(subtitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBar: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 6) {
            switch store.state {
            case .ok:
                if let updated = store.lastUpdated {
                    Text(L10n.format(
                        "Updated %@",
                        updated.formatted(date: .omitted, time: .standard)))
                }
            case .incompatible:
                Label(L10n.string("Incompatible CLI version—update detach"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .cliMissing:
                Label(L10n.string("detach is unavailable"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
// quality-coverage:begin ui-e2e-instrumentation
                    .accessibilityIdentifier("session-status-error")
#if !DEBUG
                    .background {
                        if AppSettings.uiE2E != nil {
                            UIE2EGeometryProbe(
                                identifier: "session-status-error",
                                semanticLabel: message,
                                semanticRole: .staticText,
                                semanticEnabled: false)
                        }
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
            Spacer()
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // No backing material: the sidebar List already ends above this inset,
        // and an opaque bar reads as a stray strip over the sidebar glass.
    }
}
