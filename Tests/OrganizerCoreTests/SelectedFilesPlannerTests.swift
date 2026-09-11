import XCTest
import Foundation
import Darwin
@testable import OrganizerCore

final class SelectedFilesPlannerTests: XCTestCase {
    var root: URL!
    var source: URL { root.appendingPathComponent("Source") }
    var target: URL { root.appendingPathComponent("Organized") }
    var rules: OrganizerRules!
    var engine: Organizer!

    override func setUpWithError() throws {
        root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
            .appendingPathComponent("SelectedFilesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        rules = .standard(home: root)
        engine = Organizer(store: try JournalStore(directory: root.appendingPathComponent("History")))
    }

    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    @discardableResult private func file(_ path: String, parent: URL? = nil, contents: String = "original data") throws -> URL {
        let url = (parent ?? source).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func plan(_ assignments: [SelectedFileDestination], folders: [URL] = [], authorized: [URL] = []) throws -> ScanPlan {
        try SelectedFilesPlanner.plan(assignments: assignments, destinationRoot: target, authorizedSources: authorized,
                                      rules: rules, requiredDirectories: folders)
    }

    private func execute(_ plan: ScanPlan, cancelled: () -> Bool = { false },
                         progress: (EngineProgress) -> Void = { _ in }) throws -> RunRecord {
        try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.map(\.id)), cancelled: cancelled, progress: progress)
    }

    func testMixedExistingAndNewFoldersPreviewDoesNotWriteAndUndoIsExact() throws {
        let existing = target.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let existingIdentity = try SafeFileSystem.identity(at: existing)
        let first = try file("one.png"), second = try file("two.png", parent: root.appendingPathComponent("Other Source"))
        let original = try [first, second].map { try SafeFileSystem.snapshot($0, rules: rules) }
        let nested = target.appendingPathComponent("New Project/Images")
        let empty = target.appendingPathComponent("New Project/Empty/Branch")
        let preview = try plan([.init(source: first, folder: existing), .init(source: second, folder: nested)], folders: [empty])
        XCTAssertEqual(preview.sourceRoots.count, 2)
        XCTAssertEqual(preview.directoryCreationPlan?.existingIdentities[existing.path], existingIdentity)
        XCTAssertFalse(SafeFileSystem.exists(nested)); XCTAssertFalse(SafeFileSystem.exists(empty))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
        let run = try execute(preview)
        XCTAssertEqual(run.state, .completed); XCTAssertEqual(run.movedCount, 2)
        XCTAssertTrue(SafeFileSystem.exists(empty))
        XCTAssertEqual(Set(run.createdDirectories.map(\.path)), Set(["New Project", "New Project/Images", "New Project/Empty", "New Project/Empty/Branch"].map { target.appendingPathComponent($0).path }))
        let reloaded = Organizer(store: try JournalStore(directory: engine.store.directory))
        XCTAssertEqual(try reloaded.undo(run.id).state, .undone)
        XCTAssertEqual(try [first, second].map { try SafeFileSystem.snapshot($0, rules: rules) }, original)
        XCTAssertEqual(try SafeFileSystem.identity(at: existing), existingIdentity)
        XCTAssertFalse(SafeFileSystem.exists(target.appendingPathComponent("New Project")))
    }

    func testFolderOnlyCreationIsDurableAndUndoRemovesOnlyOwnedEmptyBranches() throws {
        let existing = target.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let owned = target.appendingPathComponent("Project/Empty")
        let preview = try SelectedFilesPlanner.folderTreePlan(directories: [existing, owned], destinationRoot: target, rules: rules)
        XCTAssertTrue(preview.proposals.isEmpty); XCTAssertFalse(SafeFileSystem.exists(owned))
        let run = try execute(preview)
        XCTAssertEqual(run.state, .completed); XCTAssertEqual(run.movedCount, 0); XCTAssertTrue(run.canUndo)
        XCTAssertEqual(try engine.store.load(run.id).createdDirectories.count, 2)
        XCTAssertEqual(try engine.inspect(run.id).state, .completed)
        let restored = try engine.undo(run.id)
        XCTAssertEqual(restored.state, .undone); XCTAssertFalse(restored.canUndo)
        XCTAssertFalse(SafeFileSystem.exists(owned)); XCTAssertTrue(SafeFileSystem.exists(existing))
        XCTAssertEqual(try engine.inspect(run.id).state, .undone)
        XCTAssertThrowsError(try engine.undo(run.id))
    }

