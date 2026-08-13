import Darwin
import Foundation
import XCTest
@testable import DetachApp

final class PowerHelperHandoffStoreTests: XCTestCase {
    func testRoundTripsFsyncedTransactionAndClearsIt() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transaction = PowerHelperHandoffTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            targetDigest: "digest-current",
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001",
            lifetimeBarrierExpected: true)

        try fixture.store.save(transaction)

        XCTAssertEqual(try fixture.store.load(), transaction)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)

        try fixture.store.clear()

        XCTAssertNil(try fixture.store.load())
    }

    func testRejectsSymlinkJournal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL, withDestinationURL: target)

        XCTAssertThrowsError(try fixture.store.load())
    }

    func testRejectsInvalidTransactionBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let invalid = PowerHelperHandoffTransaction(
            phase: .registering,
            goal: .install,
            targetDigest: nil,
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001")

        XCTAssertThrowsError(try fixture.store.save(invalid))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.fileURL.path))
    }

    func testExclusiveTransactionLockRejectsOverlappingStoreUser() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let otherStore = FilePowerHelperHandoffStore(
            fileURL: fixture.fileURL,
            expectedOwner: geteuid())
        var firstLock: (any PowerHelperHandoffLocking)? = try fixture.store
            .acquireTransactionLock()

        XCTAssertThrowsError(try otherStore.acquireTransactionLock()) { error in
            guard case PowerHelperHandoffStoreError.transactionBusy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        withExtendedLifetime(firstLock) {}
        firstLock = nil
        let laterLock = try otherStore.acquireTransactionLock()
        withExtendedLifetime(laterLock) {}
    }

    func testRejectsOversizedJournalBeforeDecoding() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try writeJournal(
            Data(
                repeating: 0,
                count: FilePowerHelperHandoffStore.maximumBytes + 1),
            fixture: fixture)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            guard case PowerHelperHandoffStoreError.stateTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsInvalidPersistedTransaction() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let invalid = PowerHelperHandoffTransaction(
            phase: .registering,
            goal: .install,
            targetDigest: nil,
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001")
        try writeJournal(
            try JSONEncoder().encode(invalid),
            fixture: fixture)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            guard case PowerHelperHandoffStoreError.invalidState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsJournalReadableByOtherUsers() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transaction = PowerHelperHandoffTransaction(
            phase: .removed,
            goal: .install,
            targetDigest: "digest",
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001")
        try writeJournal(
            try JSONEncoder().encode(transaction),
            fixture: fixture,
            permissions: 0o644)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            guard case PowerHelperHandoffStoreError.insecurePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTransactionValidationRejectsInvalidIdentityAndRemovalTarget() {
        let invalidIdentity = PowerHelperHandoffTransaction(
            phase: .registering,
            goal: .install,
            targetDigest: "digest",
            bootSessionIdentifier: "NOT-A-BOOT-UUID")
        let removalWithTarget = PowerHelperHandoffTransaction(
            phase: .removed,
            goal: .remove,
            targetDigest: "digest",
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001")

        XCTAssertFalse(invalidIdentity.isValid)
        XCTAssertFalse(removalWithTarget.isValid)
    }

    func testStoreErrorsHaveActionableDescriptions() {
        let cases: [(PowerHelperHandoffStoreError, String)] = [
            (.insecurePath,
             "The power helper handoff journal has an insecure path."),
            (.stateTooLarge,
             "The power helper handoff journal is unexpectedly large."),
            (.invalidState,
             "The power helper handoff journal is invalid."),
            (.transactionBusy,
             "Another Detach process is already updating the power helper."),
            (.fileSystem(operation: "read", code: EIO),
             "Could not read the power helper handoff journal (errno \(EIO))."),
        ]

        for (error, description) in cases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testClearIsIdempotentBeforeJournalDirectoryExists() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        try fixture.store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testRejectsNonDirectoryJournalParent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let parent = fixture.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: parent)
        let transaction = PowerHelperHandoffTransaction(
            phase: .removed,
            goal: .install,
            targetDigest: "digest",
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001")

        XCTAssertThrowsError(try fixture.store.save(transaction)) { error in
            guard case PowerHelperHandoffStoreError.insecurePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSymlinkTransactionLock() throws {
        let fixture = try makeFixture()
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
                "power-helper-handoff.lock"),
            withDestinationURL: target)

        XCTAssertThrowsError(try fixture.store.acquireTransactionLock()) {
            error in
            guard case let PowerHelperHandoffStoreError.fileSystem(
                operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "open transaction lock")
        }
    }

    func testRejectsOversizedSerializedTransactionBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transaction = PowerHelperHandoffTransaction(
            phase: .removed,
            goal: .install,
            targetDigest: String(
                repeating: "x",
                count: FilePowerHelperHandoffStore.maximumBytes),
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001")

        XCTAssertThrowsError(try fixture.store.save(transaction)) { error in
            guard case PowerHelperHandoffStoreError.stateTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func writeJournal(
        _ data: Data,
        fixture: StoreFixture,
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

    private func makeFixture() throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PowerHelperHandoffStoreTests.\(UUID().uuidString)",
                isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Detach", isDirectory: true)
            .appendingPathComponent("power-helper-handoff.json")
        return StoreFixture(
            root: root,
            fileURL: fileURL,
            store: FilePowerHelperHandoffStore(
                fileURL: fileURL,
                expectedOwner: geteuid()))
    }
}

private struct StoreFixture {
    let root: URL
    let fileURL: URL
    let store: FilePowerHelperHandoffStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
