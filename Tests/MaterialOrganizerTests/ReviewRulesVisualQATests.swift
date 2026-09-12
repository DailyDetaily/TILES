import AppKit
import SwiftUI
import XCTest
@testable import MaterialOrganizer
import OrganizerCore

/// Opt-in rendering of the actual review components in hidden offscreen windows.
/// This does not capture the desktop, activate a window, or simulate native clicks.
final class ReviewRulesVisualQATests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let owner: AppModel
        let review: ProjectReviewModel
        let files: [URL]
        let project: ProjectDefinition

        init() throws {
            let fixtureRoot = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
                .appendingPathComponent("TilesRulesVisualQA-" + UUID().uuidString)
            root = fixtureRoot
            let source = fixtureRoot.appendingPathComponent("받은 자료")
            let target = fixtureRoot.appendingPathComponent("자료")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            files = ["Atlas_reference_01.txt", "Atlas_reference_02.txt"].map { source.appendingPathComponent($0) }
            for (index, url) in files.enumerated() {
                try Data("참고 내용 \(index + 1). 검토와 규칙 저장 중 원본을 유지합니다.\n".utf8).write(to: url)
            }
            project = ProjectDefinition(name: "Atlas", rootPath: target.appendingPathComponent("Atlas").path, template: .simple)
            owner = AppModel(demoRootURL: fixtureRoot)
            review = ProjectReviewModel(owner: owner)
            review.contentEnabled = false
        }

        func cleanup() {
            review.shutdown()
            owner.releaseFolderAccess()
            try? FileManager.default.removeItem(at: root)
        }

        func sourceSnapshot() throws -> SourceSnapshot {
            var snapshot = SourceSnapshot()
            for file in files {
                snapshot.bytes[file.path] = try Data(contentsOf: file)
                snapshot.identities[file.path] = try SafeFileSystem.identity(at: file)
            }
            snapshot.sourceEntries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("받은 자료").path).sorted()
            snapshot.destinationEntries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("자료").path).sorted()
            return snapshot
        }
    }

    private struct SourceSnapshot: Equatable {
        var bytes: [String: Data] = [:]
        var identities: [String: FileIdentity] = [:]
        var sourceEntries: [String] = []
        var destinationEntries: [String] = []
    }

    private struct CaptureRecord: Codable {
        let name: String
        let component: String
        let logicalWidth: Int
        let logicalHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let pngBytes: Int
        let sampledColors: Int
        let darkSamples: Int
        let lightSamples: Int
    }

    @MainActor private final class OffscreenHost {
        let window: NSWindow
        let view: NSHostingView<AnyView>

        init<Content: View>(_ content: Content, size: NSSize) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.backgroundColor = .white
            window.isOpaque = true
            window.appearance = NSAppearance(named: .aqua)
            view = NSHostingView(rootView: AnyView(content))
            view.frame = NSRect(origin: .zero, size: size)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        func capture(_ name: String, component: String, size: NSSize, directory: URL) async throws -> CaptureRecord {
            guard !window.isVisible, !window.isKeyWindow, window.frame.maxX < 0, window.frame.maxY < 0 else {
                throw OrganizerError("Rule visual QA host must stay hidden and offscreen")
            }
            window.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            // Allow SwiftUI layout to settle without ordering the window onto the desktop.
            try await Task.sleep(nanoseconds: 700_000_000)
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "No native bitmap for \(name)")
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "PNG encoding failed for \(name)")

            var colors = Set<Int>(), dark = 0, light = 0
            for row in 0..<72 {
                for column in 0..<96 {
                    let x = min(bitmap.pixelsWide - 1, (2 * column + 1) * bitmap.pixelsWide / 192)
                    let y = min(bitmap.pixelsHigh - 1, (2 * row + 1) * bitmap.pixelsHigh / 144)
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                    let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                    colors.insert(Int(red * 31) << 10 | Int(green * 31) << 5 | Int(blue * 31))
                    if max(red, green, blue) < 0.4 { dark += 1 }
                    if min(red, green, blue) > 0.85 { light += 1 }
                }
            }
            guard bitmap.pixelsWide >= Int(size.width), bitmap.pixelsHigh >= Int(size.height),
                  png.count > 8_000, colors.count > 6, dark > 10, light > 100 else {
                throw OrganizerError("Blank or incomplete rule rendering: \(name); colors=\(colors.count), dark=\(dark), light=\(light), bytes=\(png.count)")
            }
            guard !window.isVisible, !window.isKeyWindow else {
                throw OrganizerError("Rule visual QA host became visible")
            }
            try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
            return .init(name: name, component: component, logicalWidth: Int(size.width), logicalHeight: Int(size.height),
                pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh, pngBytes: png.count,
                sampledColors: colors.count, darkSamples: dark, lightSamples: light)
        }
    }

    @MainActor private func waitUntilIdle(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if !fixture.owner.busy && !fixture.review.isAnalyzing && !fixture.review.isPreparing { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Rule visual QA did not settle within 30 seconds", file: file, line: line)
        throw OrganizerError("Rule visual QA timed out")
    }

    @MainActor func testOffscreenReviewQuestionsRuleSheetAndSavedRulePreserveSources() async throws {
        guard let path = ProcessInfo.processInfo.environment["TILES_RULES_VISUAL_QA_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TILES_RULES_VISUAL_QA_DIR to an absolute directory to render rule review evidence.")
        }
        guard path.hasPrefix("/") else { throw OrganizerError("TILES_RULES_VISUAL_QA_DIR must be an absolute path") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Theme.registerFonts()
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.sourceSnapshot()
        XCTAssertTrue(fixture.review.saveProject(fixture.project, applyToIncluded: false))
        fixture.review.receive(fixture.files)
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.failure)
        XCTAssertEqual(fixture.review.rows.count, 2)
        XCTAssertEqual(fixture.review.unresolvedCount, 2)
        XCTAssertEqual(fixture.review.readyCount, 0)
        XCTAssertTrue(fixture.review.rows.allSatisfy { $0.projectID == fixture.project.id && $0.folder == nil })
        XCTAssertEqual(fixture.review.assistance.rules.count, 0)
        XCTAssertEqual(try fixture.sourceSnapshot(), original)
        let group = try XCTUnwrap(fixture.review.clarificationGroups.first { $0.rowIDs.count == 2 })
        XCTAssertEqual(Set(group.names), Set(fixture.files.map(\.lastPathComponent)))

        var captures: [CaptureRecord] = []
        let large = NSSize(width: 900, height: 700), minimum = NSSize(width: 700, height: 550)
        let reviewHost = OffscreenHost(ProjectReviewView(review: fixture.review, owner: fixture.owner), size: large)
        defer { reviewHost.close() }
        captures.append(try await reviewHost.capture("01-review-questions-900", component: "ProjectReviewView", size: large, directory: output))
        captures.append(try await reviewHost.capture("02-review-questions-700", component: "ProjectReviewView", size: minimum, directory: output))
        XCTAssertEqual(fixture.review.assistance.rules.count, 0, "Rendering must not create a rule")
        XCTAssertEqual(try fixture.sourceSnapshot(), original, "Rendering questions must not move or modify source files")

        fixture.review.assignFolder("참고자료", toGroup: group.id)
        XCTAssertEqual(fixture.review.readyCount, 2)
        XCTAssertEqual(fixture.review.unresolvedCount, 0)
        XCTAssertTrue(fixture.review.rows.allSatisfy { $0.explicitlyAssigned && $0.folder == "참고자료" })
        let draft = try XCTUnwrap(fixture.review.ruleDraft())
        XCTAssertEqual(draft.prefix, "Atlas_reference_")
        XCTAssertEqual(Set(fixture.review.ruleMatchingNames(prefix: draft.prefix)), Set(fixture.files.map(\.lastPathComponent)))
        let sheetSize = NSSize(width: 620, height: 600)
        let sheetHost = OffscreenHost(ProjectReviewRuleSheet(review: fixture.review, owner: fixture.owner, draft: draft)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white), size: sheetSize)
        defer { sheetHost.close() }
        captures.append(try await sheetHost.capture("03-rule-save-sheet", component: "ProjectReviewRuleSheet", size: sheetSize, directory: output))
        XCTAssertEqual(fixture.review.assistance.rules.count, 0, "Opening the actual rule sheet must not save a rule")
        XCTAssertEqual(try fixture.sourceSnapshot(), original, "Choosing a group destination and viewing a rule must leave originals untouched")

        // An explicit model save supplies real persisted data for the actual expanded list component.
        // This is not a simulated click or evidence of native pointer/keyboard interaction.
        XCTAssertTrue(fixture.review.rememberRule(prefix: draft.prefix))
        try await waitUntilIdle(fixture)
        XCTAssertNil(fixture.review.assistance.failure)
        XCTAssertEqual(fixture.review.assistance.rules.count, 1)
        let saved = try XCTUnwrap(fixture.review.assistance.rules.first)
        XCTAssertEqual(saved.filenamePrefix, draft.prefix)
        XCTAssertEqual(saved.sourceDirectory, draft.sourceDirectory)
        XCTAssertEqual(saved.fileExtension, draft.fileExtension)
        XCTAssertEqual(saved.projectID, draft.projectID)
        XCTAssertEqual(saved.projectRootPath, draft.projectRootPath)
        XCTAssertEqual(saved.folder, "참고자료")
        let rulesHost = OffscreenHost(ProjectReviewAssistanceView(review: fixture.review, owner: fixture.owner, expandSavedRules: true)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white), size: minimum)
        defer { rulesHost.close() }
        captures.append(try await rulesHost.capture("04-saved-rule-list", component: "ProjectReviewAssistanceView", size: minimum, directory: output))
        XCTAssertEqual(fixture.review.assistance.rules.count, 1, "Rendering the list must not add another rule")
        XCTAssertEqual(try fixture.sourceSnapshot(), original, "Explicit rule saving must preserve source paths, bytes, identities and destination contents")
        XCTAssertFalse(SafeFileSystem.exists(URL(fileURLWithPath: fixture.project.rootPath)))
        XCTAssertNil(fixture.review.preparedPlan)
        XCTAssertNil(fixture.review.lastRun)
        XCTAssertTrue(fixture.owner.records.isEmpty, "No move or undo is executed by this visual test")
        XCTAssertEqual(captures.count, 4)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(captures).write(to: output.appendingPathComponent("review-rule-captures.json"), options: .atomic)
        let note = """
        Four actual SwiftUI review-component renders from hidden offscreen NSHostingView/NSWindow hosts.
        No window ordering, activation, desktop capture, clicking or input simulation was used.
        Two temporary Atlas text files were analyzed by the real ProjectReviewModel. A real group choice
        and one explicit rule save supplied the review, rule sheet and saved-list states.
        Both source files retained their paths, bytes and identities; no project directory or move record was created.
        The 700px review image checks the standalone panel at its minimum QA size, not a new main-grid design.
        The sheet and expanded saved-list images render the same production components in standalone hosts.
        Nonblank PNG sampling is automated; native pointer/keyboard interaction and visual inspection are separate checks.
        """
        try Data(note.utf8).write(to: output.appendingPathComponent("review-rules-README.txt"), options: .atomic)
    }
}