    func testFolderOnlyUndoPreservesNewUserContentAndReplacementDirectory() throws {
        let occupied = target.appendingPathComponent("Occupied"), replaced = target.appendingPathComponent("Replaced")
        let run = try execute(plan([], folders: [occupied, replaced]))
        let content = try file("added.txt", parent: occupied, contents: "keep this")
        let originalDirectory = target.appendingPathComponent("OriginalDirectory")
        try FileManager.default.moveItem(at: replaced, to: originalDirectory)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
        let replacementIdentity = try SafeFileSystem.identity(at: replaced)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertEqual(try String(contentsOf: content, encoding: .utf8), "keep this")
        XCTAssertEqual(try SafeFileSystem.identity(at: replaced), replacementIdentity)
        XCTAssertTrue(SafeFileSystem.exists(originalDirectory))
    }

    func testExistingParentSwapInMixedPlanStopsBeforeAnyCreationOrMove() throws {
        let existing = target.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let item = try file("a.png"), fresh = target.appendingPathComponent("Fresh/Child")
        let preview = try plan([.init(source: item, folder: existing)], folders: [fresh])
        try FileManager.default.moveItem(at: existing, to: target.appendingPathComponent("Previous"))
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(item)); XCTAssertFalse(SafeFileSystem.exists(fresh))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testExistingIntermediateParentSwapCannotHideBehindNewLeaf() throws {
        let existing = target.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let item = try file("a.png"), leaf = existing.appendingPathComponent("New Leaf")
        let preview = try plan([.init(source: item, folder: leaf)])
        try FileManager.default.moveItem(at: existing, to: target.appendingPathComponent("Previous"))
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertFalse(SafeFileSystem.exists(leaf)); XCTAssertTrue(SafeFileSystem.exists(item))
    }

