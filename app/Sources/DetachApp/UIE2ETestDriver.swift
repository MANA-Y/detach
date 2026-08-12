import AppKit
import Darwin
import Foundation

/// A narrowly gated, same-process accessibility driver for the packaged-app
/// smoke test. Keeping traversal and actions inside the tested process avoids
/// a second automation executable and its independent identity. This path is
/// dormant in production and becomes reachable only in a stripped,
/// background-only app copy whose identity and every data path are validated
/// by `UIE2EConfiguration`.
@MainActor
enum UIE2ETestDriver {
    private struct Report: Codable, Sendable {
        let schema: Int
        let passed: Bool
        let checks: [String]
        let error: String?
        let accessibilityTree: [ElementSnapshot]
    }

    private struct ElementSnapshot: Codable, Sendable {
        let role: String
        let identifier: String?
        let label: String?
        let value: String?
        let frame: String
        let enabled: Bool
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var started = false

    static func startIfRequested() {
        guard let configuration = AppSettings.uiE2E, !started else { return }
        started = true
        Task { @MainActor in
            let report = await runScenario(configuration: configuration)
            try? write(report, to: configuration.result)
            NSApp.terminate(nil)
            // A SwiftUI sheet can defer normal termination even after it is
            // dismissed. The validated test copy owns no durable state, so keep
            // the harness bounded after the atomic report is safely on disk.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                _exit(EXIT_SUCCESS)
            }
        }
    }

    private static func runScenario(
        configuration: UIE2EConfiguration
    ) async -> Report {
        var checks: [String] = []
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let previousActivationPolicy = NSApp.activationPolicy()
        do {
            trace("driver started")
            guard !NSApp.isActive else {
                throw Failure(message: "background test app stole keyboard focus")
            }
            checks.append("background-app-starts-without-focus")
            guard let mainWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "main"
            }) else {
                throw Failure(message: "main test window is missing")
            }
            guard NSApp.setActivationPolicy(.regular) else {
                throw Failure(message: "cannot enable test app activation")
            }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            try await waitUntil("test app activation") {
                NSApp.isActive && mainWindow.isKeyWindow
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            trace("test app activated")

            let dashboard = try await element(role: .splitGroup)
            try requireGeometry(dashboard, name: "dashboard")
            checks.append("dashboard-accessible")
            trace("dashboard accessible")

            let completedID = "detach-claude-ui-completed"
            let completedRow = try await element(
                identifier: "session-row-\(completedID)")
            try requireSemanticControl(completedRow, name: "completed session row")
            let completedDetail = try await clickUntilElement(
                completedRow,
                name: "completed session row",
                resultIdentifier: "session-detail-\(completedID)")
            try requireGeometry(completedDetail, name: "completed session detail")
            let deleteButton = try await element(identifier: "session-action-delete")
            try requireSemanticControl(deleteButton, name: "delete action")
            checks.append("sidebar-selects-completed-session")
            trace("completed session selected")

            try await click(deleteButton, name: "delete action")
            let confirmDelete = try await sheetButton(
                label: "Delete")
            try requireSemanticControl(confirmDelete, name: "delete confirmation")
            try await click(confirmDelete, name: "delete confirmation")
            try await waitUntil("fake CLI records delete action") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains(
                    "claude delete --force \(completedID)") == true
            }
            checks.append("safe-delete-reaches-fake-cli")
            trace("delete reached fake CLI")
            try await waitUntil("delete confirmation dismissal") {
                NSApp.windows.allSatisfy(\.sheets.isEmpty)
            }
            try await Task.sleep(nanoseconds: 200_000_000)

