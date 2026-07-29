import Foundation

public func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public enum SessionNameValidator {
    public static func normalizedCustomName(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isValidInput(_ input: String, provider: Provider) -> Bool {
        guard let name = normalizedCustomName(input) else { return true }
        return isValidCustomName(name, provider: provider)
    }

    public static func isValidCustomName(_ name: String, provider: Provider) -> Bool {
        let prefix = "detach-\(provider.rawValue)-"
        let shortName = name.hasPrefix(prefix)
            ? String(name.dropFirst(prefix.count))
            : name
        let bytes = Array(shortName.utf8)
        guard (1...48).contains(bytes.count),
              let first = bytes.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIILetterOrDigit($0) || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
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
