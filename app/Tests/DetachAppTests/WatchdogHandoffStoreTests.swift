import Darwin
import Foundation
import XCTest
@testable import DetachApp

@_silgen_name("flock")
private func watchdogTestFileLock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

final class WatchdogHandoffStoreTests: XCTestCase {
    func testRoundTripsDurableTransactionAcrossStoreInstances() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let transaction = WatchdogHandoffTransaction(
            phase: .unregisterSubmitted,
            targetDigest: "digest-current")

        try fixture.store.save(transaction)

        let relaunchedStore = FileWatchdogHandoffStore(
            fileURL: fixture.fileURL,
            expectedOwner: geteuid())
        XCTAssertEqual(try relaunchedStore.load(), transaction)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)

        try relaunchedStore.clear()
        XCTAssertNil(try fixture.store.load())
    }

    func testRejectsInvalidRegisteringTransaction() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let invalid = WatchdogHandoffTransaction(
            phase: .registering,
            targetDigest: nil)

        XCTAssertThrowsError(try fixture.store.save(invalid))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.fileURL.path))
    }

    func testExclusiveTransactionLockRejectsOverlap() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let otherStore = FileWatchdogHandoffStore(
            fileURL: fixture.fileURL,
            expectedOwner: geteuid())
        var firstLock: (any WatchdogHandoffLocking)? = try fixture.store
            .acquireTransactionLock()

        XCTAssertThrowsError(try otherStore.acquireTransactionLock()) { error in
            guard case WatchdogHandoffStoreError.transactionBusy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        withExtendedLifetime(firstLock) {}
        firstLock = nil
        let laterLock = try otherStore.acquireTransactionLock()
        withExtendedLifetime(laterLock) {}
    }

    func testLifetimeBarrierReportsBusyThenReleased() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let lifetimeURL = fixture.root.appendingPathComponent("lifetime.lock")
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(
            lifetimeURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(watchdogTestFileLock(descriptor, LOCK_EX | LOCK_NB), 0)
        let barrier = WatchdogLifetimeBarrier(
            fileURL: lifetimeURL,
            expectedOwner: geteuid())

        XCTAssertEqual(try barrier.status(), .busy)

        XCTAssertEqual(watchdogTestFileLock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(try barrier.status(), .released)
    }

    func testLifetimePathMatchesWatchdogStateRootPrecedence() {
        let fallbackHome = URL(fileURLWithPath: "/fallback-home", isDirectory: true)

        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["DETACH_POWER_STATE_ROOT": "/power-override"],
                homeDirectory: fallbackHome).path,
            "/power-override/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["DETACH_STATE_ROOT": "/state-override"],
                homeDirectory: fallbackHome).path,
            "/state-override/power/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["XDG_STATE_HOME": "/xdg-state"],
                homeDirectory: fallbackHome).path,
            "/xdg-state/detach/power/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["HOME": "/environment-home"],
                homeDirectory: fallbackHome).path,
            "/environment-home/.local/state/detach/power/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: [:],
                homeDirectory: fallbackHome).path,
            "/fallback-home/.local/state/detach/power/watchdog-lifetime.lock")
    }

    func testProductionJournalDoesNotReusePreReleaseWatchdogState() {
        XCTAssertEqual(
            FileWatchdogHandoffStore.defaultFileURL.lastPathComponent,
            "power-watchdog-handoff.json")
    }

    func testRejectsOversizedJournalBeforeDecoding() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try writeJournal(
            Data(repeating: 0, count: FileWatchdogHandoffStore.maximumBytes + 1),
            fixture: fixture)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            guard case WatchdogHandoffStoreError.stateTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsInvalidPersistedTransaction() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let invalid = WatchdogHandoffTransaction(
            phase: .registering,
            targetDigest: nil)
        try writeJournal(
            try JSONEncoder().encode(invalid),
            fixture: fixture)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            guard case WatchdogHandoffStoreError.invalidState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsJournalReadableByOtherUsers() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let transaction = WatchdogHandoffTransaction(
            phase: .removed,
            targetDigest: "digest")
        try writeJournal(
            try JSONEncoder().encode(transaction),
            fixture: fixture,
            permissions: 0o644)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            guard case WatchdogHandoffStoreError.insecurePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSymlinkJournalWithoutFollowingIt() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL,
            withDestinationURL: target)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            guard case let WatchdogHandoffStoreError.fileSystem(operation, _) =
                    error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "open")
        }
    }

    func testStoreErrorsHaveActionableDescriptions() {
        let cases: [(WatchdogHandoffStoreError, String)] = [
            (.insecurePath,
             "The watchdog handoff journal has an insecure path."),
            (.stateTooLarge,
             "The watchdog handoff journal is unexpectedly large."),
            (.invalidState,
             "The watchdog handoff journal is invalid."),
            (.transactionBusy,
             "Another Detach process is already updating the watchdog."),
            (.fileSystem(operation: "read", code: EIO),
             "Could not read the watchdog handoff journal (errno \(EIO))."),
        ]

        for (error, description) in cases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testClearIsIdempotentBeforeJournalDirectoryExists() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }

        try fixture.store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testRejectsNonDirectoryJournalParent() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let parent = fixture.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: parent)
        let transaction = WatchdogHandoffTransaction(
            phase: .removed,
            targetDigest: "digest")

        XCTAssertThrowsError(try fixture.store.save(transaction)) { error in
            guard case WatchdogHandoffStoreError.insecurePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSymlinkTransactionLock() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let directory = fixture.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let target = fixture.root.appendingPathComponent("lock-target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(
                "power-watchdog-handoff.lock"),
            withDestinationURL: target)

        XCTAssertThrowsError(try fixture.store.acquireTransactionLock()) {
            error in
            guard case let WatchdogHandoffStoreError.fileSystem(operation, _) =
                    error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "open transaction lock")
        }
    }

    func testRejectsOversizedSerializedTransactionBeforeWriting() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let transaction = WatchdogHandoffTransaction(
            phase: .removed,
            targetDigest: String(
                repeating: "x",
                count: FileWatchdogHandoffStore.maximumBytes))

        XCTAssertThrowsError(try fixture.store.save(transaction)) { error in
            guard case WatchdogHandoffStoreError.stateTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLifetimeBarrierReportsMissingAndRejectsInsecureFile() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let lifetimeURL = fixture.root.appendingPathComponent("lifetime.lock")
        let barrier = WatchdogLifetimeBarrier(
            fileURL: lifetimeURL,
            expectedOwner: geteuid())

        XCTAssertEqual(try barrier.status(), .missing)

        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true)
        try Data().write(to: lifetimeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: lifetimeURL.path)
        XCTAssertThrowsError(try barrier.status()) { error in
            guard case WatchdogHandoffStoreError.insecurePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDefaultLifetimeBarrierUsesWatchdogLockName() {
        XCTAssertEqual(
            WatchdogLifetimeBarrier.defaultFileURL.lastPathComponent,
            "watchdog-lifetime.lock")
    }

    private func writeJournal(
        _ data: Data,
        fixture: WatchdogStoreFixture,
        permissions: Int = 0o600
    ) throws {
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fixture.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: fixture.fileURL.path)
    }

    private func makeFixture() -> WatchdogStoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WatchdogHandoffStoreTests.\(UUID().uuidString)",
                isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Detach", isDirectory: true)
            .appendingPathComponent("watchdog-handoff.json")
        return WatchdogStoreFixture(
            root: root,
            fileURL: fileURL,
            store: FileWatchdogHandoffStore(
                fileURL: fileURL,
                expectedOwner: geteuid()))
    }
}

private struct WatchdogStoreFixture {
    let root: URL
    let fileURL: URL
    let store: FileWatchdogHandoffStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
