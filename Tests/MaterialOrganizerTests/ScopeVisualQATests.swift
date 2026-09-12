import AppKit
import SwiftUI
import XCTest
@testable import MaterialOrganizer
import OrganizerCore

/// Opt-in native rendering and real file-flow evidence. No desktop capture or window activation.
final class ScopeVisualQATests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let review: ProjectReviewModel
        let watch: FolderWatchService
        let scope: ScopeSelectionModel
        let selectedFiles: [URL]
        var source: URL { root.appendingPathComponent("받은 자료") }
        var additionalSource: URL { root.appendingPathComponent("추가 자료") }

        init() throws {
            let fixtureRoot = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesScopeVisualQA-" + UUID().uuidString)
            root = fixtureRoot
            let contents = [
                "받은 자료/회의 메모.txt": "다음 회의에서 화면 구성과 정리 순서를 확인합니다.\n",
                "받은 자료/분기 예산.csv": "항목,금액\n인쇄,120000\n자료,45000\n",
                "받은 자료/프로젝트 안내.md": "# 자료 정리 안내\n파일 이름을 유지하고 이동안을 먼저 확인합니다.\n",
                "받은 자료/보관 폴더/기존 메모.txt": "기존 폴더 자체는 원래 위치를 유지합니다.\n",
                "받은 자료/개발 프로젝트/Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\n",
                "받은 자료/개발 프로젝트/Sources/App.swift": "let preserved = true\n",
                "추가 자료/참고 기록.txt": "연결한 두 번째 위치의 일반 문서입니다.\n"
            ]
            for (path, text) in contents {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("자료"), withIntermediateDirectories: true)
            selectedFiles = ["회의 메모.txt", "분기 예산.csv", "프로젝트 안내.md"].map {
                fixtureRoot.appendingPathComponent("받은 자료/" + $0)
            }
            owner = AppModel(demoRootURL: root)
            review = ProjectReviewModel(owner: owner)
            watch = FolderWatchService(stateDirectory: owner.stateDirectory, isDemo: true, pollInterval: 0)
            scope = ScopeSelectionModel(owner: owner)
        }

        func cleanup() {
            scope.cancel(); watch.shutdown(); owner.releaseFolderAccess()
            try? FileManager.default.removeItem(at: root)
        }

        /// AppState is intentionally excluded: staging is allowed to persist choices, not move files.
        func sourceSnapshot() throws -> SourceSnapshot {
            var result = SourceSnapshot()
            for directory in [source, additionalSource, root.appendingPathComponent("자료")] {
                result.directories.insert(relativePath(directory))
                let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]))
                while let url = enumerator.nextObject() as? URL {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    let path = relativePath(url)
                    if values.isDirectory == true { result.directories.insert(path) }
                    else if values.isRegularFile == true {
                        result.files[path] = try Data(contentsOf: url)
                        result.identities[path] = try SafeFileSystem.identity(at: url)
                    }
                }
            }
            return result
        }

        func relativePath(_ url: URL) -> String { String(url.path.dropFirst(root.path.count + 1)) }
    }

    private struct SourceSnapshot: Equatable {
        var files: [String: Data] = [:]
        var identities: [String: FileIdentity] = [:]
        var directories = Set<String>()
    }

    private struct CaptureRecord: Codable {
        let name: String
        let logicalWidth: Int
        let logicalHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let sampledColors: Int
        let darkSamples: Int
        let coloredSamples: Int
    }

    @MainActor private final class OffscreenHost {
        let window: NSWindow
        let view: NSHostingView<ContentView>

        init(_ fixture: Fixture) {
            _ = NSApplication.shared
            Theme.registerFonts()
            XCTAssertNotNil(NSFont(name: "Pretendard-Regular", size: 14))
            XCTAssertNotNil(NSFont(name: "Manrope-Regular", size: 14))
            XCTAssertNotNil(NSFont(name: "ArchivoBlack-Regular", size: 32))
            let size = NSSize(width: 1280, height: 840)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.backgroundColor = .white
            window.isOpaque = true
            window.appearance = NSAppearance(named: .aqua)
            view = NSHostingView(rootView: ContentView(model: fixture.owner, review: fixture.review,
                watch: fixture.watch, scope: fixture.scope))
            view.frame = NSRect(origin: .zero, size: size)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        func capture(_ name: String, size: NSSize, directory: URL) async throws -> CaptureRecord {
            XCTAssertFalse(window.isVisible, "QA host must never be ordered onto the desktop")
            XCTAssertFalse(window.isKeyWindow)
            window.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            // Yield to AppKit/SwiftUI and let the finite board route finish at its real landing.
            try await Task.sleep(nanoseconds: 1_100_000_000)
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "No native bitmap for \(name)")
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "PNG encoding failed for \(name)")
            try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)

            var colors = Set<Int>(), dark = 0, colored = 0
            for row in 0..<40 {
                for column in 0..<64 {
                    let x = min(bitmap.pixelsWide - 1, (2 * column + 1) * bitmap.pixelsWide / 128)
                    let y = min(bitmap.pixelsHigh - 1, (2 * row + 1) * bitmap.pixelsHigh / 80)
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                    let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                    colors.insert(Int(red * 31) << 10 | Int(green * 31) << 5 | Int(blue * 31))
                    if max(red, green, blue) < 0.4 { dark += 1 }
                    if max(red, green, blue) - min(red, green, blue) > 0.18 { colored += 1 }
                }
            }
            XCTAssertGreaterThan(bitmap.pixelsWide, 1000)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 650)
            XCTAssertGreaterThan(png.count, 15_000, "Native image is unexpectedly empty: \(name)")
            XCTAssertGreaterThan(colors.count, 12, "Native image lacks rendered content: \(name)")
            XCTAssertGreaterThan(dark, 15, "Native image lacks the black tile/text: \(name)")
            XCTAssertGreaterThan(colored, 20, "Native image lacks the blue tiles: \(name)")
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            return .init(name: name, logicalWidth: Int(size.width), logicalHeight: Int(size.height),
                pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh, sampledColors: colors.count,
                darkSamples: dark, coloredSamples: colored)
        }
    }

    @MainActor private func waitUntilIdle(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if !fixture.scope.isScanning && !fixture.owner.busy && !fixture.review.isAnalyzing &&
                !fixture.review.isPreparing && fixture.watch.isLoaded { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Scope visual QA did not settle within 30 seconds", file: file, line: line)
        throw OrganizerError("Scope visual QA timed out")
    }

    @MainActor func testNativeScopeScreensAndActualPreviewMoveUndo() async throws {
        guard let path = ProcessInfo.processInfo.environment["TILES_VISUAL_QA_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TILES_VISUAL_QA_DIR to an absolute output directory to render native QA evidence.")
        }
        guard path.hasPrefix("/") else { throw OrganizerError("TILES_VISUAL_QA_DIR must be an absolute path") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let host = OffscreenHost(fixture)
        defer { host.close() }
        let large = NSSize(width: 1280, height: 840), minimum = NSSize(width: 1060, height: 688)
        var captures: [CaptureRecord] = []
        try await waitUntilIdle(fixture)
        let originals = try fixture.sourceSnapshot()
        XCTAssertTrue(fixture.owner.records.isEmpty)

        captures.append(try await host.capture("00-intake-empty-1280", size: large, directory: output))
        captures.append(try await host.capture("00-intake-empty-1060", size: minimum, directory: output))
        fixture.scope.addFiles(fixture.selectedFiles)
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.scope.candidateCount, 3)
        XCTAssertTrue(fixture.review.rows.isEmpty, "Scope staging must not begin content analysis")
        captures.append(try await host.capture("01-files", size: large, directory: output))

        XCTAssertTrue(fixture.scope.connectFolders([fixture.source]))
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.scope.mode, .folders)
        XCTAssertEqual(fixture.scope.candidateCount, 3)
        XCTAssertGreaterThanOrEqual(fixture.scope.preservedFolderCount, 2)
        captures.append(try await host.capture("02-folders", size: large, directory: output))
        fixture.scope.includeSubfolders = true
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.scope.candidateCount, 4)
        XCTAssertTrue(fixture.scope.candidateURLs.allSatisfy { !$0.path.contains("개발 프로젝트") })
        captures.append(try await host.capture("02-folders-subfolders", size: large, directory: output))

        XCTAssertTrue(fixture.scope.connectFolders([fixture.additionalSource]))
        fixture.scope.setMode(.all)
        try await waitUntilIdle(fixture)
        XCTAssertEqual(fixture.scope.connectedLocationCount, 2)
        XCTAssertEqual(fixture.scope.selectedLocationCount, 2)
        XCTAssertTrue(fixture.scope.locations.filter(\.isDefault).allSatisfy { !$0.selected && !$0.isConnected })
        XCTAssertEqual(fixture.scope.candidateCount, 5)
        XCTAssertTrue(fixture.scope.canPreview)
        captures.append(try await host.capture("03-all", size: large, directory: output))
        XCTAssertEqual(try fixture.sourceSnapshot(), originals, "Source discovery must not change any fixture file or folder")

        let chosenPaths = Set(fixture.scope.candidateURLs.map(\.path))
        fixture.scope.preview(using: fixture.review)
        XCTAssertTrue(fixture.owner.projectReviewActive)
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        XCTAssertEqual(Set(fixture.review.rows.map { $0.evidence.sourcePath }), chosenPaths)
        XCTAssertEqual(fixture.review.readyCount, chosenPaths.count)
        XCTAssertEqual(fixture.review.unresolvedCount, 0)
        XCTAssertEqual(fixture.review.batches.first(where: { $0.id == fixture.review.activeBatchID })?.origin, "선택한 범위")
        XCTAssertEqual(try fixture.sourceSnapshot(), originals, "Recommendations must leave source bytes and paths untouched")
        captures.append(try await host.capture("04-review", size: large, directory: output))
        captures.append(try await host.capture("04-review-1060", size: minimum, directory: output))

        fixture.review.prepare()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        let plan = try XCTUnwrap(fixture.review.preparedPlan)
        XCTAssertEqual(plan.proposals.count, chosenPaths.count)
        for proposal in plan.proposals {
            let destination = URL(fileURLWithPath: try XCTUnwrap(proposal.destination))
            guard PathSafety.contains(fixture.root, URL(fileURLWithPath: proposal.source)),
                  PathSafety.contains(fixture.root, destination) else {
                throw OrganizerError("Visual QA may move only its isolated fixture files")
            }
        }
        XCTAssertTrue(fixture.review.newDirectoryPaths.allSatisfy { !SafeFileSystem.exists(URL(fileURLWithPath: $0)) })
        XCTAssertTrue(fixture.owner.records.isEmpty)
        XCTAssertEqual(try fixture.sourceSnapshot(), originals, "Preparing the move preview must not create directories or move files")
        captures.append(try await host.capture("05-plan", size: large, directory: output))

        fixture.review.executePrepared()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        let run = try XCTUnwrap(fixture.review.lastRun)
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.movedCount, chosenPaths.count)
        XCTAssertTrue(run.canUndo)
        for entry in run.entries {
            let source = URL(fileURLWithPath: entry.source), destination = URL(fileURLWithPath: entry.destination)
            XCTAssertFalse(SafeFileSystem.exists(source))
            XCTAssertEqual(try Data(contentsOf: destination), originals.files[fixture.relativePath(source)])
            XCTAssertEqual(try SafeFileSystem.identity(at: destination), originals.identities[fixture.relativePath(source)])
        }
        XCTAssertNotEqual(try fixture.sourceSnapshot(), originals)
        captures.append(try await host.capture("06-complete", size: large, directory: output))

        fixture.review.undo()
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        XCTAssertEqual(fixture.review.lastRun?.state, .undone)
        XCTAssertEqual(try fixture.sourceSnapshot(), originals, "Undo must restore every byte, file identity, path and existing directory")
        XCTAssertTrue(run.createdDirectories.allSatisfy { !SafeFileSystem.exists(URL(fileURLWithPath: $0.path)) })
        captures.append(try await host.capture("07-undone", size: large, directory: output))

        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(captures).write(to: output.appendingPathComponent("native-captures.json"), options: .atomic)
        let note = """
        Native SwiftUI ContentView rendered through an offscreen NSHostingView/NSWindow.
        No desktop screenshots, window ordering, activation, clicking or input simulation were used.
        The real scope, recommendation, planning, execution and undo models used isolated temporary files.
        Source bytes, identities and directories were unchanged before execution and fully restored by undo.
        PNG color checks reject blank output; visual layout still requires inspection of the saved images.
        """
        try Data(note.utf8).write(to: output.appendingPathComponent("README.txt"), options: .atomic)
    }
}
