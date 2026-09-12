import XCTest
import Foundation
@testable import OrganizerCore

final class OrganizationScopeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var rules: OrganizerRules { .standard(home: root) }
        init() throws {
            root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesScope-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        @discardableResult func folder(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        @discardableResult func file(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original contents".utf8).write(to: url)
            return url
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func testDefaultReadsOnlyTopLevelFilesAndKeepsFolderStructure() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.folder("source")
        let first = try f.file("source/invoice.pdf")
        let nested = try f.file("source/nested/photo.png")
        let result = try OrganizationScopeDiscovery.scan(files: [], folders: [source], rules: f.rules)
        XCTAssertEqual(result.files, [first])
        XCTAssertEqual(result.totalCandidates, 1)
        XCTAssertEqual(result.preservedFolderCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertTrue(SafeFileSystem.exists(nested))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original contents")
    }

    func testRecursiveScopeSkipsCodeProjectsPackagesHiddenSymlinksAndProtectedItems() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.folder("source")
        let eligible = try f.file("source/ordinary/image.png")
        try f.file("source/code/package.json")
        try f.file("source/code/asset.png")
        try f.file("source/Photos.photoslibrary/image.png")
        try f.file("source/.hidden/image.png")
        try f.file("source/kept/image.png")
        try f.file("source/recording.mov")
        try f.file("source/item.crdownload")
        try f.file("elsewhere/never.png")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"),
            withDestinationURL: f.root.appendingPathComponent("elsewhere"))
        var rules = f.rules; rules.protectedPaths.append(source.appendingPathComponent("kept").path)
        let result = try OrganizationScopeDiscovery.scan(files: [], folders: [source], includeSubfolders: true, rules: rules)
        XCTAssertEqual(result.files, [eligible])
        XCTAssertEqual(result.skippedCount, 7)
        XCTAssertGreaterThanOrEqual(result.preservedFolderCount, 5)
    }

    func testOverlappingRootsAndExplicitFilesProduceUniqueCandidatesIncludingHardLinks() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.folder("source")
        let first = try f.file("source/a.txt")
        let second = try f.file("source/nested/b.txt")
        try FileManager.default.linkItem(at: first, to: source.appendingPathComponent("duplicate.txt"))
        let result = try OrganizationScopeDiscovery.scan(files: [first, first, second],
            folders: [source, source.appendingPathComponent("nested"), source], includeSubfolders: true, rules: f.rules)
        XCTAssertEqual(Set(result.files), Set([first, second]))
        XCTAssertEqual(result.totalCandidates, 2)
    }

    func testExplicitNestedRootStillWorksWhenRecursionIsOff() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.folder("source")
        let nested = try f.file("source/nested/b.txt")
        let result = try OrganizationScopeDiscovery.scan(files: [], folders: [source, source.appendingPathComponent("nested")], rules: f.rules)
        XCTAssertEqual(result.files, [nested])
    }

    func testRecursiveDiscoveryPrunesExplicitlyExcludedSubtree() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.folder("source")
        let kept = try f.file("source/parent.txt")
        let excluded = try f.file("source/Receipts/deep/invoice.pdf")
        let other = try f.file("other/notes.txt")
        let result = try OrganizationScopeDiscovery.scan(files: [],
            folders: [source, other.deletingLastPathComponent()], includeSubfolders: true,
            excludedFolders: [source.appendingPathComponent("Receipts")], rules: f.rules)
        XCTAssertEqual(Set(result.files), Set([kept, other]))
        XCTAssertEqual(result.totalCandidates, 2)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.preservedFolderCount, 1)
        XCTAssertTrue(SafeFileSystem.exists(excluded))
    }

    func testExplicitFileInsideProjectAndLinkedAncestorAreExcluded() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.file("project/Package.swift")
        let file = try f.file("project/assets/image.png")
        let ordinary = try f.file("ordinary/image.png")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("linked"),
            withDestinationURL: ordinary.deletingLastPathComponent())
        let result = try OrganizationScopeDiscovery.scan(files: [file, f.root.appendingPathComponent("linked/image.png")], folders: [], rules: f.rules)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.skippedCount, 2)
    }

    func testOverflowReportsAllEligibleFilesWithoutSilentlyDroppingCount() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.folder("source")
        for index in 0..<507 { try f.file("source/\(index).txt") }
        let result = try OrganizationScopeDiscovery.scan(files: [], folders: [source], rules: f.rules)
        XCTAssertEqual(result.files.count, 500)
        XCTAssertEqual(result.totalCandidates, 507)
        XCTAssertEqual(result.overflowCount, 7)
        XCTAssertFalse(result.scanLimitReached)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 507)
    }

    func testInvestigationLimitAndCancellationAreExplicit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = try f.folder("source")
        for index in 0..<10 { try f.file("source/\(index).txt") }
        var rules = f.rules; rules.maximumSnapshotEntries = 4
        let result = try OrganizationScopeDiscovery.scan(files: [], folders: [source], rules: rules)
        XCTAssertTrue(result.scanLimitReached)
        XCTAssertEqual(result.examinedCount, 4)
        XCTAssertThrowsError(try OrganizationScopeDiscovery.scan(files: [], folders: [source], rules: rules, cancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCorruptScopeStateIsNeverReplacedWithDefaults() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let stateURL = f.root.appendingPathComponent("ScopeState.json")
        let original = Data("{ broken json".utf8)
        try original.write(to: stateURL)
        let store = OrganizationScopeStateStore(url: stateURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
    }

    func testScopeStoreRoundTripsAndRejectsExternalReplacement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let stateURL = f.root.appendingPathComponent("ScopeState.json")
        let store = OrganizationScopeStateStore(url: stateURL)
        XCTAssertEqual(try store.load(), .init())
        let state = OrganizationScopeState(connections: [.init(path: f.root.path, bookmark: Data([1, 2, 3]),
            identity: try SafeFileSystem.identity(at: f.root))])
        try store.save(state)
        XCTAssertEqual(try OrganizationScopeStateStore(url: stateURL).load(), state)
        let other = Data("externally changed".utf8)
        try other.write(to: stateURL)
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(try Data(contentsOf: stateURL), other)
    }
}
