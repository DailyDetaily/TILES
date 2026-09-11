import XCTest
import Foundation
import OrganizerCore
@testable import MaterialOrganizer

final class FolderWatchServiceTests: XCTestCase {
    private func fixture() throws -> (root: URL, watched: URL, state: URL) {
        let root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory).appendingPathComponent("WatchService-" + UUID().uuidString)
        let watched = root.appendingPathComponent("Selected"), state = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        return (root, watched, state)
    }
    @MainActor private func idle(_ service: FolderWatchService) async throws {
        for _ in 0..<1_000 {
            if service.isLoaded, !service.isScanning, !service.isSaving { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Watcher did not settle: \(service.status)")
    }

    @MainActor func testExplicitFolderStableFileQueuesOnceThenChangedFileQueuesAgainWithoutMoving() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.watched.appendingPathComponent("report.txt")
        try Data("first".utf8).write(to: file)
        var clock = Date().addingTimeInterval(120)
        let service = FolderWatchService(stateDirectory: fixture.state, isDemo: true, pollInterval: 0, now: { clock })
        defer { service.shutdown() }
        var received: [[URL]] = []
        service.onReady = { urls, origin in XCTAssertEqual(origin, "Selected"); received.append(urls); return true }
        try await idle(service)
        XCTAssertFalse(service.configuration.enabled); XCTAssertNil(service.configuration.folderPath)
        XCTAssertFalse(SafeFileSystem.exists(fixture.state.appendingPathComponent("WatchState.json")))
        let connected = await service.setFolder(fixture.watched); XCTAssertTrue(connected)
        service.setDelay(60); service.setEnabled(true); try await idle(service)
        XCTAssertTrue(received.isEmpty)
        clock.addTimeInterval(29); service.scanNow(); try await idle(service)
        XCTAssertTrue(received.isEmpty)
        clock.addTimeInterval(1); service.scanNow(); try await idle(service)
        XCTAssertEqual(received, [[file]])
        XCTAssertEqual(try String(contentsOf: file), "first")
        service.scanNow(); try await idle(service); XCTAssertEqual(received.count, 1)
        try Data("changed".utf8).write(to: file)
        clock.addTimeInterval(1); service.scanNow(); try await idle(service)
        XCTAssertEqual(received.count, 1)
        clock.addTimeInterval(30); service.scanNow(); try await idle(service)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(try String(contentsOf: file), "changed")
        XCTAssertEqual(service.pendingCount, 0)
    }

    @MainActor func testRejectedQueuePersistsAcrossPauseRestartAndAcceptedVersionNeverFloods() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.watched.appendingPathComponent("report.txt")
        try Data("untouched".utf8).write(to: file)
        var clock = Date().addingTimeInterval(120)
        let first = FolderWatchService(stateDirectory: fixture.state, isDemo: true, pollInterval: 0, now: { clock })
        first.onReady = { _, _ in false }
        try await idle(first); let connected = await first.setFolder(fixture.watched); XCTAssertTrue(connected)
        first.setDelay(0); first.setEnabled(true); try await idle(first)
        clock.addTimeInterval(30); first.scanNow(); try await idle(first)
        XCTAssertEqual(first.pendingCount, 1)
        first.setEnabled(false); try await idle(first); first.shutdown()
        let persisted = try JSONDecoder().decode(FolderWatchState.self, from: Data(contentsOf: fixture.state.appendingPathComponent("WatchState.json")))
        XCTAssertEqual(persisted.pending.map(\.url), [file]); XCTAssertFalse(persisted.configuration.enabled)

        let second = FolderWatchService(stateDirectory: fixture.state, isDemo: true, pollInterval: 0, now: { clock })
        var deliveries = 0
        second.onReady = { files, _ in XCTAssertEqual(files, [file]); deliveries += 1; return true }
        try await idle(second)
        XCTAssertEqual(second.pendingCount, 1); XCTAssertEqual(deliveries, 0)
        second.setEnabled(true); try await idle(second)
        XCTAssertEqual(deliveries, 1); XCTAssertEqual(second.pendingCount, 0)
        second.setEnabled(false); try await idle(second)
        second.setEnabled(true); try await idle(second)
        XCTAssertEqual(deliveries, 1); second.shutdown()

        let third = FolderWatchService(stateDirectory: fixture.state, isDemo: true, pollInterval: 0, now: { clock })
        defer { third.shutdown() }
        third.onReady = { _, _ in deliveries += 1; return true }
        try await idle(third); clock.addTimeInterval(600); third.scanNow(); try await idle(third)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(try String(contentsOf: file), "untouched")
    }

    @MainActor func testCorruptOldAndFutureStateAreNeverOverwritten() async throws {
        for bytes in [Data("{broken".utf8), Data("{\"version\":0}".utf8), Data("{\"version\":999}".utf8)] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
            let stateURL = fixture.state.appendingPathComponent("WatchState.json")
            try bytes.write(to: stateURL)
            let service = FolderWatchService(stateDirectory: fixture.state, isDemo: true, pollInterval: 0)
            try await idle(service)
            XCTAssertFalse(service.configuration.enabled)
            let connected = await service.setFolder(fixture.watched); XCTAssertFalse(connected)
            service.setDelay(0); service.setEnabled(true); service.scanNow(); try await idle(service)
            service.shutdown()
            XCTAssertEqual(try Data(contentsOf: stateURL), bytes)
            XCTAssertTrue(service.status.contains("보존"))
        }
    }

    @MainActor func testExternalStateReplacementStopsWatcherWithoutOverwritingBytes() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = FolderWatchService(stateDirectory: fixture.state, isDemo: true, pollInterval: 0)
        defer { service.shutdown() }
        try await idle(service); let connected = await service.setFolder(fixture.watched); XCTAssertTrue(connected)
        let stateURL = fixture.state.appendingPathComponent("WatchState.json")
        let replacement = Data("{\"version\":50,\"unknown\":true}".utf8)
        try replacement.write(to: stateURL)
        service.setDelay(120); try await idle(service)
        service.setEnabled(true); service.scanNow(); try await idle(service)
        XCTAssertEqual(try Data(contentsOf: stateURL), replacement)
        XCTAssertTrue(service.status.contains("보존"))
    }
}
