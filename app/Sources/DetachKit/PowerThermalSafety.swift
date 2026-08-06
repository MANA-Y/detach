import Foundation

/// Public macOS thermal pressure exposed without temperatures or private APIs.
public enum PowerThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    public var requiresSleepSafety: Bool {
        self == .serious || self == .critical
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PowerThermalState(rawValue: raw) ?? .unknown
    }

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

public protocol PowerThermalStateReading: Sendable {
    func thermalState() -> PowerThermalState
}

public struct ProcessInfoPowerThermalStateReader: PowerThermalStateReading {
    public init() {}

    public func thermalState() -> PowerThermalState {
        PowerThermalState(ProcessInfo.processInfo.thermalState)
    }
}

/// A deterministic default for injected policy tests and legacy callers.
public struct NominalPowerThermalStateReader: PowerThermalStateReading {
    public init() {}
    public func thermalState() -> PowerThermalState { .nominal }
}

/// Durable hysteresis state. Unsafe pressure activates immediately; cooling
/// must remain nominal or fair for the complete cooldown before protection may
/// be enabled again. An unknown reading never clears an active safety latch.
public struct PowerThermalSafetyLatch: Equatable, Codable, Sendable {
    public static let defaultCooldown: TimeInterval = 30

    public private(set) var isActive: Bool
    public private(set) var coolingSince: Date?

    public init(isActive: Bool = false, coolingSince: Date? = nil) {
        self.isActive = isActive
        self.coolingSince = isActive ? coolingSince : nil
    }

    @discardableResult
    public mutating func observe(
        _ state: PowerThermalState,
        now: Date,
        cooldown: TimeInterval = PowerThermalSafetyLatch.defaultCooldown
    ) -> Bool {
        let previous = self
        switch state {
        case .serious, .critical:
            isActive = true
            coolingSince = nil
        case .nominal, .fair:
            guard isActive else {
                coolingSince = nil
                return previous != self
            }
            if let coolingSince {
                if now.timeIntervalSince(coolingSince) >= max(0, cooldown) {
                    isActive = false
                    self.coolingSince = nil
                }
            } else {
                coolingSince = now
            }
        case .unknown:
            if isActive { coolingSince = nil }
        }
        return previous != self
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isActive = try container.decodeIfPresent(
            Bool.self, forKey: .isActive) ?? false
        coolingSince = isActive ? try container.decodeIfPresent(
            Date.self, forKey: .coolingSince) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case isActive = "is_active"
        case coolingSince = "cooling_since"
    }
}

/// Runs an operation while observing the documented ProcessInfo notification.
public protocol PowerThermalStateWatching: Sendable {
    func run(
        onStateChange: @escaping @Sendable (PowerThermalState) -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult
}

public final class ProcessInfoPowerThermalStateWatcher:
    PowerThermalStateWatching, @unchecked Sendable
{
    private let processInfo: ProcessInfo
    private let notificationCenter: NotificationCenter

    public init(
        processInfo: ProcessInfo = .processInfo,
        notificationCenter: NotificationCenter = .default
    ) {
        self.processInfo = processInfo
        self.notificationCenter = notificationCenter
    }

    public func run(
        onStateChange: @escaping @Sendable (PowerThermalState) -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult {
        let observer = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [processInfo] _ in
            onStateChange(PowerThermalState(processInfo.thermalState))
        }
        onStateChange(PowerThermalState(processInfo.thermalState))
        defer {
            notificationCenter.removeObserver(observer)
        }
        return try operation()
    }
}