            let runningID = "detach-codex-ui-running"
            let runningRow = try await element(
                identifier: "session-row-\(runningID)")
            try requireSemanticControl(runningRow, name: "running session row")
            _ = try await clickUntilElement(
                runningRow,
                name: "running session row",
                resultIdentifier: "session-detail-\(runningID)")
            let stopButton = try await element(identifier: "session-action-stop")
            try requireSemanticControl(stopButton, name: "stop action")
            try await clickUntil(
                stopButton,
                name: "stop action",
                outcome: "fake CLI records stop action") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains("codex stop \(runningID)") == true
            }
            checks.append("safe-action-reaches-fake-cli")
            trace("stop reached fake CLI")

            let newSession = try await element(identifier: "new-session-button")
            try requireSemanticControl(newSession, name: "new session action")
            try await click(newSession, name: "new session action")
            _ = try await measuredFrame(
                identifier: "new-session-sheet", name: "new session sheet")
            let launchFrame = try await measuredFrame(
                identifier: "new-session-launch", name: "new session launch")
            try await click(frame: launchFrame, name: "disabled new session launch")
            try await Task.sleep(nanoseconds: 200_000_000)
            guard NSApp.windows.contains(where: { !$0.sheets.isEmpty }) else {
                throw Failure(message: "new-session launch is active without a project")
            }
            let cancelFrame = try await measuredFrame(
                identifier: "new-session-cancel", name: "new session cancel")
            try await click(frame: cancelFrame, name: "new session cancel")
            try await waitUntil("new-session sheet closes") {
                NSApp.windows.allSatisfy(\.sheets.isEmpty)
            }
            checks.append("new-session-sheet-semantics")
            trace("new-session sheet closed")

            try Data("empty\n".utf8).write(
                to: configuration.fixtureState, options: .atomic)
            let emptyGuide = try await element(identifier: "empty-sessions-guide")
            try requireGeometry(emptyGuide, name: "empty sessions guide")
            checks.append("empty-dashboard-state")
            trace("empty dashboard visible")

            try await restoreFocus(
                to: previousFrontmost, policy: previousActivationPolicy)
            checks.append("installed-app-focus-restored")
            trace("previous application focus restored")
            return Report(
                schema: 1,
                passed: true,
                checks: checks,
                error: nil,
                accessibilityTree: snapshots())
        } catch {
            try? await restoreFocus(
                to: previousFrontmost, policy: previousActivationPolicy)
            return Report(
                schema: 1,
                passed: false,
                checks: checks,
                error: error.localizedDescription,
                accessibilityTree: snapshots())
        }
    }

    private static func trace(_ message: String) {
        FileHandle.standardError.write(Data("UI e2e: \(message)\n".utf8))
    }

    private static func restoreFocus(
        to application: NSRunningApplication?,
        policy: NSApplication.ActivationPolicy
    ) async throws {
        if let application, !application.isTerminated {
            application.activate()
        } else {
            NSApp.hide(nil)
        }
        try await waitUntil("previous application focus restoration") {
            !NSApp.isActive
        }
        guard NSApp.setActivationPolicy(policy) else {
            throw Failure(message: "cannot restore test app activation policy")
        }
    }

    private static func element(identifier: String) async throws
        -> any NSAccessibilityProtocol
    {
        var result: (any NSAccessibilityProtocol)?
        try await waitUntil("accessibility element \(identifier)") {
            result = find(identifier: identifier)
            return result != nil
        }
        return result!
    }

    private static func element(role: NSAccessibility.Role) async throws
        -> any NSAccessibilityProtocol
    {
        var result: (any NSAccessibilityProtocol)?
        try await waitUntil("accessibility role \(role.rawValue)") {
            result = elements().first { roleOf($0) == role }
            return result != nil
        }
        return result!
    }

    private static func sheetButton(label: String) async throws
        -> any NSAccessibilityProtocol
    {
        var result: (any NSAccessibilityProtocol)?
        try await waitUntil("sheet button \(label)") {
            let sheetFrames = NSApp.windows.flatMap(\.sheets).map(\.frame)
            result = elements().first { element in
                roleOf(element) == .button
                    && Self.label(element) == label
                    && sheetFrames.contains(where: { $0.contains(
                        CGPoint(x: frame(element).midX, y: frame(element).midY)) })
            }
            return result != nil
        }
        return result!
    }

    private static func waitUntil(
        _ description: String,
        attempts: Int = 100,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure(message: "timed out waiting for \(description)")
    }

    private static func requireGeometry(
        _ element: any NSAccessibilityProtocol,
        name: String
    ) throws {
        let frame = frame(element)
        guard frame.width > 0, frame.height > 0 else {
            throw Failure(message: "\(name) has empty accessibility geometry")
        }
    }

    private static func requireSemanticControl(
        _ element: any NSAccessibilityProtocol,
        name: String
    ) throws {
        try requireGeometry(element, name: name)
        guard isEnabled(element) else {
            throw Failure(message: "\(name) is disabled")
        }
        let label = label(element)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard label?.isEmpty == false else {
            throw Failure(message: "\(name) has no accessibility label")
        }
    }

    private static func click(
        _ element: any NSAccessibilityProtocol,
        name: String
    ) async throws {
        var targetFrame = frame(element)
        if let identifier = identifierOf(element),
           usesMeasuredGeometry(identifier) {
            try await waitUntil("real control geometry for \(name)") {
                guard let measured = UIE2EGeometryRegistry.frame(for: identifier) else {
                    return false
                }
                targetFrame = measured
                return !measured.isEmpty
            }
        }
        try await click(frame: targetFrame, name: name)
    }

    private static func usesMeasuredGeometry(_ identifier: String) -> Bool {
        identifier == "new-session-button"
            || identifier.hasPrefix("session-row-")
            || identifier.hasPrefix("session-action-")
    }

    private static func clickUntilElement(
        _ control: any NSAccessibilityProtocol,
        name: String,
        resultIdentifier: String
    ) async throws -> any NSAccessibilityProtocol {
        var result: (any NSAccessibilityProtocol)?
        for _ in 0..<3 {
            try await click(control, name: name)
            do {
                try await waitUntil(
                    "accessibility element \(resultIdentifier)", attempts: 10
                ) {
                    result = find(identifier: resultIdentifier)
                    return result != nil
                }
                return result!
            } catch {
                continue
            }
        }
        throw Failure(message: "\(name) did not produce \(resultIdentifier)")
    }

    private static func clickUntil(
        _ control: any NSAccessibilityProtocol,
        name: String,
        outcome: String,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<3 {
            try await click(control, name: name)
            do {
                try await waitUntil(outcome, attempts: 10, condition: condition)
                return
            } catch {
                continue
            }
        }
        throw Failure(message: "\(name) did not produce \(outcome)")
    }

    private static func measuredFrame(
        identifier: String,
        name: String
    ) async throws -> CGRect {
        var result: CGRect?
        try await waitUntil("real control geometry for \(name)") {
            result = UIE2EGeometryRegistry.frame(for: identifier)
            return result?.isEmpty == false
        }
        if identifier.hasPrefix("new-session-"),
           let sheet = NSApp.windows.flatMap(\.sheets).first,
           let localFrame = result,
           !sheet.frame.contains(CGPoint(
               x: localFrame.midX, y: localFrame.midY)) {
            result = CGRect(
                x: sheet.frame.minX + localFrame.minX,
                y: sheet.frame.minY + localFrame.minY,
                width: localFrame.width,
                height: localFrame.height)
        }
        trace("measured \(name): \(result!)")
        return result!
    }

    private static func click(frame targetFrame: CGRect, name: String) async throws {
        let screenPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let candidateWindows = NSApp.windows.flatMap(\.sheets) + NSApp.windows
        guard let window = candidateWindows.first(where: { candidate in
            candidate.frame.contains(screenPoint)
        }) else {
            throw Failure(message: "\(name) is outside every visible test window")
        }
        trace("clicking \(name) at \(screenPoint.x),\(screenPoint.y)")
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if let contentView = window.contentView {
            let contentPoint = contentView.convert(windowPoint, from: nil)
            var view = contentView.hitTest(contentPoint)
            var names: [String] = []
            while let current = view {
                names.append(String(describing: type(of: current)))
                view = current.superview
            }
            trace("hit chain for \(name): \(names.joined(separator: " > "))")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func find(identifier: String) -> (any NSAccessibilityProtocol)? {
        elements().first { identifierOf($0) == identifier }
    }

    private static func elements() -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var roots: [any NSAccessibilityProtocol] = []
        let mainWindows = NSApp.windows.filter {
            $0.identifier?.rawValue == "main" || $0.title == "Detach"
        }
        for window in mainWindows {
            roots.append(window)
            if let contentView = window.contentView { roots.append(contentView) }
        }
        roots.append(contentsOf: mainWindows.flatMap(\.sheets).map { $0 })
        var queue = roots.map { ($0, 0) }
        var visited: Set<ObjectIdentifier> = []
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            let identifier = ObjectIdentifier(element as AnyObject)
            guard visited.insert(identifier).inserted else { continue }
            result.append(element)
            guard depth < 20 else { continue }
            var children = (element.accessibilityWindows() ?? [])
                + (element.accessibilityChildren() ?? [])
                + (element.accessibilityVisibleChildren() ?? [])
                + (element.accessibilityContents() ?? [])
                + (element.accessibilityRows() ?? [])
                + (element.accessibilityVisibleRows() ?? [])
            if let view = element as? NSView {
                children.append(contentsOf: view.subviews)
            }
            if let window = element as? NSWindow,
               let contentView = window.contentView {
                children.append(contentView)
            }
            for child in children.compactMap({ $0 as? any NSAccessibilityProtocol }) {
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    private static func snapshots() -> [ElementSnapshot] {
        elements().map { element in
            let elementFrame = frame(element)
            return ElementSnapshot(
                role: roleOf(element)?.rawValue ?? "",
                identifier: identifierOf(element),
                label: label(element),
                value: value(element)
                    .map { String(describing: $0) },
                frame: "\(elementFrame.origin.x),\(elementFrame.origin.y),\(elementFrame.width),\(elementFrame.height)",
                enabled: isEnabled(element))
        }
    }

    private static func isEnabled(_ element: any NSAccessibilityProtocol) -> Bool {
        element.isAccessibilityEnabled()
    }

    private static func frame(_ element: any NSAccessibilityProtocol) -> CGRect {
        element.accessibilityFrame()
    }

    private static func roleOf(
        _ element: any NSAccessibilityProtocol
    ) -> NSAccessibility.Role? {
        element.accessibilityRole()
    }

    private static func identifierOf(
        _ element: any NSAccessibilityProtocol
    ) -> String? {
        element.accessibilityIdentifier()
    }

    private static func label(
        _ element: any NSAccessibilityProtocol
    ) -> String? {
        element.accessibilityLabel()
    }

    private static func value(
        _ element: any NSAccessibilityProtocol
    ) -> Any? {
        element.accessibilityValue()
    }

    private static func write(_ report: Report, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