    func testNewFolderAppearingAfterPreviewStopsWholeBatch() throws {
        let a = try file("a.png"), b = try file("b.png"), fresh = target.appendingPathComponent("Fresh")
        let preview = try plan([.init(source: a, folder: target), .init(source: b, folder: fresh)])
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(a)); XCTAssertTrue(SafeFileSystem.exists(b))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testSourceChangeAndDestinationCollisionStopBeforeFirstMove() throws {
        let a = try file("a.png"), b = try file("b.png")
        let preview = try plan([.init(source: a, folder: target), .init(source: b, folder: target)])
        try Data("changed".utf8).write(to: b)
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(SafeFileSystem.exists(a)); XCTAssertTrue(SafeFileSystem.exists(b))
        let refreshed = try plan([.init(source: a, folder: target), .init(source: b, folder: target)])
        let collision = try file("b.png", parent: target, contents: "unrelated")
        XCTAssertThrowsError(try execute(refreshed))
        XCTAssertTrue(SafeFileSystem.exists(a)); XCTAssertTrue(SafeFileSystem.exists(b))
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "unrelated")
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testCreatedParentSwapAtMoveSyscallPreservesSourceAndRecordsPartialFolders() throws {
        let item = try file("a.png"), folder = target.appendingPathComponent("Created")
        let preview = try plan([.init(source: item, folder: folder)])
        var swapped = false
        let run = try execute(preview, progress: { progress in
            if progress.message.hasPrefix("정리 중"), !swapped {
                swapped = true
                try! FileManager.default.moveItem(at: folder, to: target.appendingPathComponent("Prior Created"))
                try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
        })
        XCTAssertTrue(swapped); XCTAssertEqual(run.state, .interrupted); XCTAssertEqual(run.movedCount, 0)
        XCTAssertEqual(try engine.store.load(run.id).createdDirectories.count, 1)
        XCTAssertTrue(run.canUndo); XCTAssertTrue(SafeFileSystem.exists(item))
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertTrue(SafeFileSystem.exists(folder))
    }

    func testInterruptedFolderOnlyCreationCanUndoPartialRun() throws {
        let first = target.appendingPathComponent("A"), second = target.appendingPathComponent("B")
        let preview = try plan([], folders: [first, second])
        var checks = 0
        let run = try execute(preview, cancelled: { checks += 1; return checks == 2 })
        XCTAssertEqual(run.state, .interrupted); XCTAssertEqual(run.createdDirectories.count, 1)
        XCTAssertTrue(run.canUndo); XCTAssertFalse(SafeFileSystem.exists(second))
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertFalse(SafeFileSystem.exists(first))
    }

    func testInterruptedFilesUndoRestoresCompletedSubsetAndRemovesBlankBranches() throws {
        let a = try file("a.png"), b = try file("b.png"), destination = target.appendingPathComponent("Project/Files")
        let preview = try plan([.init(source: a, folder: destination), .init(source: b, folder: destination)], folders: [target.appendingPathComponent("Project/Empty")])
        var stop = false
        let run = try execute(preview, cancelled: { stop }) { if $0.message == "1개 정리 완료" { stop = true } }
        XCTAssertEqual(run.state, .interrupted); XCTAssertEqual(run.movedCount, 1)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertTrue(SafeFileSystem.exists(a)); XCTAssertTrue(SafeFileSystem.exists(b))
        XCTAssertFalse(SafeFileSystem.exists(target.appendingPathComponent("Project")))
    }

    func testDuplicateFilesHardLinksAndCollidingNamesFailClosed() throws {
        let a = try file("same.png"), b = try file("same.png", parent: root.appendingPathComponent("Other"))
        XCTAssertThrowsError(try plan([.init(source: a, folder: target), .init(source: a, folder: target)]))
        XCTAssertThrowsError(try plan([.init(source: a, folder: target), .init(source: b, folder: target)]))
        let hardlink = source.appendingPathComponent("hardlink.png")
        try FileManager.default.linkItem(at: a, to: hardlink)
        XCTAssertThrowsError(try plan([.init(source: a, folder: target), .init(source: hardlink, folder: target)]))
        XCTAssertThrowsError(try plan([.init(source: a, folder: source)]))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testExpectedIdentityAndCodePackageReferencesStayProtected() throws {
        let item = try file("a.png"), identity = try SafeFileSystem.identity(at: item)
        try FileManager.default.moveItem(at: item, to: source.appendingPathComponent("previous.png"))
        try file("a.png")
        XCTAssertThrowsError(try plan([.init(source: item, folder: target, expectedSourceIdentity: identity)]))
        let project = root.appendingPathComponent("Code Project")
        let asset = try file("Assets/image.png", parent: project)
        try file("package.json", parent: project, contents: "{}")
        XCTAssertThrowsError(try plan([.init(source: asset, folder: target)]))
        let packageAsset = try file("Example.app/Contents/image.png")
        XCTAssertThrowsError(try plan([.init(source: packageAsset, folder: target)]))
        try file("index.md", contents: item.lastPathComponent)
        XCTAssertThrowsError(try plan([.init(source: item, folder: target)]))
    }

    func testConnectedReferenceScopeAndNewReferenceAreChecked() throws {
        let connected = root.appendingPathComponent("Connected")
        let item = try file("Nested/asset.png", parent: connected)
        let reference = try file("index.md", parent: connected, contents: item.path)
        XCTAssertThrowsError(try plan([.init(source: item, folder: target)], authorized: [connected]))
        try FileManager.default.removeItem(at: reference)
        let preview = try plan([.init(source: item, folder: target)], authorized: [connected])
        XCTAssertEqual(preview.sourceRoots, [connected.path])
        try file("index.md", parent: connected, contents: item.path)
        XCTAssertThrowsError(try execute(preview)); XCTAssertTrue(SafeFileSystem.exists(item))
    }

    func testFolderTreeRejectsEscapesSymlinksPackagesAndCaseCollisions() throws {
        XCTAssertThrowsError(try plan([], folders: [root.appendingPathComponent("Outside")]))
        XCTAssertThrowsError(try plan([], folders: [target.appendingPathComponent("Example.app/Contents")]))
        XCTAssertThrowsError(try plan([], folders: [target.appendingPathComponent("package.json")]))
        XCTAssertThrowsError(try plan([], folders: [target.appendingPathComponent("DerivedData-cache")]))
        XCTAssertThrowsError(try plan([], folders: [target.appendingPathComponent("Project"), target.appendingPathComponent("project")]))
        let link = target.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try plan([], folders: [link.appendingPathComponent("Child")]))
        XCTAssertFalse(SafeFileSystem.exists(source.appendingPathComponent("Child")))
    }

    func testLegacyPlanAndRecordDecodeWithoutCreationPlanAndStillUndo() throws {
        let item = try file("Setly-photo.png")
        let legacy = try Planner.analyze(sources: [source], destination: target, rules: rules)
        XCTAssertNil(try JSONDecoder().decode(ScanPlan.self, from: JSONEncoder().encode(legacy)).directoryCreationPlan)
        let run = try execute(legacy)
        XCTAssertNil(try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(run)).directoryCreationPlan)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertTrue(SafeFileSystem.exists(item))
    }

    func testDeselectedFileDoesNotCreateItsDestinationBranch() throws {
        let a = try file("a.png"), b = try file("b.png")
        let selected = target.appendingPathComponent("Selected"), omitted = target.appendingPathComponent("Omitted")
        let preview = try plan([.init(source: a, folder: selected), .init(source: b, folder: omitted)])
        let run = try engine.execute(plan: preview, selectedIDs: [preview.proposals[0].id])
        XCTAssertEqual(run.movedCount, 1); XCTAssertFalse(SafeFileSystem.exists(omitted)); XCTAssertTrue(SafeFileSystem.exists(b))
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
    }

