import XCTest
import Foundation
@testable import MaterialOrganizer
import OrganizerCore

final class ScopeSelectionModelTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let scope: ScopeSelectionModel
        init() throws {
            root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesScopeModel-" + UUID().uuidString)
            for name in ["받은 자료", "자료", "source"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            owner = AppModel(demoRootURL: root)
            scope = ScopeSelectionModel(owner: owner)
        }
        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent("source/" + name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: url)
            return url
        }
        func cleanup() { scope.cancel(); owner.releaseFolderAccess(); try? FileManager.default.removeItem(at: root) }
    }

    @MainActor private func waitForScan(_ scope: ScopeSelectionModel) async throws {
        for _ in 0..<400 {
            if !scope.isScanning { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Scope scan timed out")
    }

    @MainActor func testModesPreserveStagedInputsAndAllIncludesOnlyConnectedLocations() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = try f.file("one.txt")
        XCTAssertEqual(f.scope.locations.count, 2)
        XCTAssertEqual(f.scope.selectedLocationCount, 0)
        f.scope.addFiles([file])
        try await waitForScan(f.scope)
        XCTAssertEqual(f.scope.candidateURLs, [file])
        XCTAssertFalse(f.owner.busy)
        XCTAssertFalse(f.owner.projectReviewActive)
        XCTAssertTrue(f.scope.connectFolders([f.root.appendingPathComponent("source")]))
        try await waitForScan(f.scope)
        XCTAssertEqual(f.scope.mode, .folders)
        XCTAssertEqual(f.scope.selectedFiles, [file])
        f.scope.setMode(.files)
        XCTAssertEqual(f.scope.selectedLocationCount, 0)
        XCTAssertEqual(f.scope.locations.filter(\.selected).count, 1)
        f.scope.setMode(.all)
        try await waitForScan(f.scope)
        XCTAssertEqual(f.scope.selectedLocationCount, 1)
        XCTAssertEqual(f.scope.candidateURLs, [file])
        XCTAssertEqual(f.scope.selectedFiles, [file])
        XCTAssertTrue(f.scope.locations.filter(\.isDefault).allSatisfy { !$0.selected })
    }

    @MainActor func testRecursionRefreshesAndResetKeepsConnections() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = try f.file("nested/one.txt")
        XCTAssertTrue(f.scope.connectFolders([f.root.appendingPathComponent("source")]))
        try await waitForScan(f.scope)
        XCTAssertEqual(f.scope.candidateCount, 0)
        f.scope.includeSubfolders = true
        try await waitForScan(f.scope)
        XCTAssertEqual(f.scope.candidateURLs, [file])
        f.scope.resetSelection()
        XCTAssertEqual(f.scope.selectedLocationCount, 0)
        XCTAssertEqual(f.scope.connectedLocationCount, 1)
        XCTAssertFalse(f.scope.includeSubfolders)
        XCTAssertTrue(f.scope.candidateURLs.isEmpty)
        let restored = ScopeSelectionModel(owner: f.owner)
        XCTAssertEqual(restored.connectedLocationCount, 1)
        XCTAssertEqual(restored.selectedLocationCount, 0)
        XCTAssertTrue(restored.storeReadable)
    }

    @MainActor func testRecursiveAllHonorsExcludedNestedConnectionAndAllowsSelectedChildOfUnselectedParent() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let parent = f.root.appendingPathComponent("source")
        let child = parent.appendingPathComponent("Receipts")
        let kept = try f.file("parent.txt")
        let excluded = try f.file("Receipts/invoice.pdf")
        let unrelated = f.root.appendingPathComponent("받은 자료/note.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        XCTAssertTrue(f.scope.connectFolders([parent, child, unrelated.deletingLastPathComponent()]))
        f.scope.includeSubfolders = true
        f.scope.setMode(.all)
        f.scope.toggleLocation(child.path)
        try await waitForScan(f.scope)
        XCTAssertEqual(Set(f.scope.candidateURLs), Set([kept, unrelated]))
        XCTAssertFalse(f.scope.locations.first { $0.path == child.path }!.selected)
        f.scope.setMode(.folders)
        try await waitForScan(f.scope)
        XCTAssertEqual(Set(f.scope.candidateURLs), Set([kept, unrelated]))
        f.scope.toggleLocation(parent.path)
        f.scope.toggleLocation(child.path)
        try await waitForScan(f.scope)
        XCTAssertEqual(Set(f.scope.candidateURLs), Set([excluded, unrelated]))
        XCTAssertTrue(SafeFileSystem.exists(excluded))
        XCTAssertTrue(f.owner.records.isEmpty)
    }

    @MainActor func testExplicitSelectedGrandchildOverridesExcludedParentWithoutIncludingSibling() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let downloads = f.root.appendingPathComponent("source")
        let receipts = downloads.appendingPathComponent("Receipts")
        let selectedYear = receipts.appendingPathComponent("2026")
        let excludedDrafts = selectedYear.appendingPathComponent("Drafts")
        let parentFile = try f.file("parent.txt")
        let selectedFile = try f.file("Receipts/2026/invoice.pdf")
        let excludedSibling = try f.file("Receipts/2025/invoice.pdf")
        let excludedWithinSelection = try f.file("Receipts/2026/Drafts/draft.pdf")
        XCTAssertTrue(f.scope.connectFolders([downloads, receipts, selectedYear, excludedDrafts]))
        f.scope.includeSubfolders = true
        f.scope.setMode(.all)
        f.scope.toggleLocation(receipts.path)
        f.scope.toggleLocation(excludedDrafts.path)
        try await waitForScan(f.scope)
        XCTAssertEqual(Set(f.scope.candidateURLs), Set([parentFile, selectedFile]))
        XCTAssertEqual(f.scope.candidateCount, 2)
        XCTAssertTrue(f.scope.locations.first(where: { $0.path == selectedYear.path })!.selected)
        XCTAssertFalse(f.scope.locations.first(where: { $0.path == receipts.path })!.selected)
        XCTAssertTrue(SafeFileSystem.exists(excludedSibling))
        XCTAssertTrue(SafeFileSystem.exists(excludedWithinSelection))
        XCTAssertTrue(f.owner.records.isEmpty)
    }

    @MainActor func testMixedFileIntakeRejectsDirectoriesAfterRecursiveFolderModeAndKeepsRegularSelections() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let kept = try f.file("kept.txt")
        let added = try f.file("added.txt")
        let nested = try f.file("nested/unselected.txt")
        f.scope.addFiles([kept])
        XCTAssertTrue(f.scope.connectFolders([f.root.appendingPathComponent("source")]))
        f.scope.includeSubfolders = true
        f.scope.setMode(.files)
        f.scope.addFiles([nested.deletingLastPathComponent(), added])
        try await waitForScan(f.scope)
        XCTAssertEqual(f.scope.mode, .files)
        XCTAssertTrue(f.scope.includeSubfolders)
        XCTAssertEqual(Set(f.scope.selectedFiles), Set([kept, added]))
        XCTAssertEqual(Set(f.scope.candidateURLs), Set([kept, added]))
        XCTAssertEqual(f.scope.candidateCount, 2)
        XCTAssertTrue(f.scope.notice?.contains("선택 폴더") == true)
        XCTAssertTrue(SafeFileSystem.exists(nested))
        XCTAssertTrue(f.owner.records.isEmpty)
    }

    @MainActor func testOverflowBlocksPreviewAndStagingDoesNotAnalyze() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let review = ProjectReviewModel(owner: f.owner)
        for index in 0..<501 { _ = try f.file("\(index).txt") }
        XCTAssertTrue(f.scope.connectFolders([f.root.appendingPathComponent("source")]))
        try await waitForScan(f.scope)
        XCTAssertEqual(f.scope.candidateCount, 501)
        XCTAssertEqual(f.scope.overflowCount, 1)
        XCTAssertFalse(f.scope.canPreview)
        XCTAssertTrue(review.batches.isEmpty)
        f.scope.preview(using: review)
        XCTAssertTrue(review.batches.isEmpty)
        XCTAssertFalse(f.owner.busy)
    }

    @MainActor func testExplicitPreviewStartsReviewAndNeverMovesSource() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let review = ProjectReviewModel(owner: f.owner)
        review.contentEnabled = false
        let file = try f.file("one.txt")
        f.scope.addFiles([file])
        try await waitForScan(f.scope)
        XCTAssertTrue(f.scope.canPreview)
        XCTAssertTrue(review.batches.isEmpty)
        XCTAssertFalse(f.owner.projectReviewActive)
        f.scope.preview(using: review)
        XCTAssertTrue(f.owner.projectReviewActive)
        XCTAssertFalse(f.owner.showFolderBatch)
        XCTAssertEqual(review.batches.flatMap { $0.files.map(\.path) }, [file.path])
        for _ in 0..<600 {
            if !f.owner.busy { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(f.owner.busy)
        XCTAssertTrue(SafeFileSystem.exists(file))
        XCTAssertTrue(f.owner.records.isEmpty)
    }

    @MainActor func testCorruptPersistenceDisablesIntakeAndPreservesBytes() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let url = f.owner.stateDirectory.appendingPathComponent("ScopeState.json")
        let bytes = Data("not-json".utf8)
        try bytes.write(to: url)
        let blocked = ScopeSelectionModel(owner: f.owner)
        XCTAssertFalse(blocked.storeReadable)
        XCTAssertFalse(blocked.connectFolders([f.root.appendingPathComponent("source")]))
        blocked.addFiles([try f.file("one.txt")])
        XCTAssertTrue(blocked.selectedFiles.isEmpty)
        XCTAssertFalse(blocked.canPreview)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
