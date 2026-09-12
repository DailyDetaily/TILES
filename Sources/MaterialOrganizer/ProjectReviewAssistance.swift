import Foundation
import Combine
import Darwin
import OrganizerCore

/// Explicit recommendation settings. This store never changes source files or executes moves.
@MainActor final class ProjectReviewAssistance: ObservableObject {
    @Published private(set) var rules: [ProjectReviewRule] = []
    @Published private(set) var storeReadable = true
    @Published var failure: String?
    private let url: URL
    private var expectedBytes: Data?
    private let maximumBytes = 1_048_576
    static let maximumRules = 200

    private struct State: Codable {
        var version = 1
        var rules: [ProjectReviewRule]
    }

    init(stateDirectory: URL) {
        url = stateDirectory.appendingPathComponent("ReviewRules.json")
        do {
            let bytes = try readBytes()
            if let bytes {
                let state = try JSONDecoder().decode(State.self, from: bytes)
                guard state.version == 1 else { throw OrganizerError("지원하지 않는 추천 규칙 버전입니다.") }
                try validate(state.rules)
                rules = state.rules
            }
            expectedBytes = bytes
        } catch {
            storeReadable = false
            failure = "추천 규칙을 읽지 못해 기존 기록을 보존했습니다. \(error.localizedDescription)"
        }
    }

    @discardableResult func save(_ rule: ProjectReviewRule) -> Bool {
        var updated = rules
        // An identical condition and destination is updated, not duplicated. Different destinations
        // remain visible as a conflict so saving a rule never silently replaces another decision.
        if let index = updated.firstIndex(where: {
            $0.id == rule.id || ($0.sourceDirectory == rule.sourceDirectory &&
                ProjectReviewRuleResolver.normalizedName($0.filenamePrefix) == ProjectReviewRuleResolver.normalizedName(rule.filenamePrefix) &&
                ProjectReviewRuleResolver.normalizedName($0.fileExtension) == ProjectReviewRuleResolver.normalizedName(rule.fileExtension) &&
                $0.projectID == rule.projectID && $0.projectRootPath == rule.projectRootPath && $0.folder == rule.folder)
        }) {
            var replacement = rule; replacement.id = updated[index].id
            updated[index] = replacement
        } else { updated.append(rule) }
        return commit(updated)
    }

    @discardableResult func setEnabled(_ id: UUID, _ enabled: Bool) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return false }
        var updated = rules; updated[index].enabled = enabled
        return commit(updated)
    }

    @discardableResult func remove(_ id: UUID) -> Bool {
        guard rules.contains(where: { $0.id == id }) else { return false }
        return commit(rules.filter { $0.id != id })
    }

    private func validate(_ rules: [ProjectReviewRule]) throws {
        guard rules.count <= Self.maximumRules, Set(rules.map(\.id)).count == rules.count else {
            throw OrganizerError("추천 규칙은 중복되지 않는 200개까지 저장할 수 있습니다.")
        }
        for rule in rules { try rule.validate() }
    }

    private func commit(_ updated: [ProjectReviewRule]) -> Bool {
        guard storeReadable else { return false }
        do {
            try validate(updated)
            guard try readBytes() == expectedBytes else {
                storeReadable = false
                throw OrganizerError("다른 곳에서 추천 규칙이 바뀌었습니다. 앱을 다시 열어 최신 규칙을 확인해 주세요.")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(State(rules: updated))
            guard bytes.count <= maximumBytes else { throw OrganizerError("추천 규칙 기록의 크기 한도를 넘었습니다.") }
            try SafeFileSystem.validateDirectory(url.deletingLastPathComponent())
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".ReviewRules-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw OrganizerError("추천 규칙 임시 기록을 만들지 못했습니다.") }
            do {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: bytes); try handle.synchronize()
            }
            guard rename(temporary.path, url.path) == 0 else { throw OrganizerError("이전 추천 규칙을 교체하지 못했습니다.") }
            rules = updated; expectedBytes = bytes; failure = nil
            return true
        } catch { failure = "추천 규칙을 저장하지 못했습니다. \(error.localizedDescription)"; return false }
    }

    private func readBytes() throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0,
              info.st_size <= maximumBytes, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw OrganizerError("추천 규칙 기록이 읽을 수 있는 일반 파일이 아닙니다.")
        }
        try SafeFileSystem.validateDirectory(url.deletingLastPathComponent())
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumBytes else { throw OrganizerError("추천 규칙 기록이 너무 큽니다.") }
        return bytes
    }
}

struct ReviewClarificationGroup: Identifiable {
    var id: String
    var rowIDs: Set<UUID>
    var question: String
    var detail: String
    var names: [String]
    var sourceDirectory: String
    var suggestedPrefix: String?
}

struct ReviewRuleDraft {
    var sourceDirectory: String
    var fileExtension: String
    var prefix: String
    var projectID: UUID
    var projectRootPath: String
    var folder: String
    var matchingNames: [String]
}

