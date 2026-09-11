import XCTest
import Foundation
@testable import OrganizerCore

final class FolderWatchPolicyTests: XCTestCase {
    private let folder = "/tmp/watched"
    private func version(_ name: String = "report.txt", modified: Int64 = 0, size: Int64 = 10, inode: UInt64 = 2) -> FolderWatchFileVersion {
        .init(path: folder + "/" + name, fingerprint: .init(device: 1, inode: inode, size: size, modifiedSeconds: modified))
    }
    private func state(delay: TimeInterval = 60) -> FolderWatchState {
        .init(configuration: .init(folderPath: folder, waitInterval: delay, enabled: true),
              rootIdentity: .init(device: 1, inode: 1, kind: "directory"))
    }
    private func time(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testOldFilesRequireObservedStabilityAndRepeatedManualScanDoesNotBypassIt() {
        var value = state(delay: 600); let file = version()
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(1_000)).isEmpty)
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(1_000)).isEmpty)
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(1_029)).isEmpty)
        XCTAssertEqual(FolderWatchPolicy.observe([file], state: &value, now: time(1_030)), [file])
        XCTAssertEqual(value.pending, [file])
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(2_000)).isEmpty)
        XCTAssertEqual(value.pending, [file])
    }

    func testModificationResetsWaitingAndRespectsDelayAfterLastChange() {
        var value = state(); let first = version(modified: 100), changed = version(modified: 145, size: 20)
        FolderWatchPolicy.observe([first], state: &value, now: time(100))
        XCTAssertTrue(FolderWatchPolicy.observe([first], state: &value, now: time(144)).isEmpty)
        XCTAssertTrue(FolderWatchPolicy.observe([changed], state: &value, now: time(145)).isEmpty)
        XCTAssertTrue(FolderWatchPolicy.observe([changed], state: &value, now: time(204)).isEmpty)
        XCTAssertEqual(FolderWatchPolicy.observe([changed], state: &value, now: time(205)), [changed])
        let replaced = version(modified: 145, size: 20, inode: 99)
        XCTAssertTrue(FolderWatchPolicy.observe([replaced], state: &value, now: time(206)).isEmpty)
        XCTAssertTrue(value.pending.isEmpty, "A queued old version must be withdrawn when it changes")
        XCTAssertEqual(FolderWatchPolicy.observe([replaced], state: &value, now: time(236)), [replaced])
    }

    func testDeliveredVersionSurvivesPauseResumeAndRestartButChangedVersionQueuesAgain() throws {
        var value = state(delay: 0); let file = version()
        FolderWatchPolicy.observe([file], state: &value, now: time(100))
        FolderWatchPolicy.observe([file], state: &value, now: time(130))
        FolderWatchPolicy.markDelivered([file], state: &value)
        value.configuration.enabled = false
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(200)).isEmpty)
        let encoded = try JSONEncoder().encode(value)
        value = try JSONDecoder().decode(FolderWatchState.self, from: encoded); try value.validate()
        value.configuration.enabled = true
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(300)).isEmpty)
        XCTAssertTrue(value.pending.isEmpty)
        let changed = version(modified: 300, size: 20)
        XCTAssertTrue(FolderWatchPolicy.observe([changed], state: &value, now: time(301)).isEmpty)
        XCTAssertEqual(FolderWatchPolicy.observe([changed], state: &value, now: time(331)), [changed])
    }

    func testOutstandingQueueSurvivesRestartAndMissingFileWithdrawsIt() throws {
        var value = state(delay: 0); let file = version()
        FolderWatchPolicy.observe([file], state: &value, now: time(100))
        FolderWatchPolicy.observe([file], state: &value, now: time(130))
        value = try JSONDecoder().decode(FolderWatchState.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value.pending, [file]); try value.validate()
        FolderWatchPolicy.observe([], state: &value, now: time(160))
        XCTAssertTrue(value.pending.isEmpty); XCTAssertTrue(value.observations.isEmpty)
    }

    func testClockCorrectionDoesNotCountAsStableElapsedTime() {
        var value = state(delay: 0); let file = version()
        FolderWatchPolicy.observe([file], state: &value, now: time(100))
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(90)).isEmpty)
        XCTAssertTrue(FolderWatchPolicy.observe([file], state: &value, now: time(119)).isEmpty)
        XCTAssertEqual(FolderWatchPolicy.observe([file], state: &value, now: time(120)), [file])
    }

    func testIncreasingDelayWithdrawsUndeliveredQueueUntilNewDeadline() {
        var value = state(delay: 0); let file = version(modified: 100)
        FolderWatchPolicy.observe([file], state: &value, now: time(100))
        FolderWatchPolicy.observe([file], state: &value, now: time(130))
        XCTAssertEqual(value.pending, [file])
        value.configuration.waitInterval = 600
        FolderWatchPolicy.observe([file], state: &value, now: time(131))
        XCTAssertTrue(value.pending.isEmpty)
        XCTAssertEqual(FolderWatchPolicy.observe([file], state: &value, now: time(700)), [file])
    }

    func testFiveHundredFileQueueKeepsOrderAndAcknowledgesOnlyAcceptedVersions() throws {
        var value = state(delay: 0)
        let files = (0..<500).map { version(String(format: "file-%03d.txt", $0), inode: UInt64($0 + 2)) }
        FolderWatchPolicy.observe(files, state: &value, now: time(100))
        XCTAssertEqual(FolderWatchPolicy.observe(files, state: &value, now: time(130)), files)
        FolderWatchPolicy.markDelivered(Array(files.prefix(250)), state: &value)
        XCTAssertEqual(value.pending, Array(files.suffix(250)))
        XCTAssertTrue(FolderWatchPolicy.observe(files, state: &value, now: time(160)).isEmpty)
        XCTAssertEqual(value.pending, Array(files.suffix(250)))
        try value.validate()
    }

    func testDefaultOffAndExcludedNamesNeverBecomeCandidates() {
        XCTAssertFalse(FolderWatchConfiguration().enabled)
        XCTAssertNil(FolderWatchConfiguration().folderPath)
        XCTAssertEqual(FolderWatchConfiguration().waitInterval, 600)
        let names = [".hidden", "~$document.docx", "image.crdownload", "video.part", "document.tmp", "asset.download", "file.icloud", "edit.swp", "draft~"]
        XCTAssertTrue(names.allSatisfy(FolderWatchPolicy.excludes))
        var value = state(delay: 0)
        FolderWatchPolicy.observe(names.map { version($0) }, state: &value, now: time(100))
        FolderWatchPolicy.observe(names.map { version($0) }, state: &value, now: time(200))
        XCTAssertTrue(value.pending.isEmpty); XCTAssertTrue(value.observations.isEmpty)
        let nested = FolderWatchFileVersion(path: folder + "/sub/nested.txt", fingerprint: version().fingerprint)
        FolderWatchPolicy.observe([nested], state: &value, now: time(300))
        XCTAssertTrue(value.observations.isEmpty)
    }

    func testMetadataScannerReadsOnlyImmediateOrdinarySupportedFiles() throws {
        let root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory).appendingPathComponent("FolderWatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = root.appendingPathComponent("report.txt")
        try Data("watcher preserves original".utf8).write(to: ordinary)
        for name in [".hidden", "~$locked.docx", "unfinished.crdownload", "cloud.icloud"] {
            try Data("not ready".utf8).write(to: root.appendingPathComponent(name))
        }
        for name in ["subfolder", "Example.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
            try Data("nested".utf8).write(to: root.appendingPathComponent(name + "/nested.txt"))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: ordinary)
        let bookmark = try ordinary.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: root.appendingPathComponent("report alias"))
        let before = try Data(contentsOf: ordinary)
        let files = try FolderWatchPolicy.scan(folder: root)
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["report.txt"])
        XCTAssertEqual(try Data(contentsOf: ordinary), before)
        XCTAssertTrue(SafeFileSystem.exists(root.appendingPathComponent("subfolder/nested.txt")))
        XCTAssertThrowsError(try FolderWatchPolicy.scan(folder: root, cancelled: { true }))
        XCTAssertThrowsError(try FolderWatchPolicy.scan(folder: root, expectedIdentity: .init(device: 1, inode: 1, kind: "directory")))
    }

    func testInvalidAndFutureStateVersionsAreRejected() throws {
        var value = state()
        for version in [0, 2] { value.version = version; XCTAssertThrowsError(try value.validate()) }
        value = state(); value.configuration.waitInterval = -.infinity
        XCTAssertThrowsError(try value.validate())
        value = state(); value.pending = [version()]
        XCTAssertThrowsError(try value.validate(), "Queue records must match a known observation")
    }
}
