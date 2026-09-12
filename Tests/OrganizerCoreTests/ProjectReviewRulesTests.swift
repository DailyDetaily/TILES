import Foundation
import XCTest
@testable import OrganizerCore

final class ProjectReviewRulesTests: XCTestCase {
    private let sourceDirectory = "/Users/reader/Downloads"
    private let projectID = UUID()

    private func project(id: UUID? = nil, rootPath: String = "/Users/reader/Projects/AAO",
                         template: ProjectTemplate = .simple, folders: [String]? = nil) -> ProjectDefinition {
        .init(id: id ?? projectID, name: "AAO", rootPath: rootPath, template: template, folders: folders)
    }

    private func rule(prefix: String = "AAO_", fileExtension: String = "pdf", folder: String = "참고자료",
                      enabled: Bool = true) -> ProjectReviewRule {
        .init(sourceDirectory: sourceDirectory, filenamePrefix: prefix, fileExtension: fileExtension,
              projectID: projectID, projectRootPath: project().rootPath, folder: folder, enabled: enabled)
    }

    private func evidence(name: String = "AAO_notes.pdf", directory: String? = nil,
                          status: FileContentReadStatus = .metadataOnly, candidates: [UUID] = []) -> FileEvidence {
        let path = (directory ?? sourceDirectory) + "/" + name
        return .init(id: UUID(), sourcePath: path, sourceIdentity: .init(device: 1, inode: 2, kind: "file"),
                     sourceVersion: nil, kind: .detect(URL(fileURLWithPath: path)), readStatus: status, reasons: [],
                     projectCandidates: candidates.map { .init(projectID: $0, projectName: "Observed project", reasons: ["파일명"], sources: [.filename]) },
                     documentCues: [], modifiedAt: nil, observedTextExcerpt: nil)
    }

