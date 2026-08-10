import Darwin
import Foundation
import XCTest
@testable import DetachKit

final class PowerRunActivityTests: XCTestCase {
    private final class ObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting = false

        func markWaiting() {
            lock.lock()
            waiting = true
            lock.unlock()
        }

        func followsWaiting() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return waiting
        }
    }

    func testReaderPermitsSleepOnlyForExactOwnedRegularWaitingRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = directory.appendingPathComponent("activity")
        let symlink = directory.appendingPathComponent("activity-link")
        let reader = FilePowerRunActivityReader()

        XCTAssertEqual(reader.state(atPath: activity.path), .working)
        try Data("waiting\n".utf8).write(to: activity)
        XCTAssertEqual(reader.state(atPath: activity.path), .waiting)

        for malformed in ["waiting", "waiting\nextra", "idle\n", "\n"] {
            try Data(malformed.utf8).write(to: activity)
            XCTAssertEqual(reader.state(atPath: activity.path), .working)
        }

        try Data("waiting\n".utf8).write(to: activity)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: activity)
        XCTAssertEqual(reader.state(atPath: symlink.path), .working)
    }

    func testWatcherReacquiresOnTranscriptWriteWithoutActivityPolling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = directory.appendingPathComponent("activity")
        let activitySource = directory.appendingPathComponent("activity-source")
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try Data("working\n".utf8).write(to: activity)
        try Data("initial\n".utf8).write(to: transcript)
        var information = stat()
        XCTAssertEqual(Darwin.lstat(transcript.path, &information), 0)
        let signature = "\(information.st_ino):\(information.st_mtimespec.tv_sec):\(information.st_size)"
        try Data("\(signature)\n\(transcript.path)".utf8).write(
            to: activitySource)
        let observedWaiting = DispatchSemaphore(value: 0)
        let observedWorking = DispatchSemaphore(value: 0)
        let watcher = FilePowerRunActivityWatcher()
        let observation = ObservationBox()

        let result = try watcher.run(
            activityFile: activity.path,
            activitySourceFile: activitySource.path,
            onStateChange: { state in
                if state == .waiting {
                    observation.markWaiting()
                    observedWaiting.signal()
                } else if observation.followsWaiting() {
                    observedWorking.signal()
                }
            },
            operation: {
                let handle = try FileHandle(forWritingTo: activity)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("waiting\n".utf8))
                try handle.synchronize()
                try handle.close()
                XCTAssertEqual(
                    observedWaiting.wait(timeout: .now() + 2),
                    .success)
                let transcriptHandle = try FileHandle(forWritingTo: transcript)
                try transcriptHandle.seekToEnd()
                try transcriptHandle.write(contentsOf: Data("next turn\n".utf8))
                try transcriptHandle.synchronize()
                try transcriptHandle.close()
                XCTAssertEqual(
                    observedWorking.wait(timeout: .now() + 2),
                    .success)
                return ChildCommandResult(exitCode: 17)
            })

        XCTAssertEqual(result.exitCode, 17)
    }

    func testWatcherRejectsWaitingWithMismatchedTranscriptSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = directory.appendingPathComponent("activity")
        let activitySource = directory.appendingPathComponent("activity-source")
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try Data("waiting\n".utf8).write(to: activity)
        try Data("initial\n".utf8).write(to: transcript)
        try Data("0:0:0\n\(transcript.path)".utf8).write(to: activitySource)
        let observedWorking = DispatchSemaphore(value: 0)
        let watcher = FilePowerRunActivityWatcher()

        let result = try watcher.run(
            activityFile: activity.path,
            activitySourceFile: activitySource.path,
            onStateChange: { state in
                if state == .working { observedWorking.signal() }
            },
            operation: {
                XCTAssertEqual(
                    observedWorking.wait(timeout: .now() + 2),
                    .success)
                return ChildCommandResult(exitCode: 23)
            })

        XCTAssertEqual(result.exitCode, 23)
    }
}
