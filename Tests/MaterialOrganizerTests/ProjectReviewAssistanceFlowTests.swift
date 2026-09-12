import Foundation
import XCTest
@testable import MaterialOrganizer
import OrganizerCore

final class ProjectReviewAssistanceFlowTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let review: ProjectReviewModel
        var source: URL { root.appendingPathComponent("받은 자료") }
        var otherSource: URL { root.appendingPathComponent("다른 받은 자료") }
        var target: URL { root.appendingPathComponent("자료") }

        init() throws {
            root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesAssistanceFlow-" + UUID().uuidString)
            for directory in ["받은 자료", "다른 받은 자료", "자료"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            owner = AppModel(demoRootURL: root)
            review = ProjectReviewModel(owner: owner)
            review.contentEnabled = false
        }

        func cleanup() {
            owner.releaseFolderAccess()
            try? FileManager.default.removeItem(at: root)
        }

        func file(_ name: String, directory: URL? = nil, contents: String = "unchanged fixture bytes") throws -> URL {
            let url = (directory ?? source).appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        func project(_ name: String = "Atlas", template: ProjectTemplate = .byKind) -> ProjectDefinition {
            .init(name: name, rootPath: target.appendingPathComponent(name).path, template: template)
        }

        func rule(for project: ProjectDefinition, prefix: String, folder: String) -> ProjectReviewRule {
            .init(sourceDirectory: source.path, filenamePrefix: prefix, fileExtension: "txt", projectID: project.id,
                  projectRootPath: project.rootPath, folder: folder)
        }
    }

    @MainActor private func waitUntilIdle(owner: AppModel, review: ProjectReviewModel,
                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if !owner.busy && !review.isAnalyzing && !review.isPreparing { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Assistance flow did not become idle within 60 seconds", file: file, line: line)
        throw OrganizerError("Assistance flow timed out")
    }

    @MainActor private func waitUntilIdle(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntilIdle(owner: fixture.owner, review: fixture.review, file: file, line: line)
    }

    @MainActor private func row(_ review: ProjectReviewModel, at source: URL,
                                file: StaticString = #filePath, line: UInt = #line) throws -> ProjectReviewRow {
        try XCTUnwrap(review.rows.first { $0.evidence.sourcePath == source.path }, file: file, line: line)
    }

    @MainActor func testOnlyExplicitRuleSavePersistsAndRecommendsWithinSourcePrefixAndExtensionAfterReload() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let seed = try fixture.file("client_001.txt")
        fixture.review.receive([seed])
        try await waitUntilIdle(fixture)
        fixture.review.assignProject(project.id)
        fixture.review.assignFolder("기타")
        XCTAssertEqual(fixture.review.readyCount, 1)
        XCTAssertTrue(fixture.review.assistance.rules.isEmpty)
        XCTAssertTrue(fixture.owner.records.isEmpty)
        XCTAssertTrue(fixture.review.rememberRule(prefix: "client_"))
        try await waitUntilIdle(fixture)
        let saved = try XCTUnwrap(fixture.review.assistance.rules.first)
        XCTAssertEqual(saved.sourceDirectory, fixture.source.path)
        XCTAssertEqual(saved.fileExtension, "txt")
        fixture.review.returnToInbox()
        XCTAssertTrue(fixture.review.persist())

        let owner = AppModel(demoRootURL: fixture.root)
        let review = ProjectReviewModel(owner: owner)
        defer { owner.releaseFolderAccess() }
        XCTAssertTrue(review.storeReadable)
        XCTAssertTrue(review.assistance.storeReadable)
        XCTAssertEqual(review.assistance.rules, [saved])
        let matching = try fixture.file("client_002.txt")
        let otherParent = try fixture.file("client_003.txt", directory: fixture.otherSource)
        let otherExtension = try fixture.file("client_004.png")
        let otherPrefix = try fixture.file("unrelated_005.txt")
        review.receive([matching, otherParent, otherExtension, otherPrefix])
        try await waitUntilIdle(owner: owner, review: review)
        let recommended = try row(review, at: matching)
        XCTAssertEqual(recommended.projectID, project.id)
        XCTAssertEqual(review.project(recommended.projectID)?.rootPath, project.rootPath)
        XCTAssertEqual(recommended.folder, "기타")
        XCTAssertNotNil(recommended.ruleReason)
        XCTAssertFalse(recommended.explicitlyAssigned)
        for source in [otherParent, otherExtension, otherPrefix] {
            let outside = try row(review, at: source)
            XCTAssertNotEqual(outside.projectID, project.id)
            XCTAssertNotEqual(review.project(outside.projectID)?.rootPath, project.rootPath)
            XCTAssertNil(outside.ruleReason)
        }
        XCTAssertEqual(review.pendingCount, 5)
        XCTAssertTrue([seed, matching, otherParent, otherExtension, otherPrefix].allSatisfy { SafeFileSystem.exists($0) })
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertTrue(owner.records.isEmpty)
    }

    @MainActor func testConflictingRulesHoldWholeGroupUntilExplicitProjectAndFolderChoice() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let atlas = fixture.project(template: .simple), boreal = fixture.project("Boreal", template: .simple)
        XCTAssertTrue(fixture.review.saveProject(atlas, applyToIncluded: false))
        XCTAssertTrue(fixture.review.saveProject(boreal, applyToIncluded: false))
        XCTAssertTrue(fixture.review.assistance.save(fixture.rule(for: atlas, prefix: "shared_", folder: "참고자료")))
        XCTAssertTrue(fixture.review.assistance.save(fixture.rule(for: boreal, prefix: "shared_", folder: "참고자료")))
        let sources = try [fixture.file("shared_01.txt"), fixture.file("shared_02.txt")]
        fixture.review.receive(sources)
        try await waitUntilIdle(fixture)
        XCTAssertTrue(fixture.review.rows.allSatisfy(\.ruleConflict))
        XCTAssertEqual(fixture.review.readyCount, 0)
        XCTAssertFalse(fixture.review.canPreview)
        let conflicted = try XCTUnwrap(fixture.review.clarificationGroups.first { $0.rowIDs.count == 2 })
        fixture.review.assignProject(atlas.id, toGroup: conflicted.id)
        XCTAssertTrue(fixture.review.rows.allSatisfy { $0.projectID == atlas.id && !$0.ruleConflict && $0.folder == nil })
        XCTAssertEqual(fixture.review.readyCount, 0)
        let needsFolder = try XCTUnwrap(fixture.review.clarificationGroups.first { $0.rowIDs.count == 2 })
        fixture.review.assignFolder("참고자료", toGroup: needsFolder.id)
        XCTAssertEqual(fixture.review.readyCount, 2)
        XCTAssertTrue(fixture.review.rows.allSatisfy { $0.explicitlyAssigned && !$0.ruleConflict && $0.folder == "참고자료" })
        fixture.review.analyzeActive()
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.readyCount, 2)
        XCTAssertTrue(fixture.review.rows.allSatisfy { $0.projectID == atlas.id && $0.explicitlyAssigned && !$0.ruleConflict })
        XCTAssertEqual(fixture.review.assistance.rules.count, 2)
        XCTAssertTrue(sources.allSatisfy { SafeFileSystem.exists($0) })
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }

    @MainActor func testDisablingAndRemovingRuleRecomputeRecommendationsWhileManualChoiceSurvives() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let saved = fixture.rule(for: project, prefix: "Atlas_packet_", folder: "기타")
        XCTAssertTrue(fixture.review.assistance.save(saved))
        let source = try fixture.file("Atlas_packet_02.txt")
        fixture.review.receive([source])
        try await waitUntilIdle(fixture)
        var selected = try row(fixture.review, at: source)
        XCTAssertEqual(selected.projectID, project.id)
        XCTAssertEqual(selected.folder, "기타")
        XCTAssertFalse(selected.explicitlyAssigned)
        XCTAssertNotNil(selected.ruleReason)

        fixture.review.setRuleEnabled(saved.id, false)
        try await waitUntilIdle(fixture)
        selected = try row(fixture.review, at: source)
        XCTAssertEqual(selected.projectID, project.id)
        XCTAssertEqual(selected.folder, "문서")
        XCTAssertNil(selected.ruleReason)
        XCTAssertFalse(selected.explicitlyAssigned)
        fixture.review.setRuleEnabled(saved.id, true)
        try await waitUntilIdle(fixture)
        XCTAssertEqual(try row(fixture.review, at: source).folder, "기타")

        fixture.review.removeRule(saved.id)
        try await waitUntilIdle(fixture)
        selected = try row(fixture.review, at: source)
        XCTAssertEqual(selected.folder, "문서")
        XCTAssertNil(selected.ruleReason)
        XCTAssertTrue(fixture.review.assistance.rules.isEmpty)
        fixture.review.assignFolder("이미지", to: selected.id)
        fixture.review.analyzeActive()
        try await waitUntilIdle(fixture)
        selected = try row(fixture.review, at: source)
        XCTAssertEqual(selected.projectID, project.id)
        XCTAssertEqual(selected.folder, "이미지")
        XCTAssertTrue(selected.explicitlyAssigned)
        XCTAssertFalse(selected.ruleConflict)
        XCTAssertTrue(fixture.review.assistance.rules.isEmpty)
        XCTAssertTrue(SafeFileSystem.exists(source))
    }

    @MainActor func testEditingRuleDestinationRootOrRemovingFolderImmediatelyHoldsExistingRecommendation() async throws {
        for change in ["root", "folder"] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let project = fixture.project(template: .simple)
            XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
            let saved = fixture.rule(for: project, prefix: "delivery_", folder: "참고자료")
            XCTAssertTrue(fixture.review.assistance.save(saved))
            let source = try fixture.file("delivery_01.txt")
            let original = try SafeFileSystem.snapshot(source, rules: fixture.owner.rules)
            fixture.review.receive([source])
            try await waitUntilIdle(fixture)
            let recommended = try row(fixture.review, at: source)
            XCTAssertFalse(recommended.explicitlyAssigned)
            XCTAssertNotNil(recommended.ruleReason)
            XCTAssertEqual(fixture.review.readyCount, 1)

            var edited = project
            if change == "root" { edited.rootPath = fixture.target.appendingPathComponent("AtlasMoved").path }
            else { edited.folders = ["작업파일", "결과물"] }
            XCTAssertTrue(fixture.review.saveProject(edited, applyToIncluded: false), change)
            // Saving the changed project must invalidate the current recommendation synchronously.
            let held = try row(fixture.review, at: source)
            XCTAssertTrue(held.ruleConflict, change)
            XCTAssertFalse(held.explicitlyAssigned, change)
            XCTAssertEqual(fixture.review.readyCount, 0, change)
            XCTAssertFalse(fixture.review.canPreview, change)
            XCTAssertEqual(fixture.review.assistance.rules, [saved], change)
            fixture.review.prepare()
            try await waitUntilIdle(fixture)
            XCTAssertNil(fixture.review.preparedPlan, change)
            fixture.review.executePrepared()
            try await waitUntilIdle(fixture)
            XCTAssertTrue(fixture.owner.records.isEmpty, change)
            XCTAssertEqual(try SafeFileSystem.snapshot(source, rules: fixture.owner.rules), original, change)
            XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)), change)
            XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: edited.rootPath)), change)
        }
    }

    @MainActor func testUnicodeCaseFoldPreviewExplicitSaveAndNewBatchRecommendationUseSameScopeWithoutMoving() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project(template: .simple)
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let seed = try fixture.file("Straße_01.txt", contents: "Unicode rule preview sample")
        let originalSeed = try SafeFileSystem.snapshot(seed, rules: fixture.owner.rules)
        fixture.review.receive([seed])
        try await waitUntilIdle(fixture)
        fixture.review.assignProject(project.id)
        fixture.review.assignFolder("결과물")
        XCTAssertTrue(fixture.review.assistance.rules.isEmpty)
        XCTAssertEqual(fixture.review.ruleMatchingNames(prefix: "STRASSE_"), [seed.lastPathComponent])
        XCTAssertTrue(fixture.review.rememberRule(prefix: "STRASSE_"))
        try await waitUntilIdle(fixture)
        let saved = try XCTUnwrap(fixture.review.assistance.rules.first)
        XCTAssertEqual(saved.filenamePrefix, "STRASSE_")
        XCTAssertEqual(saved.sourceDirectory, fixture.source.path)
        XCTAssertEqual(saved.projectRootPath, project.rootPath)
        XCTAssertEqual(saved.folder, "결과물")
        XCTAssertEqual(try SafeFileSystem.snapshot(seed, rules: fixture.owner.rules), originalSeed)
        fixture.review.returnToInbox()

        let source = try fixture.file("Straße_02.txt", contents: "new Unicode rule matching sample")
        let original = try SafeFileSystem.snapshot(source, rules: fixture.owner.rules)
        fixture.review.receive([source])
        try await waitUntilIdle(fixture)
        let recommended = try row(fixture.review, at: source)
        XCTAssertEqual(recommended.projectID, project.id)
        XCTAssertEqual(fixture.review.project(recommended.projectID)?.rootPath, saved.projectRootPath)
        XCTAssertEqual(recommended.folder, saved.folder)
        XCTAssertFalse(recommended.explicitlyAssigned)
        XCTAssertNotNil(recommended.ruleReason)
        XCTAssertFalse(recommended.ruleConflict)
        XCTAssertEqual(fixture.review.readyCount, 1)
        XCTAssertEqual(fixture.review.assistance.rules, [saved])
        XCTAssertNil(fixture.review.preparedPlan)
        XCTAssertNil(fixture.review.lastRun)
        XCTAssertTrue(fixture.owner.records.isEmpty)
        XCTAssertEqual(try SafeFileSystem.snapshot(source, rules: fixture.owner.rules), original)
        XCTAssertEqual(try SafeFileSystem.snapshot(seed, rules: fixture.owner.rules), originalSeed)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
    }

    @MainActor func testSimpleTemplateGroupAssignmentSkipsExcludedFilesAndDeferralPreservesQueue() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project(template: .simple)
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let first = try fixture.file("Atlas_01.txt"), second = try fixture.file("Atlas_02.txt")
        let excluded = try fixture.file("Atlas_03.txt"), deferred = try fixture.file("Atlas_held.png")
        let sources = [first, second, excluded, deferred]
        fixture.review.receive(sources)
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.readyCount, 0)
        XCTAssertTrue(fixture.review.rows.allSatisfy { $0.projectID == project.id && $0.folder == nil })
        fixture.review.setIncluded(try row(fixture.review, at: excluded).id, false)
        let documentGroup = try XCTUnwrap(fixture.review.clarificationGroups.first { Set($0.names) == Set([first.lastPathComponent, second.lastPathComponent]) })
        fixture.review.assignFolder("참고자료", toGroup: documentGroup.id)
        XCTAssertEqual(fixture.review.readyCount, 2)
        let excludedRow = try row(fixture.review, at: excluded)
        XCTAssertFalse(excludedRow.included)
        XCTAssertFalse(excludedRow.explicitlyAssigned)
        XCTAssertNil(excludedRow.folder)
        let heldGroup = try XCTUnwrap(fixture.review.clarificationGroups.first { $0.names == [deferred.lastPathComponent] })
        fixture.review.deferGroup(heldGroup.id)
        XCTAssertFalse(try row(fixture.review, at: deferred).included)
        XCTAssertEqual(fixture.review.pendingCount, 4)
        fixture.review.returnToInbox()
        let batch = try XCTUnwrap(fixture.review.batches.first)
        XCTAssertEqual(Set(batch.files.map(\.path)), Set(sources.map(\.path)))
        fixture.review.openBatch(batch)
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.review.readyCount, 2)
        XCTAssertEqual(try row(fixture.review, at: first).folder, "참고자료")
        XCTAssertEqual(try row(fixture.review, at: second).folder, "참고자료")
        XCTAssertFalse(try row(fixture.review, at: excluded).included)
        XCTAssertFalse(try row(fixture.review, at: deferred).included)
        XCTAssertTrue(fixture.review.assistance.rules.isEmpty)
        XCTAssertTrue(sources.allSatisfy { SafeFileSystem.exists($0) })
        XCTAssertTrue(fixture.owner.records.isEmpty)
    }

    @MainActor func testChangedSourceInvalidatesExplicitChoiceExcludesFileAndPreventsExecution() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project(template: .simple)
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let source = try fixture.file("unknown_01.txt", contents: "initial source")
        fixture.review.receive([source])
        try await waitUntilIdle(fixture)
        fixture.review.assignProject(project.id)
        fixture.review.assignFolder("참고자료")
        let selected = try row(fixture.review, at: source)
        XCTAssertTrue(selected.explicitlyAssigned)
        XCTAssertEqual(fixture.review.readyCount, 1)
        let identity = try SafeFileSystem.identity(at: source)
        let replacement = Data("revised and longer source content".utf8)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()
        XCTAssertEqual(try SafeFileSystem.identity(at: source), identity)
        fixture.review.analyzeActive()
        try await waitUntilIdle(fixture)
        let changed = try row(fixture.review, at: source)
        XCTAssertFalse(changed.explicitlyAssigned)
        XCTAssertFalse(changed.included)
        XCTAssertNotEqual(changed.evidence.sourceVersion, selected.evidence.sourceVersion)
        XCTAssertNotEqual(changed.projectID, project.id)
        XCTAssertEqual(fixture.review.readyCount, 0)
        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.preparedPlan)
        fixture.review.executePrepared()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.lastRun)
        XCTAssertTrue(fixture.owner.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertEqual(try SafeFileSystem.identity(at: source), identity)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
    }

    @MainActor func testExplicitlySavedRuleNewBatchPreviewMoveAndUndoPreserveBytesAndIdentity() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let project = fixture.project(template: .simple)
        XCTAssertTrue(fixture.review.saveProject(project, applyToIncluded: false))
        let seed = try fixture.file("delivery_01.txt", contents: "rule selection sample remains in its original folder")
        fixture.review.receive([seed])
        try await waitUntilIdle(fixture)
        fixture.review.assignProject(project.id)
        fixture.review.assignFolder("결과물")
        XCTAssertTrue(fixture.review.rememberRule(prefix: "delivery_"))
        try await waitUntilIdle(fixture)
        XCTAssertTrue(fixture.owner.records.isEmpty)
        fixture.review.returnToInbox()

        let source = try fixture.file("delivery_02.txt", contents: "newly received payload with exact bytes to preserve")
        let original = try SafeFileSystem.snapshot(source, rules: fixture.owner.rules)
        let identity = try SafeFileSystem.identity(at: source)
        fixture.review.receive([source])
        try await waitUntilIdle(fixture)
        let recommended = try row(fixture.review, at: source)
        XCTAssertEqual(recommended.projectID, project.id)
        XCTAssertEqual(recommended.folder, "결과물")
        XCTAssertFalse(recommended.explicitlyAssigned)
        XCTAssertNotNil(recommended.ruleReason)
        XCTAssertEqual(fixture.review.readyCount, 1)
        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        let plan = try XCTUnwrap(fixture.review.preparedPlan)
        XCTAssertEqual(plan.proposals.map(\.source), [source.path])
        XCTAssertEqual(try SafeFileSystem.snapshot(source, rules: fixture.owner.rules), original)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertTrue(fixture.owner.records.isEmpty)
        fixture.review.executePrepared()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        let run = try XCTUnwrap(fixture.review.lastRun)
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.movedCount, 1)
        let destination = URL(fileURLWithPath: try XCTUnwrap(run.entries.first).destination)
        XCTAssertEqual(destination.deletingLastPathComponent().path, URL(fileURLWithPath: project.rootPath).appendingPathComponent("결과물").path)
        XCTAssertEqual(try SafeFileSystem.identity(at: destination), identity)
        XCTAssertEqual(try SafeFileSystem.snapshot(destination, rules: fixture.owner.rules), original)
        XCTAssertFalse(SafeFileSystem.exists(source))
        XCTAssertTrue(SafeFileSystem.exists(seed))
        fixture.review.undo()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        XCTAssertEqual(fixture.review.lastRun?.state, .undone)
        XCTAssertEqual(try SafeFileSystem.identity(at: source), identity)
        XCTAssertEqual(try SafeFileSystem.snapshot(source, rules: fixture.owner.rules), original)
        XCTAssertTrue(SafeFileSystem.exists(seed))
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: project.rootPath)))
        XCTAssertEqual(fixture.owner.records.count, 1)
    }
}
