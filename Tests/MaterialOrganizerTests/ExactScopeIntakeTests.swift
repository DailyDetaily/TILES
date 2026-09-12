import XCTest
import Foundation
@testable import MaterialOrganizer
import OrganizerCore

final class ExactScopeIntakeTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let review: ProjectReviewModel
        var source: URL { root.appendingPathComponent("받은 자료") }
        var target: URL { root.appendingPathComponent("자료") }
        var state: URL { owner.stateDirectory.appendingPathComponent("ReviewState.json") }
        init() throws {
            root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesExactScope-" + UUID().uuidString)
            for name in ["받은 자료", "자료"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            owner = AppModel(demoRootURL: root)
            review = ProjectReviewModel(owner: owner)
            review.contentEnabled = false
        }
        func file(_ name: String) throws -> URL {
            let url = source.appendingPathComponent(name)
            try Data(("original bytes: " + name).utf8).write(to: url)
            return url
        }
        func cleanup() { owner.releaseFolderAccess(); try? FileManager.default.removeItem(at: root) }
    }

    @MainActor private func idle(_ owner: AppModel, _ review: ProjectReviewModel) async throws {
        for _ in 0..<300 {
            if !owner.busy && !review.isAnalyzing && !review.isPreparing { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Exact scope intake did not finish")
        throw OrganizerError("Exact scope intake timed out")
    }

    @MainActor func testBackThenNarrowAndExpandSelectionKeepsOnlyChosenFilesActiveAndPreservesManualChoice() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try fixture.file("a.txt"), b = try fixture.file("b.txt"), c = try fixture.file("c.txt")
        let files = [a, b, c]
        let original = try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }
        fixture.review.receiveScope([a, b])
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(Set(fixture.review.rows.map { $0.evidence.sourcePath }), Set([a.path, b.path]))
        let rowA = try XCTUnwrap(fixture.review.rows.first { $0.evidence.sourcePath == a.path })
        XCTAssertTrue(fixture.review.assignExistingDestination(fixture.target, to: rowA.id))
        fixture.review.returnToInbox()

        fixture.review.receiveScope([a])
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.rows.map { $0.evidence.sourcePath }, [a.path])
        let narrowed = try XCTUnwrap(fixture.review.rows.first)
        XCTAssertTrue(narrowed.explicitlyAssigned)
        XCTAssertEqual(fixture.review.destinationFolder(narrowed), fixture.target.path)
        XCTAssertEqual(fixture.review.batches.filter { $0.id != fixture.review.activeBatchID }.flatMap { $0.files.map(\.path) }, [b.path])
        XCTAssertEqual(fixture.review.pendingCount, 2)

        fixture.review.returnToInbox()
        fixture.review.receiveScope([a, c])
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(Set(fixture.review.rows.map { $0.evidence.sourcePath }), Set([a.path, c.path]))
        XCTAssertEqual(fixture.review.batches.filter { $0.id != fixture.review.activeBatchID }.flatMap { $0.files.map(\.path) }, [b.path])
        XCTAssertEqual(fixture.review.batches.count, 2)
        XCTAssertEqual(fixture.review.pendingCount, 3)
        let expanded = try XCTUnwrap(fixture.review.rows.first { $0.evidence.sourcePath == a.path })
        XCTAssertTrue(expanded.explicitlyAssigned)
        XCTAssertEqual(fixture.review.destinationFolder(expanded), fixture.target.path)
        XCTAssertEqual(try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }, original)
        XCTAssertTrue(fixture.owner.records.isEmpty)

        let owner = AppModel(demoRootURL: fixture.root), review: ProjectReviewModel
        review = ProjectReviewModel(owner: owner)
        defer { owner.releaseFolderAccess() }
        review.receiveScope([a, c])
        try await idle(owner, review)
        XCTAssertEqual(Set(review.rows.map { $0.evidence.sourcePath }), Set([a.path, c.path]))
        XCTAssertEqual(review.batches.filter { $0.id != review.activeBatchID }.flatMap { $0.files.map(\.path) }, [b.path])
        XCTAssertEqual(review.destinationFolder(try XCTUnwrap(review.rows.first { $0.evidence.sourcePath == a.path })), fixture.target.path)
    }

    @MainActor func testReplacingActiveScopePreservesExclusionAndReleasesBorrowedAccessOnce() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try fixture.file("a.txt"), b = try fixture.file("b.txt"), c = try fixture.file("c.txt")
        var firstRelease = 0, secondRelease = 0, thirdRelease = 0
        fixture.review.receiveScope([a, b], releaseAccess: { firstRelease += 1 })
        try await idle(fixture.owner, fixture.review)
        fixture.review.setIncluded(try XCTUnwrap(fixture.review.rows.first { $0.evidence.sourcePath == a.path }).id, false)
        fixture.review.receiveScope([a], releaseAccess: { secondRelease += 1 })
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.rows.map { $0.evidence.sourcePath }, [a.path])
        XCTAssertEqual(fixture.review.rows.first?.included, false)
        XCTAssertEqual(firstRelease, 0)
        XCTAssertEqual(secondRelease, 0)
        fixture.review.receiveScope([c], releaseAccess: { thirdRelease += 1 })
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(firstRelease, 1)
        XCTAssertEqual(secondRelease, 1)
        XCTAssertEqual(thirdRelease, 0)
        XCTAssertEqual(fixture.review.rows.map { $0.evidence.sourcePath }, [c.path])
        XCTAssertEqual(Set(fixture.review.batches.filter { $0.id != fixture.review.activeBatchID }.flatMap { $0.files.map(\.path) }), Set([a.path, b.path]))
        fixture.review.returnToInbox()
        fixture.review.shutdown()
        XCTAssertEqual(firstRelease, 1)
        XCTAssertEqual(secondRelease, 1)
        XCTAssertEqual(thirdRelease, 1)
        XCTAssertTrue([a, b, c].allSatisfy { SafeFileSystem.exists($0) })
    }

    @MainActor func testPersistenceFailureRollsBackExactSelectionAndDoesNotReleaseExistingBorrow() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try fixture.file("a.txt"), b = try fixture.file("b.txt"), c = try fixture.file("c.txt")
        var priorRelease = 0, failedRelease = 0
        fixture.review.receiveScope([a, b], releaseAccess: { priorRelease += 1 })
        try await idle(fixture.owner, fixture.review)
        let previousBatch = fixture.review.activeBatchID
        let previousRows = fixture.review.rows.map(\.id)
        try FileManager.default.removeItem(at: fixture.state)
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: false)
        fixture.review.receiveScope([c], releaseAccess: { failedRelease += 1 })
        XCTAssertFalse(fixture.owner.busy)
        XCTAssertEqual(fixture.review.activeBatchID, previousBatch)
        XCTAssertEqual(fixture.review.rows.map(\.id), previousRows)
        XCTAssertEqual(Set(fixture.review.batches.flatMap { $0.files.map(\.path) }), Set([a.path, b.path]))
        XCTAssertEqual(priorRelease, 0)
        XCTAssertEqual(failedRelease, 1)
        XCTAssertTrue(fixture.review.failure?.contains("저장하지 못했습니다") == true)
        fixture.review.shutdown()
        XCTAssertEqual(priorRelease, 1)
        XCTAssertEqual(failedRelease, 1)
        XCTAssertTrue([a, b, c].allSatisfy { SafeFileSystem.exists($0) })
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }

    @MainActor func testFullPendingQueueRejectsSplittingExistingBatchWithoutLosingFiles() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try fixture.file("a.txt"), b = try fixture.file("b.txt")
        let state = ProjectReviewState(contentEnabled: false, batches:
            [ReviewQueuedBatch(origin: "selected", files: [.init(path: a.path), .init(path: b.path)])] +
            (0..<199).map { ReviewQueuedBatch(origin: "pending \($0)", files: [.init(path: fixture.source.appendingPathComponent("pending-\($0).txt").path)]) })
        let original = try JSONEncoder().encode(state)
        try original.write(to: fixture.state)
        let review = ProjectReviewModel(owner: fixture.owner)
        var released = 0
        review.receiveScope([a], releaseAccess: { released += 1 })
        XCTAssertEqual(released, 1)
        XCTAssertNil(review.activeBatchID)
        XCTAssertTrue(review.rows.isEmpty)
        XCTAssertEqual(review.batches.count, 200)
        XCTAssertEqual(review.pendingCount, 201)
        XCTAssertEqual(try Data(contentsOf: fixture.state), original)
        XCTAssertTrue(review.failure?.contains("묶음") == true)
        XCTAssertTrue(SafeFileSystem.exists(a))
        XCTAssertTrue(SafeFileSystem.exists(b))
    }
}
