import XCTest
import Foundation
@testable import OrganizerCore

final class OrganizerCoreTests: XCTestCase {
    var root: URL!
    var source: URL { root.appendingPathComponent("받은 자료") }
    var target: URL { root.appendingPathComponent("자료") }
    var rules: OrganizerRules!
    var engine: Organizer!
    override func setUpWithError() throws {
        root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory).appendingPathComponent("OrganizerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        rules = .standard(home: root)
        engine = Organizer(store: try JournalStore(directory: root.appendingPathComponent("History")))
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    @discardableResult func file(_ name: String, _ content: String = "original-content") throws -> URL {
        let url = source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url); return url
    }
    func plan() throws -> ScanPlan { try Planner.analyze(sources: [source], destination: target, rules: rules) }
    func execute(_ plan: ScanPlan) throws -> RunRecord { try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.filter { $0.decision.executable }.map(\.id))) }
    func testFolderDateAndUnicodeRule() throws {
        XCTAssertEqual(try rules.normalFolderName("TasteBuddy-리서치-2026-09-08", removing: "TasteBuddy"), "2026-09-08 리서치")
        XCTAssertEqual(try rules.normalFolderName("Setly---2026-02-30---메모", removing: "Setly"), "2026 02 30 메모")
        XCTAssertFalse(OrganizerRules.hasPrefix("Orange", "O"))
        XCTAssertTrue(OrganizerRules.hasPrefix("O-기록", "O"))
        XCTAssertThrowsError(try PathSafety.validateComponent("../escape"))
    }
    func testSuccessfulMoveUndoRetainsEveryByteAndIdentity() throws {
        let folder = try file("TasteBuddy-리서치-2026-09-08/note.md").deletingLastPathComponent()
        let standalone = try file("Withings-2026-09-08.png", "image-placeholder")
        let beforeFolder = try SafeFileSystem.snapshot(folder, rules: rules)
        let beforeFile = try SafeFileSystem.snapshot(standalone, rules: rules)
        let preview = try plan()
        XCTAssertEqual(preview.proposals.filter { $0.decision.executable }.count, 2)
        let run = try execute(preview)
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.movedCount, 2)
        XCTAssertFalse(SafeFileSystem.exists(folder))
        XCTAssertTrue(SafeFileSystem.exists(target.appendingPathComponent("Taste Buddy/2026-09-08 리서치/note.md")))
        let undo = try engine.undo(run.id)
        XCTAssertEqual(undo.state, .undone)
        XCTAssertEqual(try SafeFileSystem.snapshot(folder, rules: rules), beforeFolder)
        XCTAssertEqual(try SafeFileSystem.snapshot(standalone, rules: rules), beforeFile)
        XCTAssertFalse(SafeFileSystem.exists(target))
        XCTAssertThrowsError(try engine.undo(run.id))
    }
    func testCodeProjectsAndNestedOriginalsAreProtected() throws {
        try file("Setly-코드/package.json", "{}")
        try file("Setly-외부/nested/Package.swift", "code")
        try file("Setly-원본/recording.mov", "video")
        try file("Setly-자료/key.pem", "secret-placeholder")
        let preview = try plan()
        XCTAssertTrue(preview.proposals.allSatisfy { !$0.decision.executable && !$0.canAssignCategory })
    }
    func testProtectedDescendantDoesNotPreventSiblingOrganization() throws {
        let protected = try file("Setly-보호/readme.txt").deletingLastPathComponent()
        rules.protectedPaths.append(protected.path)
        try file("Setly-정리/readme.txt")
        let preview = try plan()
        XCTAssertEqual(preview.proposals.first { $0.name == "Setly-보호" }?.decision, .keep)
        XCTAssertEqual(preview.proposals.first { $0.name == "Setly-정리" }?.decision, .move)
        let run = try execute(preview); XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
    }
    func testRootProjectCannotBeScannedForMoves() throws {
        try file("package.json", "{}")
        try file("Setly-picture.png")
        XCTAssertTrue(try plan().proposals.allSatisfy { !$0.decision.executable })
    }
    func testLinksAndHiddenFilesRemainInPlace() throws {
        let external = root.appendingPathComponent("external")
        try Data("real".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Setly-linked.png"), withDestinationURL: external)
        try file(".Setly-secret.txt")
        try file("Setly-bundle.app/Contents/info.txt")
        XCTAssertTrue(try plan().proposals.allSatisfy { !$0.decision.executable })
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "real")
    }
    func testUnknownRequiresExplicitCategory() throws {
        try file("이름없는-노트.txt")
        var preview = try plan()
        let item = try XCTUnwrap(preview.proposals.first)
        XCTAssertEqual(item.decision, .review); XCTAssertTrue(item.canAssignCategory)
        XCTAssertThrowsError(try execute(preview))
        try Planner.assignCategory("개인", proposalID: item.id, plan: &preview)
        XCTAssertEqual(preview.proposals[0].decision, .move)
        let run = try execute(preview); XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
    }
    func testCollisionAfterPreviewStopsWholeBatch() throws {
        let first = try file("Setly-a.png"), second = try file("Setly-b.png")
        let preview = try plan()
        let collision = URL(fileURLWithPath: try XCTUnwrap(preview.proposals.last?.destination))
        try FileManager.default.createDirectory(at: collision.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other".utf8).write(to: collision)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(first)); XCTAssertTrue(SafeFileSystem.exists(second))
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "other")
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }
    func testFingerprintDetectsChangedBytesWithRestoredDateAndSize() throws {
        let url = try file("Setly-note.txt", "abcde")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let preview = try plan()
        try Data("ABCDE".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: url.path)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(url))
    }
    func testReferencesInOtherDocumentsPreserveSource() throws {
        try file("Setly-자료/note.txt")
        try file("index.md", "See Setly-자료 for details")
        let item = try XCTUnwrap(try plan().proposals.first { $0.name == "Setly-자료" })
        XCTAssertEqual(item.decision, .keep); XCTAssertFalse(item.canAssignCategory)
    }
    func testNewReferenceAfterPreviewPreventsMove() throws {
        let url = try file("Setly-image.png")
        let preview = try plan()
        try file("index.md", url.path)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(url))
    }
    func testIncompleteReferenceIndexFailsClosed() throws {
        rules.maximumReferenceFiles = 1
        try file("Setly-a.txt"); try file("Setly-b.txt")
        let preview = try plan()
        XCTAssertFalse(preview.warnings.isEmpty)
        XCTAssertTrue(preview.proposals.allSatisfy { !$0.decision.executable && !$0.canAssignCategory })
    }
    func testSnapshotLimitDoesNotOfferManualBypass() throws {
        rules.maximumSnapshotBytes = 2
        try file("Setly-big.png", "1234")
        let item = try XCTUnwrap(try plan().proposals.first)
        XCTAssertEqual(item.decision, .review); XCTAssertFalse(item.canAssignCategory)
    }
    func testUndoSourceCollisionPreservesBothFiles() throws {
        let url = try file("Setly-a.png")
        let run = try execute(plan())
        try Data("new source".utf8).write(to: url)
        XCTAssertThrowsError(try engine.undo(run.id))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new source")
        XCTAssertEqual(try String(contentsOfFile: run.entries[0].destination, encoding: .utf8), "original-content")
    }
    func testUndoEditedDestinationStopsWholeBatch() throws {
        let original = try file("Setly-a.png"); try file("Setly-b.png")
        let run = try execute(plan())
        try Data("edited".utf8).write(to: URL(fileURLWithPath: run.entries[0].destination))
        XCTAssertThrowsError(try engine.undo(run.id))
        XCTAssertFalse(SafeFileSystem.exists(original))
        XCTAssertTrue(run.entries.allSatisfy { SafeFileSystem.exists(URL(fileURLWithPath: $0.destination)) })
        XCTAssertEqual(try engine.store.load(run.id).state, .attention)
    }
    func testCancelledRunCanUndoOnlyCompletedMoves() throws {
        try file("Setly-a.png"); try file("Setly-b.png")
        let preview = try plan(); var stop = false
        let run = try engine.execute(plan: preview, selectedIDs: Set(preview.proposals.map(\.id)), cancelled: { stop }, progress: { value in if value.message == "1개 정리 완료" { stop = true } })
        XCTAssertEqual(run.state, .interrupted); XCTAssertEqual(run.movedCount, 1)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertTrue(SafeFileSystem.exists(source.appendingPathComponent("Setly-a.png")))
        XCTAssertTrue(SafeFileSystem.exists(source.appendingPathComponent("Setly-b.png")))
    }
    func testRecoverJournalWrittenBeforeMoveCompletion() throws {
        try file("Setly-a.png")
        var run = try execute(plan())
        run.entries[0].state = .moving; run.state = .running
        try engine.store.save(run)
        let reopened = Organizer(store: try JournalStore(directory: engine.store.directory))
        XCTAssertEqual(try reopened.inspect(run.id).state, .completed)
        XCTAssertEqual(try reopened.undo(run.id).state, .undone)
    }
    func testRecoverJournalDuringUndo() throws {
        try file("Setly-a.png")
        var run = try execute(plan())
        _ = try engine.undo(run.id)
        run.entries[0].state = .undoing; run.state = .undoing
        try engine.store.save(run)
        XCTAssertEqual(try engine.inspect(run.id).state, .undone)
    }
    func testUndoKeepsNewFileInsideCreatedDirectory() throws {
        try file("Setly-a.png")
        let run = try execute(plan())
        let extra = target.appendingPathComponent("Setly/new.txt")
        try Data("keep me".utf8).write(to: extra)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertEqual(try String(contentsOf: extra, encoding: .utf8), "keep me")
    }
    func testDuplicateDestinationsCannotExecute() throws {
        let a = source.appendingPathComponent("one"), b = source.appendingPathComponent("two")
        try file("one/Setly-a.png"); try file("two/Setly-a.png")
        let preview = try Planner.analyze(sources: [a,b], destination: target, rules: rules)
        XCTAssertTrue(preview.proposals.allSatisfy { $0.decision == .review })
        XCTAssertThrowsError(try execute(preview))
    }
    func testTamperedPlanOutsideSourceScopeCannotExecute() throws {
        let url = try file("Setly-a.png")
        var preview = try plan()
        let outside = root.appendingPathComponent("Setly-outside.png")
        try Data("outside".utf8).write(to: outside)
        preview.proposals[0].source = outside.path
        preview.proposals[0].snapshot = try SafeFileSystem.snapshot(outside, rules: rules)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(outside)); XCTAssertTrue(SafeFileSystem.exists(url))
    }
    func testReplacedSourceRootSymlinkCannotExecute() throws {
        try file("Setly-a.png")
        let preview = try plan()
        let moved = root.appendingPathComponent("moved-source")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(moved.appendingPathComponent("Setly-a.png")))
    }
    func testReplacedJournalStoragePreventsMoves() throws {
        let url = try file("Setly-a.png")
        let preview = try plan()
        let storeURL = engine.store.directory
        try FileManager.default.moveItem(at: storeURL, to: root.appendingPathComponent("OldHistory"))
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try execute(preview)); XCTAssertTrue(SafeFileSystem.exists(url))
    }
    func testOverlappingSourcesAreScannedOnce() throws {
        try file("Setly-folder/note.txt")
        let preview = try Planner.analyze(sources: [source,source.appendingPathComponent("Setly-folder"),source], destination: target, rules: rules)
        XCTAssertEqual(preview.sourceRoots.count, 1); XCTAssertEqual(preview.proposals.count, 1)
    }
    func testNewProjectAtSourceRootPreventsExecution() throws {
        let url = try file("Setly-a.png")
        let preview = try plan()
        try file("package.json", "{}")
        XCTAssertThrowsError(try execute(preview)); XCTAssertTrue(SafeFileSystem.exists(url))
    }
}
