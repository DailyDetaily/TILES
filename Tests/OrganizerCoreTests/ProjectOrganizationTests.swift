import XCTest
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import OrganizerCore

final class ProjectOrganizationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory)
            .appendingPathComponent("ProjectOrganizationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func project(_ name: String = "Setly", aliases: [String] = [], template: ProjectTemplate = .simple) -> ProjectDefinition {
        .init(name: name, rootPath: root.appendingPathComponent(name).path, aliases: aliases, template: template)
    }
    private func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testUnknownFilenameUsesObservedTextAndKeepsBatchEvidenceSeparate() async throws {
        let first = try file("scan-3746.txt", "Setly project notes"), second = try file("scan-9831.txt", "unrelated daily groceries")
        let results = await ProjectFileAnalyzer.analyze(urls: [first, second], projects: [project()])
        XCTAssertEqual(results[0].projectMatch, .unique)
        XCTAssertEqual(results[0].projectCandidates[0].sources, [.localText])
        XCTAssertEqual(results[0].readStatus, .textRead)
        XCTAssertNotNil(results[0].sourceIdentity)
        XCTAssertEqual(results[1].projectMatch, .unknown)
        XCTAssertTrue(results[1].projectCandidates.isEmpty)
    }

    func testExactUnicodeTokensShortNamesAliasesAndAmbiguity() async throws {
        XCTAssertFalse(ProjectFileAnalyzer.containsToken("O", in: "logo-document-orange"))
        XCTAssertFalse(ProjectFileAnalyzer.containsToken("O", in: "O2 document"))
        XCTAssertTrue(ProjectFileAnalyzer.containsToken("O", in: "O-final"))
        XCTAssertTrue(ProjectFileAnalyzer.containsToken("Taste Buddy", in: "Taste_Buddy-notes"))
        XCTAssertFalse(ProjectFileAnalyzer.containsToken("Setly", in: "Setlyish"))
        XCTAssertTrue(ProjectFileAnalyzer.containsToken("프로젝트", in: "프로젝트_기록"))
        let input = try file("unknown.txt", "Setly and Taste Buddy are both mentioned. logo document")
        let results = await ProjectFileAnalyzer.analyze(urls: [input], projects: [project(), project("TB", aliases: ["Taste Buddy"]), project("O")])
        XCTAssertEqual(results[0].projectMatch, .ambiguous)
        XCTAssertEqual(results[0].projectCandidates.map(\.projectName), ["Setly", "TB"])
    }

    func testEmptyUnsupportedUnicodeFailureAndDisabledOCRAreDistinct() async throws {
        let empty = try file("empty.txt", ""), unsupported = try file("proposal.docx", "Setly"), image = try file("photo.png", "not an image")
        let broken = root.appendingPathComponent("broken.txt")
        try Data([0xC3, 0x28]).write(to: broken)
        let results = await ProjectFileAnalyzer.analyze(urls: [empty, unsupported, broken], projects: [project()])
        XCTAssertEqual(results.map(\.readStatus), [.empty, .unsupported, .decodingFailed])
        XCTAssertTrue(results.allSatisfy { $0.projectMatch == .unknown })
        let disabled = await ProjectFileAnalyzer.analyze(urls: [image], projects: [], contentEnabled: false)
        XCTAssertEqual(disabled.first?.readStatus, .ocrDisabled)
        XCTAssertNil(disabled.first?.observedTextExcerpt)
    }

    func testUnreadableMissingSymlinkAndNonlocalInputDoNotGainIdentity() async throws {
        let inaccessible = try file("Setly.txt", "Setly")
        XCTAssertEqual(chmod(inaccessible.path, 0), 0)
        defer { chmod(inaccessible.path, 0o600) }
        let missing = root.appendingPathComponent("missing.txt"), link = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inaccessible)
        let inputs = [inaccessible, missing, link, URL(string: "file://remote.example/tmp/Setly.txt")!]
        let results = await ProjectFileAnalyzer.analyze(urls: inputs, projects: [project()])
        XCTAssertTrue(results.allSatisfy { $0.sourceIdentity == nil && $0.readStatus == .invalidFile && $0.projectCandidates.isEmpty })
    }

    func testPDFTextCanFindProjectButCannotInferWorkflowRole() async throws {
        let pdf = try makePDF("scan.pdf", text: "Setly invoice - final release")
        let result = await ProjectFileAnalyzer.analyze(urls: [pdf], projects: [project()])[0]
        XCTAssertEqual(result.readStatus, .pdfTextRead)
        XCTAssertEqual(result.projectCandidates.first?.sources, [.pdfText])
        XCTAssertEqual(result.documentCues, [.invoice])
        XCTAssertNil(result.suggestedFolder(for: project(template: .workflow)))
        XCTAssertNil(result.suggestedFolder(for: project(template: .simple)))
        XCTAssertEqual(result.suggestedFolder(for: project(template: .byKind)), "문서")
        XCTAssertEqual(result.suggestedFolder(for: project(template: .byDocument)), "청구서")
        XCTAssertEqual(ProjectTemplate.byMonth.defaultFolders, [])
        XCTAssertNotNil(result.suggestedFolder(for: project(template: .byMonth)))
    }

    func testImageAndScannedPDFReadActualLocalOCR() async throws {
        let image = try makeImage("SETLY INVOICE")
        let png = root.appendingPathComponent("capture-8192.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pdf = root.appendingPathComponent("scan-8192.pdf")
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let consumer = try XCTUnwrap(CGDataConsumer(url: pdf as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.draw(image, in: box); context.endPDFPage(); context.closePDF()
        let results = await ProjectFileAnalyzer.analyze(urls: [png, pdf], projects: [project()])
        XCTAssertEqual(results.map(\.readStatus), [.ocrRead, .ocrRead])
        XCTAssertEqual(results.map { $0.projectCandidates.first?.sources }, [[.imageOCR], [.pdfOCR]])
        XCTAssertTrue(results.allSatisfy { $0.documentCues == [.invoice] })
    }

    func testCancellationAndFileSizeLimitAreExplicit() async throws {
        let input = try file("Setly.txt", "Setly")
        let cancelled = await ProjectFileAnalyzer.analyze(urls: [input], projects: [project()], cancelled: { true })
        XCTAssertEqual(cancelled[0].readStatus, .cancelled)
        XCTAssertNil(cancelled[0].sourceIdentity)
        let oversized = root.appendingPathComponent("large.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ProjectFileAnalyzer.maximumTextBytes + 1)); try handle.close()
        let result = await ProjectFileAnalyzer.analyze(urls: [oversized], projects: [project()])[0]
        XCTAssertEqual(result.readStatus, .limitExceeded)
        XCTAssertNil(result.observedTextExcerpt)
    }

    func testSourceVersionInvalidatesSameInodeChanges() async throws {
        let input = try file("scan.txt", "Setly")
        let evidence = await ProjectFileAnalyzer.analyze(urls: [input], projects: [project()])[0]
        XCTAssertTrue(try evidence.matchesCurrentSource())
        let handle = try FileHandle(forWritingTo: input)
        try handle.write(contentsOf: Data("A different project and longer content".utf8)); try handle.close()
        XCTAssertEqual(try ProjectFileVersion.capture(input).identity, evidence.sourceIdentity)
        XCTAssertFalse(try evidence.matchesCurrentSource())
    }

    func testMetadataStillAvailableAfterContentBudget() async throws {
        let input = try file("Setly-note.txt", "Setly")
        let results = await ProjectFileAnalyzer.analyze(urls: Array(repeating: input, count: 101), projects: [project()])
        XCTAssertEqual(results.count, 101)
        XCTAssertEqual(results[100].readStatus, .limitExceeded)
        XCTAssertNotNil(results[100].sourceIdentity)
        XCTAssertNotNil(results[100].sourceVersion)
        XCTAssertEqual(results[100].projectCandidates.first?.sources, [.filename])
        XCTAssertNil(results[100].observedTextExcerpt)
    }

    func testInvalidPDFIsReadFailureAndDocumentCuesCanRemainAmbiguous() async throws {
        let invalid = try file("invoice-contract.pdf", "not a PDF")
        let result = await ProjectFileAnalyzer.analyze(urls: [invalid], projects: [project()])[0]
        XCTAssertEqual(result.readStatus, .readFailed)
        XCTAssertEqual(Set(result.documentCues), [.contract, .invoice])
        XCTAssertNil(result.suggestedFolder(for: project(template: .byDocument)))
    }

    func testTreeValidationBoundsTraversalCollisionsAndModelRoundtrip() throws {
        for path in ["", "/tmp", "../escape", "자료/../escape", "자료//웹용", ".", ".hidden", "자료/", "자료\n", "자료\\파일", "C:drive"] {
            XCTAssertThrowsError(try ProjectFolderTree.validate([path]), path)
        }
        XCTAssertThrowsError(try ProjectFolderTree.validate(["a/b/c/d/e/f/g/h/i"]))
        XCTAssertThrowsError(try ProjectFolderTree.validate((0..<129).map { "folder\($0)" }))
        XCTAssertThrowsError(try ProjectFolderTree.validate(["Assets", "assets/icon"]))
        XCTAssertThrowsError(try ProjectFolderTree.validate(["자료", "자료"]))
        XCTAssertEqual(try ProjectFolderTree.normalized(["결과물/웹용", "결과물/인쇄용"]), ["결과물", "결과물/웹용", "결과물/인쇄용"])
        let value = project("Taste Buddy", aliases: ["TB"])
        try value.validate()
        XCTAssertEqual(try JSONDecoder().decode(ProjectDefinition.self, from: JSONEncoder().encode(value)), value)
        var unsafe = value; unsafe.rootPath = "/tmp/../escape"
        XCTAssertThrowsError(try unsafe.validate())
    }

    func testKoreanAndEnglishTreeCommandsEditPreviewOnly() throws {
        let original = ["참고자료", "작업파일", "결과물"]
        let split = FolderTreeEditing.apply(command: "결과물을 웹용과 인쇄용으로 나눠줘", to: original)
        XCTAssertTrue(split.applied, split.message)
        XCTAssertEqual(split.folders, original + ["결과물/웹용", "결과물/인쇄용"])
        let renamed = FolderTreeEditing.apply(command: "결과물/웹용을 화면용으로 이름 변경해줘", to: split.folders)
        XCTAssertTrue(renamed.applied, renamed.message)
        XCTAssertTrue(renamed.folders.contains("결과물/화면용"))
        let added = FolderTreeEditing.apply(command: "add folder 참고자료/회의", to: renamed.folders)
        XCTAssertTrue(added.applied, added.message)
        let childAdded = FolderTreeEditing.apply(command: "참고자료에 문서 폴더 추가해줘", to: added.folders)
        XCTAssertTrue(childAdded.applied, childAdded.message)
        XCTAssertTrue(childAdded.folders.contains("참고자료/문서"))
        let deleted = FolderTreeEditing.apply(command: "참고자료 삭제해줘", to: childAdded.folders)
        XCTAssertTrue(deleted.applied, deleted.message)
        XCTAssertFalse(deleted.folders.contains { $0.hasPrefix("참고자료") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testTreeUnsupportedAmbiguousUnsafeAndCollidingRequestsPreserveOriginal() {
        let tree = ["A", "A/자료", "B", "B/자료", "결과물"]
        for command in ["더 감각적으로 정리해줘", "자료 삭제", "자료에 문서 폴더 추가", "add folder ../escape", "rename A to B", "결과물을 웹용과 웹용으로 나눠줘"] {
            let result = FolderTreeEditing.apply(command: command, to: tree)
            XCTAssertFalse(result.applied, command)
            XCTAssertEqual(result.folders, tree)
        }
    }

    private func makePDF(_ name: String, text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 800, height: 240)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        draw(text, in: context)
        context.endPDFPage(); context.closePDF()
        return url
    }
    private func makeImage(_ text: String) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1_200, height: 300, bitsPerComponent: 8, bytesPerRow: 4_800,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 300))
        draw(text, in: context)
        return try XCTUnwrap(context.makeImage())
    }
    private func draw(_ text: String, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 54, nil),
                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 120); CTLineDraw(line, context)
    }
}