    func testConnectedSourceParentSwapStopsExecutionAndUndo() throws {
        let connected = root.appendingPathComponent("Connected")
        let item = try file("Nested/asset.png", parent: connected)
        let parent = item.deletingLastPathComponent()
        let preview = try plan([.init(source: item, folder: target)], authorized: [connected])
        let saved = connected.appendingPathComponent("Saved")
        try FileManager.default.moveItem(at: parent, to: saved)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: saved.appendingPathComponent(item.lastPathComponent), to: item)
        XCTAssertThrowsError(try execute(preview)); XCTAssertTrue(SafeFileSystem.exists(item))
        let run = try execute(plan([.init(source: item, folder: target)], authorized: [connected]))
        try FileManager.default.moveItem(at: parent, to: connected.appendingPathComponent("Second Saved"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertThrowsError(try engine.undo(run.id))
        XCTAssertFalse(SafeFileSystem.exists(item)); XCTAssertTrue(SafeFileSystem.exists(target.appendingPathComponent(item.lastPathComponent)))
    }

    func testSourceChangeDuringFolderCreationStopsBeforeFirstMove() throws {
        let first = try file("first.png"), second = try file("second.png")
        let preview = try plan([.init(source: first, folder: target), .init(source: second, folder: target)], folders: [target.appendingPathComponent("Blank")])
        var changed = false
        let run = try execute(preview, progress: { progress in
            if progress.message.hasPrefix("폴더 만드는 중"), !changed {
                changed = true
                try! Data("changed after preflight".utf8).write(to: second)
            }
        })
        XCTAssertEqual(run.state, .interrupted); XCTAssertEqual(run.movedCount, 0)
        XCTAssertTrue(SafeFileSystem.exists(first)); XCTAssertTrue(SafeFileSystem.exists(second))
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertFalse(SafeFileSystem.exists(target.appendingPathComponent("Blank")))
    }

    func testInterruptedUndoCanFinishRemovingOwnedFoldersAfterFileRestoration() throws {
        let original = try file("image.png"), folder = target.appendingPathComponent("Project/Images")
        var run = try execute(plan([.init(source: original, folder: folder)]))
        try SafeFileSystem.moveExclusively(from: folder.appendingPathComponent(original.lastPathComponent), to: original,
                                           expectedIdentity: run.entries[0].snapshot.rootIdentity)
        run.entries[0].state = .undoing; run.state = .undoing
        try engine.store.save(run)
        let recovered = try engine.inspect(run.id)
        XCTAssertEqual(recovered.state, .undoing); XCTAssertTrue(recovered.canUndo)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertTrue(SafeFileSystem.exists(original))
        XCTAssertFalse(SafeFileSystem.exists(target.appendingPathComponent("Project")))
    }

    func testSecondSourceParentBecomingReadOnlyStopsBeforeAnyMoveOrFolderCreation() throws {
        let first = try file("first.png")
        let otherSource = root.appendingPathComponent("Other Source")
        let second = try file("second.png", parent: otherSource)
        let originals = try [first, second].map { try SafeFileSystem.snapshot($0, rules: rules) }
        let blank = target.appendingPathComponent("Must Remain Absent")
        let preview = try plan([.init(source: first, folder: target), .init(source: second, folder: target)], folders: [blank])
        XCTAssertEqual(chmod(otherSource.path, 0o555), 0)
        defer { chmod(otherSource.path, 0o755) }
        XCTAssertThrowsError(try execute(preview)) { XCTAssertTrue($0.localizedDescription.contains("접근 권한이 부족")) }
        XCTAssertEqual(try [first, second].map { try SafeFileSystem.snapshot($0, rules: rules) }, originals)
        XCTAssertFalse(SafeFileSystem.exists(target.appendingPathComponent(first.lastPathComponent)))
        XCTAssertFalse(SafeFileSystem.exists(blank))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testSecondDestinationBecomingReadOnlyStopsBeforeAnyMoveOrFolderCreation() throws {
        let first = try file("first.png"), second = try file("second.png")
        let restricted = target.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: false)
        let originalIdentity = try SafeFileSystem.identity(at: restricted)
        let blank = target.appendingPathComponent("Must Remain Absent")
        let preview = try plan([.init(source: first, folder: target), .init(source: second, folder: restricted)], folders: [blank])
        XCTAssertEqual(chmod(restricted.path, 0o555), 0)
        defer { chmod(restricted.path, 0o755) }
        XCTAssertThrowsError(try execute(preview)) { XCTAssertTrue($0.localizedDescription.contains("접근 권한이 부족")) }
        XCTAssertTrue(SafeFileSystem.exists(first)); XCTAssertTrue(SafeFileSystem.exists(second))
        XCTAssertFalse(SafeFileSystem.exists(target.appendingPathComponent(first.lastPathComponent)))
        XCTAssertFalse(SafeFileSystem.exists(blank))
        XCTAssertEqual(try SafeFileSystem.identity(at: restricted), originalIdentity)
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }
}
