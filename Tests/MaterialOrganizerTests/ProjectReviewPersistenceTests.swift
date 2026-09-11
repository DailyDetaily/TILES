import XCTest
import Foundation
@testable import MaterialOrganizer
import OrganizerCore

final class ProjectReviewPersistenceTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let review: ProjectReviewModel
        var source: URL { root.appendingPathComponent("받은 자료") }
        var target: URL { root.appendingPathComponent("자료") }
        var state: URL { owner.stateDirectory.appendingPathComponent("ReviewState.json") }
        init() throws {
            root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesPersistence-" + UUID().uuidString)
            for name in ["받은 자료", "자료"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            owner = AppModel(demoRootURL: root)
            review = ProjectReviewModel(owner: owner)
            review.contentEnabled = false
        }
        func file(_ name: String) throws -> URL {
            let url = source.appendingPathComponent(name)
            try Data("original bytes".utf8).write(to: url)
            return url
        }
        func cleanup() { owner.releaseFolderAccess(); try? FileManager.default.removeItem(at: root) }
    }

    @MainActor private func waitUntilIdle(_ fixture: Fixture) async throws {
        for _ in 0..<600 {
            if !fixture.owner.busy && !fixture.review.isAnalyzing && !fixture.review.isPreparing { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Review operation did not become idle")
        throw OrganizerError("Review operation timed out")
    }

    @MainActor func testFailedSaveAndIntakeRestoreProjectsRowsQueueAndPreparedPlan() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = try fixture.file("original.txt"), incoming = try fixture.file("incoming.txt")
        let project = ProjectDefinition(name: "Original", rootPath: fixture.target.appendingPathComponent("Original").path)
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        fixture.owner.acceptFilesForReview([original])
        try await waitUntilIdle(fixture)
        fixture.review.assignProject(project.id)
        fixture.review.assignFolder("참고자료")
        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        let planID = try XCTUnwrap(fixture.review.preparedPlan).id
        let batchID = fixture.review.activeBatchID
        let rowID = try XCTUnwrap(fixture.review.rows.first).id
        fixture.review.newProject()

        // A directory at the file destination forces atomic replacement to fail,
        // while source files and the journal remain writable.
        try FileManager.default.removeItem(at: fixture.state)
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: false)
        let replacement = ProjectDefinition(name: "Replacement", rootPath: fixture.target.appendingPathComponent("Replacement").path, template: .byKind)
        XCTAssertFalse(fixture.review.saveProject(replacement, applyToIncluded: true))
        XCTAssertEqual(fixture.review.projects, [project])
        XCTAssertEqual(fixture.review.rows.first?.projectID, project.id)
        XCTAssertEqual(fixture.review.rows.first?.folder, "참고자료")
        XCTAssertEqual(fixture.review.preparedPlan?.id, planID)
        XCTAssertTrue(fixture.review.showProjectSetup)
        XCTAssertTrue(fixture.review.failure?.contains("저장하지 못했습니다") == true)

        var released = 0
        fixture.review.receive([incoming], releaseAccess: { released += 1 })
        XCTAssertEqual(released, 1)
        XCTAssertFalse(fixture.owner.busy)
        XCTAssertEqual(fixture.review.activeBatchID, batchID)
        XCTAssertEqual(fixture.review.rows.map(\.id), [rowID])
        XCTAssertEqual(fixture.review.batches.flatMap { $0.files.map(\.path) }, [original.path])
        XCTAssertEqual(fixture.review.preparedPlan?.id, planID)
        XCTAssertTrue(fixture.review.failure?.contains("저장하지 못했습니다") == true)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original bytes")
        XCTAssertEqual(try String(contentsOf: incoming, encoding: .utf8), "original bytes")
        XCTAssertTrue(fixture.owner.records.isEmpty)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: replacement.rootPath)))
    }

    @MainActor func testOversizedQueueKeepsPreviousDiskStateReadableAndRollsBackMemory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let file = try fixture.file("watched.txt")
        XCTAssertTrue(fixture.review.persist())
        let previous = try Data(contentsOf: fixture.state)
        let hugeOrigin = String(repeating: "x", count: 8 * 1_024 * 1_024)
        XCTAssertFalse(fixture.review.enqueueWatchedFiles([file], origin: hugeOrigin))
        XCTAssertTrue(fixture.review.batches.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.state), previous)
        XCTAssertTrue(fixture.review.failure?.contains("8MB") == true)
        let restored = ProjectReviewModel(owner: fixture.owner)
        XCTAssertTrue(restored.storeReadable)
        XCTAssertTrue(restored.batches.isEmpty)
        XCTAssertTrue(SafeFileSystem.exists(file))
    }

    @MainActor func testDirectIntakeCannotWriteMoreBatchesThanLoaderAccepts() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let file = try fixture.file("incoming.txt")
        let state = ProjectReviewState(workspaceRootPath: fixture.target.path, contentEnabled: false,
                                       batches: (0..<200).map { ReviewQueuedBatch(origin: "묶음 \($0)", files: []) })
        let previous = try JSONEncoder().encode(state)
        try previous.write(to: fixture.state)
        let restored = ProjectReviewModel(owner: fixture.owner)
        XCTAssertTrue(restored.storeReadable)
        var released = 0
        restored.receive([file], releaseAccess: { released += 1 })
        XCTAssertEqual(released, 1)
        XCTAssertEqual(restored.batches.count, 200)
        XCTAssertNil(restored.activeBatchID)
        XCTAssertTrue(restored.rows.isEmpty)
        XCTAssertFalse(fixture.owner.busy)
        XCTAssertEqual(try Data(contentsOf: fixture.state), previous)
        XCTAssertTrue(restored.failure?.contains("묶음") == true)
    }
}
