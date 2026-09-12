import XCTest
import Foundation
import OrganizerCore
@testable import MaterialOrganizer

final class ProjectReviewRuleStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
            .appendingPathComponent("TilesRulesStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func rule(id: UUID = UUID(), folder: String = "문서") -> ProjectReviewRule {
        .init(id: id, sourceDirectory: "/Users/test/Desktop", filenamePrefix: "Atlas_", fileExtension: "pdf",
              projectID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, projectRootPath: "/Users/test/Projects/Atlas", folder: folder)
    }

    @MainActor func testRulesReloadDeduplicateDisableAndDeleteWithoutTouchingOtherState() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("ReviewState.json")
        let bytes = Data("existing queue is independent".utf8); try bytes.write(to: unrelated)
        let store = ProjectReviewAssistance(stateDirectory: root)
        XCTAssertTrue(store.storeReadable); XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.save(rule())); XCTAssertTrue(store.save(rule()))
        XCTAssertEqual(store.rules.count, 1)
        let id = try XCTUnwrap(store.rules.first?.id)
        XCTAssertTrue(store.setEnabled(id, false))
        let restored = ProjectReviewAssistance(stateDirectory: root)
        XCTAssertTrue(restored.storeReadable); XCTAssertEqual(restored.rules.count, 1)
        XCTAssertEqual(restored.rules.first?.enabled, false)
        XCTAssertTrue(restored.remove(id))
        XCTAssertTrue(ProjectReviewAssistance(stateDirectory: root).rules.isEmpty)
        XCTAssertEqual(try Data(contentsOf: unrelated), bytes)
    }

    @MainActor func testCorruptRulesArePreservedAndCannotBeReplaced() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ReviewRules.json")
        let bytes = Data("{ broken existing rules".utf8); try bytes.write(to: url)
        let store = ProjectReviewAssistance(stateDirectory: root)
        XCTAssertFalse(store.storeReadable); XCTAssertFalse(store.save(rule()))
        XCTAssertTrue(store.rules.isEmpty); XCTAssertNotNil(store.failure)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor func testExternalWriteIsNotOverwrittenByStaleStore() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ProjectReviewAssistance(stateDirectory: root)
        let second = ProjectReviewAssistance(stateDirectory: root)
        XCTAssertTrue(first.save(rule()))
        let url = root.appendingPathComponent("ReviewRules.json"), saved = try Data(contentsOf: url)
        XCTAssertFalse(second.save(rule(folder: "이미지")))
        XCTAssertFalse(second.storeReadable); XCTAssertTrue(second.rules.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    @MainActor func testInvalidRuleDoesNotChangePreviouslySavedRules() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectReviewAssistance(stateDirectory: root)
        XCTAssertTrue(store.save(rule()))
        let url = root.appendingPathComponent("ReviewRules.json"), saved = try Data(contentsOf: url)
        var invalid = rule(); invalid.filenamePrefix = ""
        XCTAssertFalse(store.save(invalid)); XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    @MainActor func testRuleFileSymlinkIsRejectedWithoutChangingItsTarget() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("original.json"), bytes = Data("protected original".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ReviewRules.json"), withDestinationURL: target)
        let store = ProjectReviewAssistance(stateDirectory: root)
        XCTAssertFalse(store.storeReadable); XCTAssertFalse(store.save(rule()))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
}
