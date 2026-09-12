import XCTest
import Foundation
@testable import MaterialOrganizer
import OrganizerCore

final class AutomaticDestinationTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let review: ProjectReviewModel
        var source: URL { root.appendingPathComponent("받은 자료") }
        var target: URL { root.appendingPathComponent("자료") }
        init() throws {
            root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesAutomaticDestination-" + UUID().uuidString)
            for name in ["받은 자료", "자료"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            owner = AppModel(demoRootURL: root)
            review = ProjectReviewModel(owner: owner)
            review.contentEnabled = false
        }
        func file(_ name: String, contents: String = "fixture bytes") throws -> URL {
            let url = source.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }
        func cleanup() { owner.releaseFolderAccess(); try? FileManager.default.removeItem(at: root) }
    }

    @MainActor private func idle(_ owner: AppModel, _ review: ProjectReviewModel) async throws {
        for _ in 0..<300 {
            if !owner.busy && !review.isAnalyzing && !review.isPreparing { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Automatic destination operation did not finish")
        throw OrganizerError("Automatic destination timed out")
    }

    @MainActor func testNoProjectAutomaticallyPreviewsOnlyRequiredTypeFoldersAndExecutionCanUndo() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let files = try [fixture.file("notes.txt"), fixture.file("picture.png")]
        let original = try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }
        fixture.review.receive(files)
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.readyCount, 2)
        XCTAssertTrue(fixture.review.savedProjects.isEmpty)
        XCTAssertEqual(fixture.review.automaticLocationRoots.count, 1)
        XCTAssertEqual(Set(fixture.review.rows.compactMap { fixture.review.destinationFolder($0) }),
                       Set([fixture.source.appendingPathComponent("문서").path, fixture.source.appendingPathComponent("이미지").path]))
        XCTAssertTrue(fixture.review.rows.allSatisfy { fixture.review.recommendationReason($0).contains("확장자") })
        fixture.review.prepare()
        try await idle(fixture.owner, fixture.review)
        XCTAssertNil(fixture.review.failure)
        let plan = try XCTUnwrap(fixture.review.preparedPlan)
        XCTAssertEqual(plan.proposals.count, 2)
        XCTAssertEqual(Set(fixture.review.newDirectoryPaths),
                       Set([fixture.source.appendingPathComponent("문서").path, fixture.source.appendingPathComponent("이미지").path]))
        XCTAssertTrue(fixture.review.newDirectoryPaths.allSatisfy { !SafeFileSystem.exists(URL(fileURLWithPath: $0)) })
        XCTAssertEqual(try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }, original)
        XCTAssertTrue(fixture.owner.records.isEmpty)
        fixture.review.executePrepared()
        try await idle(fixture.owner, fixture.review)
        XCTAssertNil(fixture.review.failure)
        let run = try XCTUnwrap(fixture.review.lastRun)
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.movedCount, 2)
        XCTAssertEqual(run.createdDirectories.count, 2)
        XCTAssertTrue(files.allSatisfy { !SafeFileSystem.exists($0) })
        XCTAssertTrue(run.entries.allSatisfy { SafeFileSystem.exists(URL(fileURLWithPath: $0.destination)) })
        fixture.review.undo()
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.lastRun?.state, .undone)
        XCTAssertEqual(try files.map { try SafeFileSystem.snapshot($0, rules: fixture.owner.rules) }, original)
        XCTAssertTrue(run.createdDirectories.allSatisfy { !SafeFileSystem.exists(URL(fileURLWithPath: $0.path)) })
        XCTAssertEqual(fixture.owner.records.count, 1)
    }

    @MainActor func testAmbiguousEvidenceRemainsUnresolvedBesideAnAutomaticFallback() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        for name in ["Atlas", "Boreal"] {
            XCTAssertTrue(fixture.review.saveProject(.init(name: name, rootPath: fixture.target.appendingPathComponent(name).path, template: .byKind), applyToIncluded: false))
        }
        let unknown = try fixture.file("note.txt"), ambiguous = try fixture.file("Atlas-Boreal.txt")
        fixture.review.receive([unknown, ambiguous])
        try await idle(fixture.owner, fixture.review)
        let row = try XCTUnwrap(fixture.review.rows.first { $0.evidence.sourcePath == ambiguous.path })
        XCTAssertEqual(row.evidence.projectMatch, .ambiguous)
        XCTAssertNil(row.projectID)
        XCTAssertNil(fixture.review.destination(row))
        XCTAssertEqual(fixture.review.readyCount, 1)
        XCTAssertEqual(fixture.review.unresolvedCount, 1)
        fixture.review.prepare()
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.preparedPlan?.proposals.map(\.source), [unknown.path])
        XCTAssertTrue(SafeFileSystem.exists(ambiguous))
    }

    @MainActor func testManualExistingDestinationAndExclusionSurviveReanalysisAndReload() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.file("note.txt")
        fixture.review.receive([source])
        try await idle(fixture.owner, fixture.review)
        let rowID = try XCTUnwrap(fixture.review.rows.first).id
        XCTAssertTrue(fixture.review.assignExistingDestination(fixture.target, to: rowID))
        fixture.review.setIncluded(rowID, false)
        fixture.review.analyzeActive()
        try await idle(fixture.owner, fixture.review)
        var row = try XCTUnwrap(fixture.review.rows.first)
        XCTAssertEqual(fixture.review.destinationFolder(row), fixture.target.path)
        XCTAssertTrue(row.explicitlyAssigned)
        XCTAssertFalse(row.included)
        XCTAssertEqual(fixture.review.automaticLocationRoots.count, 1)
        fixture.review.returnToInbox()
        let owner = AppModel(demoRootURL: fixture.root), review: ProjectReviewModel
        review = ProjectReviewModel(owner: owner)
        defer { owner.releaseFolderAccess() }
        XCTAssertTrue(review.storeReadable)
        review.openBatch(try XCTUnwrap(review.batches.first))
        try await idle(owner, review)
        row = try XCTUnwrap(review.rows.first)
        XCTAssertEqual(review.destinationFolder(row), fixture.target.path)
        XCTAssertTrue(row.explicitlyAssigned)
        XCTAssertFalse(row.included)
        XCTAssertEqual(review.recommendationReason(row), "직접 지정한 정리 위치")
        XCTAssertTrue(SafeFileSystem.exists(source))
        XCTAssertTrue(owner.records.isEmpty)
    }

    @MainActor func testManagedLocationNameNeverBecomesSemanticProjectEvidence() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.review.receive([try fixture.file("first.txt")])
        try await idle(fixture.owner, fixture.review)
        let location = try XCTUnwrap(fixture.review.projects.first)
        let file = try fixture.file(location.name + ".txt")
        fixture.review.receive([file])
        try await idle(fixture.owner, fixture.review)
        let row = try XCTUnwrap(fixture.review.rows.first { $0.evidence.sourcePath == file.path })
        XCTAssertEqual(row.evidence.projectMatch, .unknown)
        XCTAssertTrue(row.evidence.projectCandidates.isEmpty)
        XCTAssertEqual(fixture.review.readyCount, 2)
        XCTAssertEqual(fixture.review.automaticLocationRoots.count, 1)
    }

    @MainActor func testNewAmbiguousEvidenceReplacesAutomaticFallbackButNotAnExplicitChoice() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.review.receive([try fixture.file("Atlas-Boreal.txt")])
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.readyCount, 1)
        for name in ["Atlas", "Boreal"] {
            XCTAssertTrue(fixture.review.saveProject(.init(name: name, rootPath: fixture.target.appendingPathComponent(name).path, template: .byKind), applyToIncluded: false))
        }
        fixture.review.analyzeActive()
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.rows.first?.evidence.projectMatch, .ambiguous)
        XCTAssertEqual(fixture.review.readyCount, 0)
        XCTAssertTrue(fixture.review.automaticLocationRoots.isEmpty)
        XCTAssertTrue(fixture.review.assignExistingDestination(fixture.target))
        fixture.review.analyzeActive()
        try await idle(fixture.owner, fixture.review)
        let row = try XCTUnwrap(fixture.review.rows.first)
        XCTAssertEqual(row.evidence.projectMatch, .ambiguous)
        XCTAssertEqual(fixture.review.readyCount, 1)
        XCTAssertEqual(fixture.review.destinationFolder(row), fixture.target.path)
    }

    @MainActor func testProtectedMediaStaysUnmovedWhenAutomaticPrepareRejectsIt() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.file("recording.mp4", contents: "protected original recording")
        fixture.review.receive([source])
        try await idle(fixture.owner, fixture.review)
        XCTAssertEqual(fixture.review.readyCount, 1)
        fixture.review.prepare()
        try await idle(fixture.owner, fixture.review)
        XCTAssertNil(fixture.review.preparedPlan)
        XCTAssertNotNil(fixture.review.failure)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "protected original recording")
        XCTAssertFalse(SafeFileSystem.exists(fixture.source.appendingPathComponent("영상")))
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }

    @MainActor func testProtectedParentCannotReceiveAutomaticFallback() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.owner.rules.protectedPaths.append(fixture.source.path)
        let source = try fixture.file("note.txt")
        fixture.review.receive([source])
        try await idle(fixture.owner, fixture.review)
        let row = try XCTUnwrap(fixture.review.rows.first)
        XCTAssertNil(row.projectID)
        XCTAssertEqual(fixture.review.readyCount, 0)
        XCTAssertTrue(row.evidence.reasons.contains { $0.contains("자동 정리 위치를 준비할 수 없습니다") })
        XCTAssertTrue(fixture.review.projects.isEmpty)
        XCTAssertTrue(SafeFileSystem.exists(source))
    }

    @MainActor func testAutomaticDestinationCollisionRejectsPrepareWithoutOverwriting() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.file("note.txt", contents: "incoming bytes")
        let folder = fixture.source.appendingPathComponent("문서")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let existing = folder.appendingPathComponent("note.txt")
        try Data("existing destination bytes".utf8).write(to: existing)
        fixture.review.receive([source])
        try await idle(fixture.owner, fixture.review)
        fixture.review.prepare()
        try await idle(fixture.owner, fixture.review)
        XCTAssertNil(fixture.review.preparedPlan)
        XCTAssertTrue(fixture.review.failure?.contains("덮어쓰지 않습니다") == true)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "incoming bytes")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing destination bytes")
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }

    func testLegacyReviewStateDecodesWithoutAutomaticLocationMetadata() throws {
        let state = ProjectReviewState(contentEnabled: false)
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("automaticLocationRoots"))
        let restored = try JSONDecoder().decode(ProjectReviewState.self, from: data)
        XCTAssertNil(restored.automaticLocationRoots)
        XCTAssertFalse(restored.contentEnabled)
    }
}
