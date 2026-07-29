import Foundation

public func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public enum SessionNameValidator {
    public static func normalizedCustomName(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isValidInput(_ input: String, provider _: Provider) -> Bool {
        guard let name = normalizedCustomName(input) else { return true }
        return isValidCustomName(name)
    }

    public static func isValidCustomName(_ name: String, provider _: Provider? = nil) -> Bool {
        guard (1...100).contains(name.utf8.count),
              name.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
            return false
        }
        return name.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

public enum TerminalCommand {
    public static func attach(detachPath: String, session: Session) -> String {
        "exec \(shellQuoted(detachPath)) \(session.provider.rawValue) attach \(shellQuoted(session.sessionName))"
    }

    public static func resume(detachPath: String, session: Session) -> String? {
        guard let uuid = session.agentSessionId else { return nil }
        return "exec \(shellQuoted(detachPath)) resume \(shellQuoted(uuid))"
    }

    public static func recover(detachPath: String, session: Session) -> String {
        "exec \(shellQuoted(detachPath)) \(session.provider.rawValue) recover \(shellQuoted(session.sessionName))"
    }

    public static func start(detachPath: String, provider: Provider, projectDir: String,
                             name: String?, prompt: String?) -> String {
        var command = "cd \(shellQuoted(projectDir)) && exec \(shellQuoted(detachPath)) \(provider.rawValue)"
        if let name, !name.isEmpty {
            command += " --name \(shellQuoted(name))"
        }
        if let prompt, !prompt.isEmpty {
            command += " -- \(shellQuoted(prompt))"
        }
        return command
    }
}
