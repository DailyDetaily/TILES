import XCTest
import Foundation
@testable import MaterialOrganizer
import OrganizerCore

final class ProjectReviewFlowTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let review: ProjectReviewModel
        var source: URL { root.appendingPathComponent("받은 자료") }
        var target: URL { root.appendingPathComponent("자료") }

        init() throws {
            root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesProjectReview-" + UUID().uuidString)
            for name in ["받은 자료", "자료"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            owner = AppModel(demoRootURL: root)
            review = ProjectReviewModel(owner: owner)
            // These tests exercise intake, planning, persistence and moves. OCR has separate core tests.
            review.contentEnabled = false
        }

        func cleanup() {
            owner.releaseFolderAccess()
            try? FileManager.default.removeItem(at: root)
        }

        func file(_ name: String, contents: String = "original fixture bytes") throws -> URL {
            let url = source.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        func project(_ name: String = "Atlas", template: ProjectTemplate = .byKind) -> ProjectDefinition {
            .init(name: name, rootPath: target.appendingPathComponent(name).path, template: template)
        }
    }

    @MainActor private func waitUntilIdle(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if !fixture.owner.busy && !fixture.review.isAnalyzing && !fixture.review.isPreparing { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Project review did not become idle within 60 seconds", file: file, line: line)
        throw OrganizerError("Project review timed out")
    }

    @MainActor func testMultiInputProjectPreviewApplyAndUndoPreserveEveryByteAndIdentity() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let files = try [fixture.file("meeting.txt"), fixture.file("picture.png")]
        let originals = try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }
        XCTAssertNotNil(fixture.owner.receiveReviewFiles)
        fixture.owner.acceptFilesForReview(files)
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.rows.count, 2)
        let project = fixture.project()
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        for row in fixture.review.rows { fixture.review.assignProject(project.id, to: row.id) }
        XCTAssertEqual(fixture.review.readyCount, 2)
        XCTAssertEqual(Set(fixture.review.rows.compactMap(\.folder)), Set(["문서", "이미지"]))
        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        let preview = try XCTUnwrap(fixture.review.preparedPlan)
        XCTAssertEqual(preview.proposals.count, 2)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertEqual(try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }, originals)
        XCTAssertTrue(fixture.owner.records.isEmpty)

        fixture.review.executePrepared()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        let run = try XCTUnwrap(fixture.review.lastRun)
        XCTAssertEqual(run.state, .completed); XCTAssertEqual(run.movedCount, 2)
        XCTAssertEqual(fixture.owner.records.count, 1)
        XCTAssertTrue(files.allSatisfy { !SafeFileSystem.exists($0) })
        XCTAssertTrue(run.entries.allSatisfy { SafeFileSystem.exists(URL(fileURLWithPath: $0.destination)) })

        fixture.review.undo()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure); XCTAssertEqual(fixture.review.lastRun?.state, .undone)
        XCTAssertEqual(try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }, originals)
        XCTAssertEqual(fixture.owner.records.count, 1)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
    }

    @MainActor func testEmptyTemplateCreatesOnlyOnApplyAndCanUndoAfterward() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project("Empty Project", template: .simple)
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        fixture.review.prepare(folderOnly: project.id)
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        XCTAssertEqual(try XCTUnwrap(fixture.review.preparedPlan).proposals.count, 0)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertTrue(fixture.owner.records.isEmpty)
        fixture.review.executePrepared()
        try await waitUntilIdle(fixture)
        let run = try XCTUnwrap(fixture.review.lastRun)
        XCTAssertEqual(run.state, .completed); XCTAssertEqual(run.movedCount, 0); XCTAssertTrue(run.canUndo)
        let root = URL(fileURLWithPath: project.rootPath)
        XCTAssertEqual(Set(run.createdDirectories.map(\.path)), Set([root.path] + project.folders.map { root.appendingPathComponent($0).path }))
        XCTAssertEqual(fixture.owner.records.count, 1)
        fixture.review.undo()
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.lastRun?.state, .undone)
        XCTAssertFalse(SafeFileSystem.exists(root)); XCTAssertTrue(SafeFileSystem.exists(fixture.target))
    }

    @MainActor func testUnresolvedFilesRemainQueuedWhileReadyFilesMove() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let ready = try fixture.file("Atlas-note.txt"), unresolved = try fixture.file("unrelated.txt")
        fixture.owner.acceptFilesForReview([ready, unresolved])
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.readyCount, 1); XCTAssertEqual(fixture.review.unresolvedCount, 1)
        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        XCTAssertEqual(try XCTUnwrap(fixture.review.preparedPlan).proposals.map(\.source), [ready.path])
        fixture.review.executePrepared()
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.lastRun?.movedCount, 1)
        XCTAssertFalse(SafeFileSystem.exists(ready)); XCTAssertTrue(SafeFileSystem.exists(unresolved))
        XCTAssertEqual(fixture.review.batches.flatMap { $0.files.map(\.path) }, [unresolved.path])
        fixture.review.returnToInbox()
        XCTAssertEqual(fixture.review.pendingCount, 1)
        let pending = try XCTUnwrap(fixture.review.batches.first)
        fixture.review.openBatch(pending)
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.rows.map { $0.evidence.sourcePath }, [unresolved.path])
        XCTAssertEqual(fixture.review.readyCount, 0)
    }

    @MainActor func testAnotherDropKeepsCurrentFilesManualFolderAndInclusionChoice() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let first = try fixture.file("first.txt"), second = try fixture.file("second.txt")
        fixture.owner.acceptFilesForReview([first])
        try await waitUntilIdle(fixture)
        let rowID = try XCTUnwrap(fixture.review.rows.first).id
        fixture.review.assignProject(project.id, to: rowID)
        fixture.review.assignFolder("기타", to: rowID)
        fixture.review.setIncluded(rowID, false)
        fixture.owner.acceptFilesForReview([second])
        try await waitUntilIdle(fixture)
        XCTAssertEqual(Set(fixture.review.rows.map { $0.evidence.sourcePath }), Set([first.path, second.path]))
        let preserved = try XCTUnwrap(fixture.review.rows.first { $0.evidence.sourcePath == first.path })
        XCTAssertEqual(preserved.projectID, project.id); XCTAssertEqual(preserved.folder, "기타")
        XCTAssertFalse(preserved.included); XCTAssertTrue(preserved.explicitlyAssigned)
        XCTAssertEqual(fixture.review.batches.count, 1); XCTAssertEqual(fixture.review.pendingCount, 2)
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }

    @MainActor func testPendingQueueAndManualProjectChoicesReloadWithoutMovingFiles() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        let source = try fixture.file("note.txt")
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        fixture.owner.acceptFilesForReview([source])
        try await waitUntilIdle(fixture)
        fixture.review.assignProject(project.id)
        fixture.review.assignFolder("")
        fixture.review.returnToInbox()
        fixture.review.persist()
        let owner = AppModel(demoRootURL: fixture.root)
        let review = ProjectReviewModel(owner: owner)
        defer { owner.releaseFolderAccess() }
        XCTAssertTrue(review.storeReadable)
        XCTAssertEqual(review.projects, [project])
        XCTAssertEqual(review.batches.flatMap { $0.files.map(\.path) }, [source.path])
        let pending = try XCTUnwrap(review.batches.first)
        review.openBatch(pending)
        for _ in 0..<600 {
            if !owner.busy && !review.isAnalyzing { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(owner.busy)
        let row = try XCTUnwrap(review.rows.first)
        XCTAssertEqual(row.projectID, project.id); XCTAssertEqual(row.folder, ""); XCTAssertTrue(row.explicitlyAssigned)
        XCTAssertTrue(SafeFileSystem.exists(source)); XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertTrue(owner.records.isEmpty)
    }

    @MainActor func testRedropDeduplicatesAcrossReloadAndOtherBatchesPreservingChoices() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        let source = try fixture.file("café.txt"), other = try fixture.file("other.txt"), fresh = try fixture.file("fresh.txt")
        let decomposed = URL(fileURLWithPath: source.path.decomposedStringWithCanonicalMapping)
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        fixture.review.receive([source])
        try await waitUntilIdle(fixture)
        let originalBatchID = try XCTUnwrap(fixture.review.activeBatchID)
        let rowID = try XCTUnwrap(fixture.review.rows.first).id
        fixture.review.assignProject(project.id, to: rowID)
        fixture.review.assignFolder("기타", to: rowID)
        fixture.review.setIncluded(rowID, false)
        fixture.review.returnToInbox()
        XCTAssertTrue(fixture.review.enqueueWatchedFiles([decomposed], origin: "정규화 회귀"))
        XCTAssertEqual(fixture.review.pendingCount, 1); XCTAssertEqual(fixture.review.batches.count, 1)
        XCTAssertTrue(fixture.review.enqueueWatchedFiles([other], origin: "회귀 대기"))
        let otherBatchID = try XCTUnwrap(fixture.review.batches.first { $0.id != originalBatchID }).id

        let owner = AppModel(demoRootURL: fixture.root)
        let review = ProjectReviewModel(owner: owner)
        defer { owner.releaseFolderAccess() }
        func idle() async throws {
            for _ in 0..<100 {
                if !owner.busy && !review.isAnalyzing { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTFail("Reopened review did not finish analysis")
        }
        XCTAssertNil(review.activeBatchID)
        review.receive([decomposed])
        try await idle()
        XCTAssertEqual(review.activeBatchID, originalBatchID)
        XCTAssertEqual(review.pendingCount, 2); XCTAssertEqual(review.batches.count, 2)
        XCTAssertEqual(review.batches.first { $0.id == originalBatchID }?.files.first?.path.utf8.elementsEqual(source.path.utf8), true)
        let preserved = try XCTUnwrap(review.rows.first)
        XCTAssertEqual(preserved.projectID, project.id); XCTAssertEqual(preserved.folder, "기타")
        XCTAssertFalse(preserved.included); XCTAssertTrue(preserved.explicitlyAssigned)

        review.returnToInbox()
        review.receive([decomposed, fresh])
        try await idle()
        XCTAssertEqual(review.pendingCount, 3); XCTAssertEqual(review.batches.count, 3)
        XCTAssertEqual(review.rows.map { $0.evidence.sourcePath }, [fresh.path])
        review.openBatch(try XCTUnwrap(review.batches.first { $0.id == otherBatchID }))
        try await idle()
        review.receive([source])
        try await idle()
        XCTAssertEqual(review.activeBatchID, originalBatchID)
        XCTAssertEqual(review.pendingCount, 3); XCTAssertEqual(review.batches.count, 3)
        let reopened = try XCTUnwrap(review.rows.first)
        XCTAssertEqual(reopened.projectID, project.id); XCTAssertEqual(reopened.folder, "기타")
        XCTAssertFalse(reopened.included); XCTAssertTrue(reopened.explicitlyAssigned)
        XCTAssertTrue([source, other, fresh].allSatisfy { SafeFileSystem.exists($0) })
        XCTAssertTrue(owner.records.isEmpty)
    }

    @MainActor func testCorruptReviewStateIsPreservedAndCannotBeOverwrittenByIntake() async throws {
        let root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
            .appendingPathComponent("TilesCorruptReview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["받은 자료", "자료"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let owner = AppModel(demoRootURL: root)
        let stateURL = owner.stateDirectory.appendingPathComponent("ReviewState.json")
        let damaged = Data("{intentionally incomplete review state".utf8)
        try damaged.write(to: stateURL)
        let review = ProjectReviewModel(owner: owner)
        defer { owner.releaseFolderAccess() }
        XCTAssertFalse(review.storeReadable); XCTAssertNotNil(review.failure)
        let source = root.appendingPathComponent("받은 자료/keep.txt")
        try Data("preserved source".utf8).write(to: source)
        owner.acceptFilesForReview([source])
        let project = ProjectDefinition(name: "Atlas", rootPath: root.appendingPathComponent("자료/Atlas").path)
        XCTAssertFalse(review.saveProject(project, applyToIncluded: false))
        review.persist(); review.shutdown()
        XCTAssertEqual(try Data(contentsOf: stateURL), damaged)
        XCTAssertTrue(SafeFileSystem.exists(source)); XCTAssertTrue(owner.records.isEmpty)
    }

    @MainActor func testSameInodeContentChangeAfterAnalysisRejectsPrepare() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let source = try fixture.file("Atlas-note.txt", contents: "alpha evidence")
        fixture.owner.acceptFilesForReview([source])
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.readyCount, 1)
        let before = try SafeFileSystem.identity(at: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data("other evidence".utf8)); try handle.close()
        XCTAssertEqual(try SafeFileSystem.identity(at: source), before)
        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.preparedPlan); XCTAssertNotNil(fixture.review.failure)
        XCTAssertTrue(fixture.review.failure?.contains("바뀌었습니다") == true)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "other evidence")
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }

    @MainActor func testSameInodeContentChangeAfterPreviewRejectsExecuteWithoutCreatingFolders() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let source = try fixture.file("Atlas-note.txt", contents: "alpha evidence")
        fixture.owner.acceptFilesForReview([source])
        try await waitUntilIdle(fixture)
        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        XCTAssertNotNil(fixture.review.preparedPlan)
        let before = try SafeFileSystem.identity(at: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data("other evidence".utf8)); try handle.close()
        XCTAssertEqual(try SafeFileSystem.identity(at: source), before)
        fixture.review.executePrepared()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.lastRun); XCTAssertNotNil(fixture.review.failure)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "other evidence")
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }
}
