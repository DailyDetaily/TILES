import XCTest
import Foundation
import CoreGraphics
import Darwin
@testable import OrganizerCore

final class FolderOverlayTests: XCTestCase {
    var root: URL!
    var source: URL { root.appendingPathComponent("받은 자료") }
    var target: URL { root.appendingPathComponent("자료") }
    var rules: OrganizerRules!
    var engine: Organizer!
    override func setUpWithError() throws {
        root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory).appendingPathComponent("FolderOverlayTests-" + UUID().uuidString)
        for path in [source, target, target.appendingPathComponent("Setly"), target.appendingPathComponent("참고"), target.appendingPathComponent("개인")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        rules = .standard(home: root)
        engine = Organizer(store: try JournalStore(directory: root.appendingPathComponent("History")))
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    func file(_ name: String = "Setly-note.txt") throws -> URL {
        let url = source.appendingPathComponent(name); try Data("fixture-original".utf8).write(to: url); return url
    }
    func folder(_ name: String = "Setly") throws -> FolderDestination {
        let url = target.appendingPathComponent(name)
        return .init(path: url.path, identity: try SafeFileSystem.identity(at: url), category: name)
    }
    func plan(_ file: URL, folder: FolderDestination? = nil) throws -> ScanPlan {
        try Planner.singleFilePlan(source: file, folder: folder ?? self.folder(), registeredRoot: target, authorizedSources: [source], rules: rules)
    }
    func execute(_ plan: ScanPlan, progress: (EngineProgress) -> Void = { _ in }) throws -> RunRecord {
        try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.map(\.id)), progress: progress)
    }
    func catalogue(_ records: [RunRecord] = []) throws -> [FolderDestination] {
        try FolderRecommendations.catalogue(root: target, rules: rules, records: records)
    }

    func testRecommendationUsesExistingRuleThenCommittedRecentThenConnectedRoot() throws {
        let item = try file()
        var folders = try catalogue()
        for index in folders.indices where ["참고", "개인"].contains(URL(fileURLWithPath: folders[index].path).lastPathComponent) {
            folders[index].lastUsed = Date(timeIntervalSince1970: 100)
        }
        let recommended = try FolderRecommendations.recommendations(source: item, catalogue: folders, rules: rules)
        XCTAssertEqual(recommended.count, 3)
        XCTAssertEqual(recommended.first?.name, "Setly")
        XCTAssertEqual(recommended.first?.reason, "이름 규칙 일치 · Setly")
        XCTAssertEqual(recommended.map(\.id), try FolderRecommendations.recommendations(source: item, catalogue: folders.reversed(), rules: rules).map(\.id))
        XCTAssertTrue(recommended.dropFirst().allSatisfy { $0.reason.hasPrefix("최근 사용") })
        let plain = try FolderRecommendations.recommendations(source: item, catalogue: catalogue(), rules: rules)
        XCTAssertEqual(plain.map(\.name), ["Setly", "자료"])
        XCTAssertTrue(plain.last!.reason.hasPrefix("고정"))
    }

    func testNativeGestureRankingNeedsNoSourceFilesystemAccess() throws {
        let cached = try catalogue()
        // This deliberately absent path must be usable for ranking without stat, open, download or permission UI.
        let unavailable = URL(fileURLWithPath: "/unavailable-" + UUID().uuidString + "/Setly-note.txt")
        let result = FolderRecommendations.cachedRecommendations(source: unavailable, catalogue: cached, rules: rules)
        XCTAssertEqual(result.map(\.name), ["Setly", "자료"])
        XCTAssertThrowsError(try Planner.singleFilePlan(source: unavailable, folder: folder(), registeredRoot: target,
                                                       authorizedSources: [unavailable.deletingLastPathComponent()], rules: rules))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testCandidateFiltersDuplicatesMissingUnwritableAndSourceParent() throws {
        let item = try file(), setly = try folder()
        let rootFolder = FolderDestination(path: target.path, identity: try SafeFileSystem.identity(at: target), isRegisteredRoot: true)
        let current = FolderDestination(path: source.path, identity: try SafeFileSystem.identity(at: source), isRegisteredRoot: true)
        let personal = try folder("개인")
        XCTAssertEqual(chmod(personal.path, 0), 0)
        defer { chmod(personal.path, 0o755) }
        var inaccessible = personal; inaccessible.lastUsed = Date()
        let list = [setly, setly, current, rootFolder, inaccessible]
        let before = try FolderRecommendations.recommendations(source: item, catalogue: list, rules: rules)
        XCTAssertEqual(before.map(\.name), ["Setly", "자료"])
        try FileManager.default.removeItem(atPath: setly.path)
        XCTAssertEqual(try FolderRecommendations.recommendations(source: item, catalogue: list, rules: rules).map(\.name), ["자료"])
    }

    func testNoMissingCategoryOrOutsideJournalFolderIsInvented() throws {
        let item = try file("Pisa-note.txt")
        XCTAssertEqual(try FolderRecommendations.recommendations(source: item, catalogue: catalogue(), rules: rules).map(\.name), ["자료"])
        XCTAssertFalse(SafeFileSystem.exists(target.appendingPathComponent("Pisa")))
    }

    func testSessionFreezesCandidatesIgnoresLateResultsAndRunsOnlyOnce() throws {
        let item = try file()
        let candidates = try FolderRecommendations.recommendations(source: item, catalogue: catalogue(), rules: rules)
        var session = FolderDropSession()
        let token = try XCTUnwrap(session.begin(sequence: 42, source: item.path))
        XCTAssertTrue(session.freeze(candidates, for: token))
        XCTAssertFalse(session.freeze(candidates.reversed(), for: token))
        session.hover(candidates[0].id)
        XCTAssertNil(session.accept(sequence: 42, source: item.path, allowsMove: false, busy: false))
        XCTAssertNil(session.accept(sequence: 42, source: item.path, allowsMove: true, busy: true))
        XCTAssertNil(session.accept(sequence: 42, source: "different", allowsMove: true, busy: false))
        XCTAssertEqual(session.begin(sequence: 42, source: item.path), token)
        XCTAssertEqual(session.candidates, candidates)
        XCTAssertNotNil(session.accept(sequence: 42, source: item.path, allowsMove: true, busy: false))
        XCTAssertNil(session.accept(sequence: 42, source: item.path, allowsMove: true, busy: false))
        session.ended(sequence: 42)
        XCTAssertEqual(session.phase, .moving)
        session.finish(); session.reset()
        XCTAssertNil(session.begin(sequence: 42, source: item.path))
        let next = try XCTUnwrap(session.begin(sequence: 43, source: item.path))
        XCTAssertFalse(session.freeze(candidates, for: token))
        XCTAssertTrue(session.freeze(candidates, for: next))
        session.hover(nil)
        XCTAssertNil(session.accept(sequence: 43, source: item.path, allowsMove: true, busy: false))
        session.ended(sequence: 43)
        XCTAssertEqual(session.phase, .cancelled); XCTAssertTrue(session.candidates.isEmpty)
    }

    func testBatchReviewWithoutCatalogueFreezesSelectionAndAcceptsOnlyOnce() throws {
        let paths = ["/tmp/a.txt", "/tmp/b.txt"]
        var session = FolderDropSession()
        let token = try XCTUnwrap(session.begin(sequence: 101, sources: paths))
        XCTAssertTrue(session.freeze(targets: [.recommendation], for: token))
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.candidates.isEmpty, "Review must not fabricate a filesystem folder")
        session.hover(FolderDropTarget.recommendation.id)
        XCTAssertNil(session.accept(sequence: 101, sources: [paths[0]], allowsMove: true, busy: false))
        XCTAssertNil(session.accept(sequence: 101, sources: paths.reversed(), allowsMove: true, busy: false))
        XCTAssertNil(session.accept(sequence: 101, sources: paths, allowsMove: false, busy: false))
        XCTAssertNil(session.accept(sequence: 101, sources: paths, allowsMove: true, busy: true))
        XCTAssertEqual(session.accept(sequence: 101, sources: paths, allowsMove: true, busy: false), .recommendation)
        XCTAssertNil(session.accept(sequence: 101, sources: paths, allowsMove: true, busy: false))
        session.ended(sequence: 101)
        XCTAssertEqual(session.phase, .moving)
        session.finish(); session.reset()
        XCTAssertNil(session.begin(sequence: 101, sources: paths))
    }

    func testBatchTargetsStayFrozenAcrossReentryAndCatalogueChanges() throws {
        let item = try file()
        let folders = try FolderRecommendations.recommendations(source: item, catalogue: catalogue(), rules: rules)
        let targets: [FolderDropTarget] = [.recommendation] + folders.prefix(2).map(FolderDropTarget.folder)
        var session = FolderDropSession()
        let token = try XCTUnwrap(session.begin(sequence: 102, sources: [item.path]))
        XCTAssertTrue(session.freeze(targets: targets, for: token))
        XCTAssertEqual(session.begin(sequence: 102, sources: ["changed"]), token)
        XCTAssertEqual(session.sources, [item.path])
        XCTAssertFalse(session.freeze(targets: [.recommendation], for: token))
        XCTAssertEqual(session.targets, targets)
        session.hover(folders[0].id)
        XCTAssertEqual(session.accept(sequence: 102, sources: [item.path], allowsMove: true, busy: false), .folder(folders[0]))
    }

    func testBatchInputValidationIsBoundedPureAndPreservesURLs() throws {
        let urls = (0..<500).map { URL(fileURLWithPath: "/not-inspected/자료 \($0).txt") }
        XCTAssertEqual(try ExistingFileDrop.validateInputs(urls: urls, itemCount: 500, hasFilePromise: false, allowsMove: true), urls)
        let invalid: [([URL], Int, Bool, Bool)] = [
            ([], 0, false, true), (urls + [URL(fileURLWithPath: "/tmp/501")], 501, false, true),
            ([urls[0], urls[0]], 2, false, true), ([urls[0]], 2, false, true),
            ([urls[0]], 1, true, true), ([urls[0]], 1, false, false),
            ([URL(string: "https://example.com/file.txt")!], 1, false, true),
            ([URL(string: "file://remote/tmp/file.txt")!], 1, false, true)
        ]
        for (input, count, promises, move) in invalid {
            XCTAssertThrowsError(try ExistingFileDrop.validateInputs(urls: input, itemCount: count, hasFilePromise: promises, allowsMove: move))
        }
    }

    func testUnregisteredSourceMovesAndUndoAfterReloadRestoresOriginalLocation() throws {
        let item = try file(), before = try SafeFileSystem.snapshot(item, rules: rules)
        let preview = try Planner.singleFilePlan(source: item, folder: folder(), registeredRoot: target, rules: rules)
        XCTAssertEqual(preview.sourceRoots, [source.path])
        XCTAssertEqual(preview.sourceRootIdentities[source.path], try SafeFileSystem.identity(at: source))
        XCTAssertEqual(preview.proposals[0].name, item.lastPathComponent)
        let run = try execute(preview)
        XCTAssertEqual(run.entries[0].source, item.path)
        XCTAssertEqual(run.state, .completed); XCTAssertEqual(run.movedCount, 1)
        XCTAssertTrue(run.createdDirectories.isEmpty)
        XCTAssertEqual(try engine.store.history().records.count, 1)
        let reloaded = Organizer(store: try JournalStore(directory: root.appendingPathComponent("History")))
        XCTAssertEqual(try reloaded.undo(run.id).state, .undone)
        XCTAssertEqual(try SafeFileSystem.snapshot(item, rules: rules), before)
        XCTAssertEqual(try engine.store.history().records.count, 1)
        XCTAssertTrue(SafeFileSystem.exists(target.appendingPathComponent("Setly")))
        XCTAssertThrowsError(try engine.undo(run.id))
        XCTAssertEqual(try engine.store.history().records.count, 1)
    }

    func testFailedAndUndoneHistoryDoesNotCountAsAChoice() throws {
        let item = try file(), run = try execute(plan(item))
        XCTAssertNotNil(try catalogue([run]).first { $0.category == "Setly" }?.lastUsed)
        var failed = run; failed.state = .interrupted
        XCTAssertNil(try catalogue([failed]).first { $0.category == "Setly" }?.lastUsed)
        let undone = try engine.undo(run.id)
        XCTAssertNil(try catalogue([undone]).first { $0.category == "Setly" }?.lastUsed)
        var outside = run; outside.entries[0].destination = root.appendingPathComponent("outside/a.txt").path
        XCTAssertFalse(try catalogue([outside]).contains { $0.path.contains("outside") })
    }

    func testDropCannotCreateRemovedFolderBeforeOrDuringExecution() throws {
        let item = try file(), destination = try folder()
        let preview = try plan(item, folder: destination)
        try FileManager.default.removeItem(atPath: destination.path)
        XCTAssertThrowsError(try plan(item, folder: destination))
        XCTAssertThrowsError(try execute(preview))
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: destination.path)))
        XCTAssertTrue(SafeFileSystem.exists(item))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testReplacedDestinationAtActualWriteIsRejected() throws {
        let item = try file(), preview = try plan(item), destination = try folder()
        var replaced = false
        let run = try execute(preview) { progress in
            if progress.message.hasPrefix("정리 중"), !replaced {
                replaced = true
                try! FileManager.default.moveItem(atPath: destination.path, toPath: destination.path + "-previous")
                try! FileManager.default.createDirectory(atPath: destination.path, withIntermediateDirectories: false)
            }
        }
        XCTAssertTrue(replaced); XCTAssertEqual(run.movedCount, 0); XCTAssertEqual(run.state, .interrupted)
        XCTAssertTrue(SafeFileSystem.exists(item)); XCTAssertTrue(run.createdDirectories.isEmpty)
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: destination.path).appendingPathComponent(item.lastPathComponent)))
    }

    func testCollisionAtWriteAndUndoConflictPreserveOtherFile() throws {
        let item = try file(), preview = try plan(item)
        let dest = URL(fileURLWithPath: preview.proposals[0].destination!)
        var collided = false
        let failed = try execute(preview) { progress in
            if progress.message.hasPrefix("정리 중"), !collided { collided = true; try! Data("other".utf8).write(to: dest) }
        }
        XCTAssertEqual(failed.movedCount, 0); XCTAssertTrue(SafeFileSystem.exists(item))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "other")
        try FileManager.default.removeItem(at: dest)
        let run = try execute(plan(item))
        try Data("new-original-path".utf8).write(to: item)
        XCTAssertThrowsError(try engine.undo(run.id))
        XCTAssertEqual(try String(contentsOf: item, encoding: .utf8), "new-original-path")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "fixture-original")
    }

    func testActualExclusiveSyscallHasOneWinnerUnderContention() throws {
        let files = try (0..<12).map { try file("Setly-\($0).txt") }
        let destination = target.appendingPathComponent("race.txt")
        let group = DispatchGroup()
        for file in files {
            let identity = try SafeFileSystem.identity(at: file)
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                try? SafeFileSystem.moveExclusively(from: file, to: destination, expectedIdentity: identity)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(files.filter { !SafeFileSystem.exists($0) }.count, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "fixture-original")
    }

    func testUnsupportedInputAndReplacedFileCannotMove() throws {
        let item = try file()
        for (urls, count, promise, move) in [([item, item], 2, false, true), ([item], 1, true, true), ([item], 1, false, false), ([URL(string: "https://example.com/a")!], 1, false, true)] {
            XCTAssertThrowsError(try ExistingFileDrop.validateInput(urls: urls, itemCount: count, hasFilePromise: promise, allowsMove: move))
        }
        XCTAssertThrowsError(try ExistingFileDrop.inspect(source))
        let linked = source.appendingPathComponent("Setly-link.txt")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: item)
        XCTAssertThrowsError(try ExistingFileDrop.inspect(linked))
        let identity = try SafeFileSystem.identity(at: item)
        try FileManager.default.moveItem(at: item, to: source.appendingPathComponent("saved-original.txt"))
        _ = try file()
        XCTAssertThrowsError(try Planner.singleFilePlan(source: item, folder: folder(), registeredRoot: target,
                                                       authorizedSources: [source], rules: rules, expectedSourceIdentity: identity))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testAutomaticParentKeepsEnclosingProjectAndDestinationBoundaries() throws {
        let project = root.appendingPathComponent("ExampleProject")
        let assets = project.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        let item = assets.appendingPathComponent("Setly-note.txt")
        try Data("project-asset".utf8).write(to: item)
        XCTAssertThrowsError(try Planner.singleFilePlan(source: item, folder: folder(), registeredRoot: target, rules: rules)) {
            XCTAssertTrue($0.localizedDescription.contains("코드 프로젝트"))
        }
        let outside = FolderDestination(path: assets.path, identity: try SafeFileSystem.identity(at: assets))
        XCTAssertThrowsError(try Planner.singleFilePlan(source: file(), folder: outside, registeredRoot: target, rules: rules)) {
            XCTAssertTrue($0.localizedDescription.contains("정리 위치 밖"))
        }
        XCTAssertEqual(try String(contentsOf: item, encoding: .utf8), "project-asset")
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testSameFolderDisappearedSourcePermissionsAndProtectedReferences() throws {
        let item = try file()
        let current = FolderDestination(path: source.path, identity: try SafeFileSystem.identity(at: source))
        XCTAssertThrowsError(try Planner.singleFilePlan(source: item, folder: current, registeredRoot: root, authorizedSources: [source], rules: rules))
        let preview = try plan(item)
        try Data(item.lastPathComponent.utf8).write(to: source.appendingPathComponent("index.md"))
        XCTAssertThrowsError(try execute(preview))
        try FileManager.default.removeItem(at: source.appendingPathComponent("index.md"))
        XCTAssertEqual(chmod(source.path, 0o555), 0)
        XCTAssertThrowsError(try Planner.singleFilePlan(source: item, folder: folder(), registeredRoot: target, rules: rules)) {
            XCTAssertTrue($0.localizedDescription.contains("접근 권한이 부족"))
        }
        XCTAssertEqual(chmod(source.path, 0o755), 0)
        try FileManager.default.removeItem(at: item)
        XCTAssertThrowsError(try plan(item)) { XCTAssertFalse($0.localizedDescription.contains("연결")) }
        XCTAssertThrowsError(try execute(preview))
        XCTAssertTrue(try engine.store.history().records.isEmpty)
    }

    func testLegacyPlansAndRecordsDecodeWithoutNewConstraint() throws {
        let item = try file()
        let original = try Planner.analyze(sources: [source], destination: target, rules: rules)
        let data = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(ScanPlan.self, from: data).destinationParentIdentities)
        let run = try execute(original)
        XCTAssertNil(try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(run)).destinationParentIdentities)
        XCTAssertEqual(try engine.undo(run.id).state, .undone)
        XCTAssertTrue(SafeFileSystem.exists(item))
    }

    func testDisplayPlacementUsesPointsNegativeOriginsMenuBarAndNotch() {
        let cases: [(CGRect, CGRect, CGFloat)] = [
            (.init(x: 0, y: 0, width: 2048, height: 1280), .init(x: 0, y: 70, width: 2048, height: 1180), 0),
            (.init(x: -1920, y: -200, width: 1920, height: 1080), .init(x: -1920, y: -200, width: 1920, height: 1056), 0),
            (.init(x: 2048, y: 1280, width: 1512, height: 982), .init(x: 2048, y: 1340, width: 1512, height: 890), 38)
        ]
        for (screen, visible, safe) in cases {
            let expanded = FolderOverlayGeometry.frame(screen: screen, visible: visible, safeTop: safe, size: .init(width: 720, height: 210))
            let tab = FolderOverlayGeometry.frame(screen: screen, visible: visible, safeTop: safe, size: .init(width: 112, height: 28))
            XCTAssertEqual(expanded.maxY, tab.maxY)
            XCTAssertLessThan(expanded.maxY, min(visible.maxY, screen.maxY - safe))
            XCTAssertTrue(expanded.contains(tab))
            XCTAssertEqual(expanded.midX, screen.midX)
            // A 2x backing scale changes pixels, not these point coordinates.
            XCTAssertEqual(expanded.width * 2, 1440)
        }
    }
}
