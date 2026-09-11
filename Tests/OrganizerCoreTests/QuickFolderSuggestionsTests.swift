import XCTest
@testable import OrganizerCore

final class QuickFolderSuggestionsTests: XCTestCase {
    private var root: URL!
    private var rules: OrganizerRules!
    override func setUpWithError() throws {
        root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory).appendingPathComponent("TilesQuickMove-" + UUID().uuidString)
        for name in ["inbox", "saved", "common"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        rules = .standard(home: root)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("inbox/" + name)
        try Data("quick-move-fixture".utf8).write(to: url)
        return url
    }
    func testSavedPrefixWinsWithoutInventingMissingFoldersOrIncludingCurrentFolder() throws {
        let source = try file("Research-note.txt")
        let saved = root.appendingPathComponent("saved"), common = root.appendingPathComponent("common")
        let remembered = [FolderSuggestionRule(prefix: "Research", folderPath: saved.path),
                          FolderSuggestionRule(prefix: "Research", folderPath: root.appendingPathComponent("missing").path)]
        let items = try QuickFolderSuggestions.recommendations(source: source, catalogue: [], rules: rules, remembered: remembered,
                                                              commonFolders: [source.deletingLastPathComponent(), common, saved])
        XCTAssertEqual(items.map(\.id), [saved.path, common.path])
        XCTAssertTrue(items[0].reason.contains("Research"))
        XCTAssertFalse(SafeFileSystem.exists(root.appendingPathComponent("missing")))
        let unmatched = try file("Researcher-note.txt")
        XCTAssertTrue(try QuickFolderSuggestions.recommendations(source: unmatched, catalogue: [], rules: rules, remembered: remembered, commonFolders: []).isEmpty)
    }
    func testPickedFolderMovesAndUndoReloadsWithoutRegisteredSource() throws {
        let source = try file("Note.txt"), target = root.appendingPathComponent("saved")
        let before = try SafeFileSystem.snapshot(source, rules: rules)
        let folder = try XCTUnwrap(QuickFolderSuggestions.destination(target, rules: rules))
        let plan = try Planner.singleFilePlan(source: source, folder: folder, registeredRoot: target, rules: rules, expectedSourceIdentity: before.rootIdentity)
        let journal = root.appendingPathComponent("History")
        let engine = Organizer(store: try JournalStore(directory: journal))
        let run = try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.map(\.id)))
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.entries.first?.source, source.path)
        XCTAssertFalse(SafeFileSystem.exists(source))
        let reloaded = Organizer(store: try JournalStore(directory: journal))
        XCTAssertEqual(try reloaded.undo(run.id).state, .undone)
        XCTAssertEqual(try SafeFileSystem.snapshot(source, rules: rules), before)
    }
    func testProtectedAndReplacedDestinationsDoNotBecomeMoveTargets() throws {
        let source = try file("Note.txt"), target = root.appendingPathComponent("saved")
        var protected = rules!
        protected.protectedPaths = [target.path]
        XCTAssertNil(QuickFolderSuggestions.destination(target, rules: protected))
        let folder = try XCTUnwrap(QuickFolderSuggestions.destination(target, rules: rules))
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("old-saved"))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try Planner.singleFilePlan(source: source, folder: folder, registeredRoot: target, rules: rules))
        XCTAssertTrue(SafeFileSystem.exists(source))
    }
}
