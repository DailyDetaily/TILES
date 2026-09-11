import XCTest
@testable import MaterialOrganizer
import OrganizerCore

final class FileMoveFlowTests: XCTestCase {
    @MainActor private func waitUntilIdle(_ model: AppModel) async throws {
        for _ in 0..<300 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("File move did not finish within 30 seconds")
    }

    @MainActor func testSelectCreateFolderRememberMoveAndUndo() async throws {
        let root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory).appendingPathComponent("TilesFlow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["받은 자료", "자료"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let file = root.appendingPathComponent("받은 자료/Research-note.txt")
        try Data("original-contents".utf8).write(to: file)
        let model = AppModel(demoRootURL: root)
        defer { model.releaseFolderAccess() }
        XCTAssertNil(model.error)
        model.acceptFile(file)
        try await waitUntilIdle(model)
        XCTAssertEqual(model.quickFile, file)
        XCTAssertNil(model.quickDestination)
        XCTAssertTrue(model.createQuickFolder(name: "Research", parent: root.appendingPathComponent("자료")))
        XCTAssertEqual(model.quickDestination?.name, "Research")
        model.rememberQuickChoice = true; model.quickRulePrefix = "Research"
        model.executeQuickMove()
        try await waitUntilIdle(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.quickRun?.state, .completed)
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.folderSuggestionRules.first?.prefix, "Research")
        XCTAssertFalse(SafeFileSystem.exists(file))
        model.undoQuickMove()
        try await waitUntilIdle(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.quickRun?.state, .undone)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original-contents")
        XCTAssertTrue(SafeFileSystem.exists(root.appendingPathComponent("자료/Research")))
        XCTAssertFalse(SafeFileSystem.exists(root.appendingPathComponent("AppState/Settings.json")))
    }
}