    func testExplicitScopeMatchesAndReturnsRootSelectionAsEmptyFolder() throws {
        let saved = rule(folder: "")
        try saved.validate()
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [saved])
        XCTAssertEqual(result.matchedRuleIDs, [saved.id])
        XCTAssertEqual(result.projectID, projectID)
        XCTAssertEqual(result.folder, "")
        XCTAssertNotNil(result.reason)
        XCTAssertFalse(result.conflict)
    }

    func testScopeIsOnlyExactImmediateParent() {
        let saved = rule()
        for directory in [sourceDirectory + "/nested", sourceDirectory + "2", "/Users/reader/downloads", "/Users/reader"] {
            let result = ProjectReviewRuleResolver.resolve(evidence: evidence(directory: directory), projects: [project()], rules: [saved])
            XCTAssertEqual(result, .init(), directory)
        }
    }

    func testPrefixAndExtensionMustBothMatchWithoutBroadeningToFileKind() {
        let saved = rule()
        for name in ["notes_AAO_.pdf", "AAOxnotes.pdf", "AAO_notes.png", "AAO_notes.docx", "AAO_notes.pdf.backup", "AAO_notes"] {
            XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(name: name), projects: [project()], rules: [saved]), .init(), name)
        }
        let matching = ProjectReviewRuleResolver.resolve(evidence: evidence(name: "aao_notes.PDF"), projects: [project()], rules: [saved])
        XCTAssertEqual(matching.projectID, projectID)
    }

    func testUnicodeNormalizationAndCaseDoNotRemoveAccents() {
        let saved = rule(prefix: "CAFÉ_", fileExtension: "TÉXT")
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(name: "cafe\u{301}_노트.te\u{301}xt"), projects: [project()], rules: [saved])
        XCTAssertEqual(result.projectID, projectID)
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(name: "cafe_노트.téxt"), projects: [project()], rules: [saved]), .init())
    }

    func testScopePreviewAndResolverShareUnicodeCaseFoldingForExpandedCharacters() {
        let saved = rule(prefix: "STRASSE_")
        let observed = evidence(name: "Straße_01.pdf")
        XCTAssertTrue(ProjectReviewRuleResolver.matchesScope(saved, source: URL(fileURLWithPath: observed.sourcePath)))
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: observed, projects: [project()], rules: [saved]).projectID, projectID)
        XCTAssertEqual(ProjectReviewRuleResolver.normalizedName("STRASSE_"), ProjectReviewRuleResolver.normalizedName("Straße_"))
        XCTAssertEqual(ProjectReviewRuleResolver.normalizedName("CAFÉ_"), ProjectReviewRuleResolver.normalizedName("cafe\u{301}_"))
        XCTAssertNotEqual(ProjectReviewRuleResolver.normalizedName("CAFÉ_"), ProjectReviewRuleResolver.normalizedName("CAFE_"))
    }

    func testTwoCharacterPrefixPreservesExplicitTrailingSpaceBoundary() throws {
        let saved = rule(prefix: "O ")
        try saved.validate()
        XCTAssertTrue(ProjectReviewRuleResolver.matchesScope(saved, source: URL(fileURLWithPath: sourceDirectory + "/o 01.pdf")))
        XCTAssertFalse(ProjectReviewRuleResolver.matchesScope(saved, source: URL(fileURLWithPath: sourceDirectory + "/Orange.pdf")))
        XCTAssertFalse(ProjectReviewRuleResolver.matchesScope(saved, source: URL(fileURLWithPath: sourceDirectory + "/O_01.pdf")))
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(name: "O 01.pdf"), projects: [project()], rules: [saved]).projectID, projectID)
        let tooShort = rule(prefix: "O")
        XCTAssertThrowsError(try tooShort.validate())
        XCTAssertFalse(ProjectReviewRuleResolver.matchesScope(tooShort, source: URL(fileURLWithPath: sourceDirectory + "/O 01.pdf")))
    }

    func testScopeMatcherChecksLocalURLShapeAndIgnoresEnabledStateOnly() throws {
        let saved = rule(enabled: false)
        let path = sourceDirectory + "/AAO_notes.pdf"
        XCTAssertTrue(ProjectReviewRuleResolver.matchesScope(saved, source: URL(fileURLWithPath: path)))
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [saved]), .init())
        for url in ["https://example.com" + path, "file://remote.example" + path,
                    "file://localhost" + path + "?query=1", "file://localhost" + path + "#fragment",
                    "file://user@localhost" + path, "file://localhost:80" + path,
                    "file://localhost/Users/reader/Downloads/../Downloads/AAO_notes.pdf"] {
            XCTAssertFalse(ProjectReviewRuleResolver.matchesScope(saved, source: try XCTUnwrap(URL(string: url))), url)
        }
        XCTAssertFalse(ProjectReviewRuleResolver.matchesScope(rule(prefix: ""), source: URL(fileURLWithPath: path)))
        XCTAssertFalse(ProjectReviewRuleResolver.matchesScope(saved, source: URL(fileURLWithPath: sourceDirectory + "/nested/AAO_notes.pdf")))
        XCTAssertFalse(ProjectReviewRuleResolver.matchesScope(saved, source: URL(fileURLWithPath: sourceDirectory + "/AAO_notes.txt")))
    }

    func testEmptyExtensionMatchesOnlyFilesWithoutAnExtension() throws {
        let saved = rule(fileExtension: "")
        try saved.validate()
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(name: "AAO_notes"), projects: [project()], rules: [saved]).projectID, projectID)
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [saved]), .init())
    }

    func testInvalidPrefixCannotBecomeAnAllFilesRule() {
        for prefix in ["", "A", "__", "  ", "A/", "A\\", "A:", "AA\n", "AA\u{0}", String(repeating: "a", count: 256)] {
            let saved = rule(prefix: prefix)
            XCTAssertThrowsError(try saved.validate(), prefix)
            XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [saved]), .init())
        }
        XCTAssertNoThrow(try rule(prefix: "A_").validate())
        XCTAssertNoThrow(try rule(prefix: "프로젝트 ").validate())
    }

    func testInvalidExtensionsAreRejected() {
        for ext in [".pdf", "p.df", "../pdf", "p\\df", "pdf:", "p df", "pdf\n", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(try rule(fileExtension: ext).validate(), ext)
        }
    }

    func testNonAbsoluteAndTraversalScopePathsCannotMatch() {
        for path in ["", "Downloads", "file:///Downloads", "/Users//reader/Downloads", "/Users/reader/../Downloads", "/Users/reader/./Downloads", sourceDirectory + "/", sourceDirectory + "\n"] {
            var saved = rule(); saved.sourceDirectory = path
            XCTAssertThrowsError(try saved.validate(), path)
            XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [saved]), .init())
        }
        var invalidSource = evidence(); invalidSource.sourcePath = sourceDirectory + "/../Downloads/AAO_notes.pdf"
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: invalidSource, projects: [project()], rules: [rule()]), .init())
    }

    func testDestinationPathsAreValidatedBeforeRecommendation() {
        for path in ["/", "Projects/AAO", "/Users/reader/../AAO", "/Users/reader//AAO", "/Users/reader/AAO/"] {
            var saved = rule(); saved.projectRootPath = path
            XCTAssertThrowsError(try saved.validate(), path)
            let result = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [saved])
            XCTAssertTrue(result.conflict, path)
            XCTAssertEqual(result.matchedRuleIDs, [saved.id])
            XCTAssertNil(result.projectID)
        }
        for folder in ["../escape", "/outside", "참고자료/../escape", "참고자료//문서"] {
            let saved = rule(folder: folder)
            XCTAssertThrowsError(try saved.validate(), folder)
            XCTAssertTrue(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [saved]).conflict)
        }
    }

    func testDifferentFoldersOrProjectsMatchingSameFileHoldForReview() {
        let first = rule(), otherFolder = rule(prefix: "AAO", folder: "결과물")
        let folderConflict = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [first, otherFolder])
        XCTAssertTrue(folderConflict.conflict)
        XCTAssertEqual(folderConflict.matchedRuleIDs, [first.id, otherFolder.id])
        XCTAssertNil(folderConflict.projectID)
        XCTAssertNil(folderConflict.folder)

        let other = project(id: UUID(), rootPath: "/Users/reader/Projects/Other")
        var otherRule = rule(); otherRule.projectID = other.id; otherRule.projectRootPath = other.rootPath
        let projectConflict = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project(), other], rules: [first, otherRule])
        XCTAssertTrue(projectConflict.conflict)
        XCTAssertNil(projectConflict.projectID)
    }

    func testSeveralRulesForSameDestinationResolveToOneRecommendation() {
        let first = rule(), second = rule(prefix: "AAO")
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [first, second, first])
        XCTAssertEqual(result.matchedRuleIDs, [first.id, second.id])
        XCTAssertEqual(result.projectID, projectID)
        XCTAssertEqual(result.folder, "참고자료")
        XCTAssertFalse(result.conflict)
    }

    func testDeletedProjectAndChangedRootInvalidateMatchingRule() {
        let saved = rule()
        let deleted = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [], rules: [saved])
        XCTAssertTrue(deleted.conflict)
        XCTAssertNil(deleted.projectID)
        XCTAssertEqual(deleted.matchedRuleIDs, [saved.id])
        let changed = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project(rootPath: "/Users/reader/Projects/NewLocation")], rules: [saved])
        XCTAssertTrue(changed.conflict)
        XCTAssertNil(changed.projectID)
        XCTAssertNil(changed.folder)
    }

    func testDeletedFolderAndDuplicateProjectIDInvalidateMatchingRule() {
        let saved = rule()
        XCTAssertTrue(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project(folders: ["결과물"])], rules: [saved]).conflict)
        XCTAssertTrue(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project(), project()], rules: [saved]).conflict)
    }

    func testNormalizedAncestorRemainsAValidFolder() {
        let saved = rule()
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project(folders: ["참고자료/문서"])], rules: [saved])
        XCTAssertEqual(result.folder, "참고자료")
        XCTAssertFalse(result.conflict)
    }

    func testMonthlyTemplateRetainsLegalUserChosenFolderCompatibility() {
        for folder in ["2026-09", "2026/09", "직접 지정한 월"] {
            let saved = rule(folder: folder)
            let result = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project(template: .byMonth)], rules: [saved])
            XCTAssertEqual(result.folder, folder)
            XCTAssertFalse(result.conflict)
        }
        XCTAssertTrue(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project(template: .byMonth)], rules: [rule(folder: "../escape")]).conflict)
    }

    func testDisabledAndUnmatchedStaleRulesDoNotBlockValidRule() {
        let valid = rule()
        var disabled = rule(folder: "삭제된 폴더", enabled: false); disabled.projectID = UUID()
        var unrelated = rule(prefix: "Other_"); unrelated.projectID = UUID()
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [disabled, unrelated, valid])
        XCTAssertEqual(result.matchedRuleIDs, [valid.id])
        XCTAssertEqual(result.projectID, projectID)
        XCTAssertFalse(result.conflict)
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [], rules: [disabled]), .init())
    }

    func testMatchingStaleRuleBlocksAnotherOtherwiseValidRule() {
        let valid = rule()
        var deletedProject = rule(prefix: "AAO"); deletedProject.projectID = UUID()
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(), projects: [project()], rules: [valid, deletedProject])
        XCTAssertTrue(result.conflict)
        XCTAssertEqual(result.matchedRuleIDs, [valid.id, deletedProject.id])
        XCTAssertNil(result.projectID)
    }

    func testObservedOtherProjectEvidenceCannotBeOverriddenByRule() {
        let saved = rule(), otherID = UUID()
        for candidates in [[otherID], [projectID, otherID]] {
            let result = ProjectReviewRuleResolver.resolve(evidence: evidence(candidates: candidates), projects: [project()], rules: [saved])
            XCTAssertTrue(result.conflict)
            XCTAssertNil(result.projectID)
            XCTAssertNil(result.folder)
        }
        XCTAssertFalse(ProjectReviewRuleResolver.resolve(evidence: evidence(candidates: [projectID]), projects: [project()], rules: [saved]).conflict)
    }

    func testCancelledInvalidOrUnidentifiedSourceCannotReceiveRecommendation() {
        let saved = rule()
        for status in [FileContentReadStatus.cancelled, .invalidFile] {
            XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(status: status), projects: [project()], rules: [saved]), .init())
        }
        var unidentified = evidence(); unidentified.sourceIdentity = nil
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: unidentified, projects: [project()], rules: [saved]), .init())
        var directory = evidence(); directory.sourceIdentity?.kind = "directory"
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: directory, projects: [project()], rules: [saved]), .init())
    }

    func testObservedMetadataStillMatchesWhenContentBudgetWasExceeded() {
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(status: .limitExceeded), projects: [project()], rules: [rule()])
        XCTAssertEqual(result.projectID, projectID)
        XCTAssertFalse(result.conflict)
    }

    func testNoRulesMeansNoRecommendationOrImplicitLearning() {
        let rules: [ProjectReviewRule] = []
        let result = ProjectReviewRuleResolver.resolve(evidence: evidence(candidates: [projectID]), projects: [project()], rules: rules)
        XCTAssertEqual(result, .init())
        XCTAssertTrue(rules.isEmpty)
    }

    func testCodableRoundTripPreservesExplicitScopeAndEnabledState() throws {
        let saved = rule(prefix: "AAO_", fileExtension: "PDF", enabled: false)
        let restored = try JSONDecoder().decode(ProjectReviewRule.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored, saved)
        try restored.validate()
        XCTAssertFalse(restored.enabled)
    }

    func testSharedPrefixUsesStemsAndLastSharedDelimiterOnly() {
        XCTAssertEqual(ProjectReviewRuleResolver.sharedPrefix(names: ["AAO_견적서_v1.pdf", "AAO_견적서_v2.pdf"]), "AAO_견적서_")
        XCTAssertEqual(ProjectReviewRuleResolver.sharedPrefix(names: ["Client A 01.png", "Client A 02.png"]), "Client A ")
        XCTAssertEqual(ProjectReviewRuleResolver.sharedPrefix(names: ["IMG_2048.png", "IMG_2049.png"]), "IMG_")
        XCTAssertEqual(ProjectReviewRuleResolver.sharedPrefix(names: ["AAO-notes.pdf", "aao-contract.pdf"]), "AAO-")
        XCTAssertNil(ProjectReviewRuleResolver.sharedPrefix(names: ["AAO.pdf", "AAO.png"]))
    }

    func testSharedPrefixDoesNotInventProjectEvidenceOrAcceptUnsafeNames() {
        for names in [[], ["AAO_one.pdf"], ["AAO_one.pdf", "AAO_one.pdf"], ["abc1.pdf", "abc2.pdf"],
                      ["_1.pdf", "_2.pdf"], ["A1.pdf", "B1.pdf"], ["/tmp/AAO_one.pdf", "/tmp/AAO_two.pdf"],
                      ["AAO_\none.pdf", "AAO_\ntwo.pdf"]] {
            XCTAssertNil(ProjectReviewRuleResolver.sharedPrefix(names: names), names.joined(separator: ", "))
        }
        XCTAssertEqual(ProjectReviewRuleResolver.resolve(evidence: evidence(name: "IMG_2048.png"), projects: [project()], rules: []), .init())
    }

    func testSharedPrefixHandlesComposedAndDecomposedUnicode() {
        XCTAssertEqual(ProjectReviewRuleResolver.sharedPrefix(names: ["CAFÉ_01.pdf", "cafe\u{301}_02.pdf"]), "CAFÉ_")
    }
}