extension ProjectReviewModel {
    /// These are review shortcuts, never additional evidence of project membership.
    var clarificationGroups: [ReviewClarificationGroup] {
        let available = rows.filter { $0.included && $0.evidence.sourceIdentity != nil && $0.evidence.readStatus != .cancelled }
        let buckets = Dictionary(grouping: available) { row in
            let url = URL(fileURLWithPath: row.evidence.sourcePath)
            let candidates = row.evidence.projectCandidates.map { $0.projectID.uuidString }.sorted().joined(separator: ",")
            let issue = row.ruleConflict ? "rule" : row.projectID == nil ? "project" : row.folder == nil ? "folder" : "ready"
            return [url.deletingLastPathComponent().path, url.pathExtension.lowercased(),
                    row.projectID?.uuidString ?? "", row.folder ?? "?", candidates, issue].joined(separator: "\u{1F}")
        }
        return buckets.compactMap { key, members -> ReviewClarificationGroup? in
            let sorted = members.sorted { $0.evidence.name.localizedStandardCompare($1.evidence.name) == .orderedAscending }
            guard let first = sorted.first else { return nil }
            let names = sorted.map { $0.evidence.name }
            let prefix = ProjectReviewRuleResolver.sharedPrefix(names: names)
            let question: String, detail: String
            if first.ruleConflict {
                question = "서로 다른 추천 중 어디로 정리할까요?"
                detail = first.ruleReason ?? "저장한 규칙과 현재 파일의 단서가 일치하지 않습니다."
            } else if first.projectID == nil {
                question = first.evidence.projectMatch == .ambiguous ? "어느 프로젝트의 파일인가요?" : "어디에 정리할까요?"
                detail = first.evidence.projectMatch == .ambiguous ? "여러 프로젝트 이름이 함께 발견됐습니다." : "프로젝트를 정할 단서가 부족합니다."
            } else if first.folder == nil {
                question = "이 파일들은 어떤 용도인가요?"
                detail = "\(projectName(first)) 안에서 사용할 폴더를 골라 주세요. 파일 형식과 날짜로 작업 단계를 판단하지 않습니다."
            } else {
                guard sorted.count > 1, prefix != nil, !sorted.allSatisfy(\.explicitlyAssigned) else { return nil }
                question = "이 파일들을 같은 위치에 정리할까요?"
                detail = "파일명 앞부분과 원본 폴더·확장자가 같습니다. 같은 프로젝트라는 뜻은 아니며, 함께 확인할 수 있습니다."
            }
            return .init(id: key, rowIDs: Set(sorted.map(\.id)), question: question, detail: detail, names: names,
                         sourceDirectory: URL(fileURLWithPath: first.evidence.sourcePath).deletingLastPathComponent().path,
                         suggestedPrefix: prefix)
        }.sorted { $0.id < $1.id }
    }

    func projectForGroup(_ id: String) -> ProjectDefinition? {
        guard let group = clarificationGroups.first(where: { $0.id == id }) else { return nil }
        let members = rows.filter { group.rowIDs.contains($0.id) }
        let ids = Set(members.compactMap(\.projectID))
        guard members.allSatisfy({ $0.projectID != nil }), ids.count == 1 else { return nil }
        return project(ids.first)
    }

    func ruleDraft() -> ReviewRuleDraft? {
        let chosen = rows.filter(\.included)
        guard let first = chosen.first, chosen.allSatisfy(\.isReady),
              let id = first.projectID, let target = project(id), let folder = first.folder else { return nil }
        let source = URL(fileURLWithPath: first.evidence.sourcePath)
        let parent = source.deletingLastPathComponent().path, ext = source.pathExtension.lowercased()
        guard chosen.allSatisfy({ row in
            let url = URL(fileURLWithPath: row.evidence.sourcePath)
            return url.deletingLastPathComponent().path == parent && url.pathExtension.lowercased() == ext && row.projectID == id && row.folder == folder
        }) else { return nil }
        let names = chosen.map { $0.evidence.name }.sorted()
        let prefix = ProjectReviewRuleResolver.sharedPrefix(names: names) ?? (chosen.count == 1 ? source.deletingPathExtension().lastPathComponent : "")
        return .init(sourceDirectory: parent, fileExtension: ext, prefix: prefix, projectID: id,
                     projectRootPath: target.rootPath, folder: folder, matchingNames: names)
    }

    func ruleMatchingNames(prefix: String) -> [String] {
        guard let draft = ruleDraft(), !prefix.isEmpty else { return [] }
        let rule = ProjectReviewRule(sourceDirectory: draft.sourceDirectory, filenamePrefix: prefix, fileExtension: draft.fileExtension,
                                     projectID: draft.projectID, projectRootPath: draft.projectRootPath, folder: draft.folder)
        return rows.filter { row in
            row.evidence.sourceIdentity != nil && row.evidence.readStatus != .cancelled &&
                ProjectReviewRuleResolver.matchesScope(rule, source: URL(fileURLWithPath: row.evidence.sourcePath))
        }.map { $0.evidence.name }.sorted()
    }

    @discardableResult func rememberRule(prefix: String) -> Bool {
        guard !owner.busy, storeReadable, assistance.storeReadable, let draft = ruleDraft(),
              !ruleMatchingNames(prefix: prefix).isEmpty else {
            assistance.failure = "같은 원본 폴더·확장자·목적지의 파일을 선택하고 일치하는 접두어를 입력해 주세요."
            return false
        }
        let rule = ProjectReviewRule(sourceDirectory: draft.sourceDirectory, filenamePrefix: prefix, fileExtension: draft.fileExtension,
                                     projectID: draft.projectID, projectRootPath: draft.projectRootPath, folder: draft.folder)
        guard assistance.save(rule) else { return false }
        notice = "추천 기준을 저장했습니다. 같은 원본 폴더의 일치하는 파일에만 사용합니다."
        if activeBatchID != nil { analyzeActive() }
        return true
    }

    func setRuleEnabled(_ id: UUID, _ enabled: Bool) {
        guard !owner.busy, storeReadable, assistance.setEnabled(id, enabled) else { return }
        if activeBatchID != nil { analyzeActive() }
    }

    func removeRule(_ id: UUID) {
        guard !owner.busy, storeReadable, assistance.remove(id) else { return }
        if activeBatchID != nil { analyzeActive() }
    }
}
