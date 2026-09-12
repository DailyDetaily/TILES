import Foundation

/// A recommendation explicitly saved by the user. Matching never creates a rule or moves a file.
public struct ProjectReviewRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourceDirectory: String
    public var filenamePrefix: String
    public var fileExtension: String
    public var projectID: UUID
    /// Keep the destination fixed to the project location the user reviewed when saving this rule.
    public var projectRootPath: String
    /// An empty string selects the project root.
    public var folder: String
    public var enabled: Bool

    public init(id: UUID = UUID(), sourceDirectory: String, filenamePrefix: String, fileExtension: String,
                projectID: UUID, projectRootPath: String, folder: String = "", enabled: Bool = true) {
        self.id = id; self.sourceDirectory = sourceDirectory; self.filenamePrefix = filenamePrefix
        self.fileExtension = fileExtension; self.projectID = projectID; self.projectRootPath = projectRootPath
        self.folder = folder; self.enabled = enabled
    }

    /// Validate stored values without silently widening or rewriting the user's chosen scope.
    public func validate() throws {
        try validateScope()
        try Self.validateAbsolutePath(projectRootPath, allowRoot: false)
        if !folder.isEmpty { try ProjectFolderTree.validatePath(folder) }
    }

    fileprivate func validateScope() throws {
        try Self.validateAbsolutePath(sourceDirectory, allowRoot: true)
        guard filenamePrefix.count >= 2, filenamePrefix.utf8.count <= 255,
              filenamePrefix.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }),
              !filenamePrefix.contains("/"), !filenamePrefix.contains("\\"), !filenamePrefix.contains(":"),
              !filenamePrefix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw OrganizerError("파일명 시작 부분은 문자나 숫자를 포함한 2자 이상이어야 하며 경로 문자와 제어 문자를 사용할 수 없습니다.")
        }
        guard fileExtension.utf8.count <= 32,
              !fileExtension.contains("."), !fileExtension.contains("/"), !fileExtension.contains("\\"), !fileExtension.contains(":"),
              !fileExtension.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else {
            throw OrganizerError("확장자는 점이나 경로 문자 없이 입력해 주세요. 확장자가 없는 파일은 빈 값으로 지정할 수 있습니다.")
        }
    }

    fileprivate static func validateAbsolutePath(_ path: String, allowRoot: Bool) throws {
        if allowRoot, path == "/" { return }
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4_096,
              !path.hasSuffix("/"), !path.contains("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw OrganizerError("규칙의 위치는 올바른 로컬 절대 경로여야 합니다.")
        }
        for component in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw OrganizerError("규칙의 위치에 빈 경로나 상위 경로를 사용할 수 없습니다.")
            }
        }
    }
}

public struct ProjectReviewRuleResolution: Equatable, Sendable {
    public var matchedRuleIDs: [UUID]
    public var projectID: UUID?
    public var folder: String?
    public var reason: String?
    public var conflict: Bool

    public init(matchedRuleIDs: [UUID] = [], projectID: UUID? = nil, folder: String? = nil,
                reason: String? = nil, conflict: Bool = false) {
        self.matchedRuleIDs = matchedRuleIDs; self.projectID = projectID; self.folder = folder
        self.reason = reason; self.conflict = conflict
    }
}

public enum ProjectReviewRuleResolver {
    /// Use the same explicit scope for previews and recommendations. Enabled state and live file checks belong to callers.
    public static func matchesScope(_ rule: ProjectReviewRule, source: URL) -> Bool {
        guard source.isFileURL, source.host == nil || source.host == "" || source.host == "localhost",
              source.user == nil, source.password == nil, source.port == nil,
              source.query == nil, source.fragment == nil,
              (try? ProjectReviewRule.validateAbsolutePath(source.path, allowRoot: false)) != nil,
              (try? rule.validateScope()) != nil else { return false }
        return rule.sourceDirectory == source.deletingLastPathComponent().path
            && normalizedName(source.pathExtension) == normalizedName(rule.fileExtension)
            && normalizedName(source.lastPathComponent).hasPrefix(normalizedName(rule.filenamePrefix))
    }

    /// Resolve only observed, valid file evidence. The move planner still checks the live source and destination.
    public static func resolve(evidence: FileEvidence, projects: [ProjectDefinition],
                               rules: [ProjectReviewRule]) -> ProjectReviewRuleResolution {
        guard evidence.sourceIdentity?.kind == "file", evidence.readStatus != .cancelled,
              evidence.readStatus != .invalidFile,
              (try? ProjectReviewRule.validateAbsolutePath(evidence.sourcePath, allowRoot: false)) != nil else {
            return .init()
        }
        let source = URL(fileURLWithPath: evidence.sourcePath)
        let matches = rules.filter { $0.enabled && matchesScope($0, source: source) }
        guard !matches.isEmpty else { return .init() }
        var seen = Set<UUID>()
        let matchedIDs = matches.map(\.id).filter { seen.insert($0).inserted }
        func conflict(_ reason: String) -> ProjectReviewRuleResolution {
            .init(matchedRuleIDs: matchedIDs, reason: reason, conflict: true)
        }

        for rule in matches {
            let targets = projects.filter { $0.id == rule.projectID }
            guard (try? rule.validate()) != nil, targets.count == 1,
                  let project = targets.first, (try? project.validate()) != nil else {
                return conflict("저장한 규칙의 프로젝트 또는 목적지가 없어졌거나 유효하지 않아 다시 확인해야 합니다.")
            }
            guard project.rootPath == rule.projectRootPath else {
                return conflict("저장한 규칙의 프로젝트 위치가 바뀌어 다시 확인해야 합니다.")
            }
            // Monthly projects already support user-selected relative folders outside their saved tree.
            let folders = (try? ProjectFolderTree.normalized(project.folders)) ?? []
            guard rule.folder.isEmpty || project.template == .byMonth || folders.contains(rule.folder) else {
                return conflict("저장한 규칙의 폴더가 프로젝트에서 삭제되거나 이름이 바뀌어 다시 확인해야 합니다.")
            }
        }

        let first = matches[0]
        guard matches.allSatisfy({ $0.projectID == first.projectID && $0.projectRootPath == first.projectRootPath && $0.folder == first.folder }) else {
            return conflict("같은 파일에 서로 다른 목적지의 규칙이 일치해 직접 확인해야 합니다.")
        }
        guard !evidence.projectCandidates.contains(where: { $0.projectID != first.projectID }) else {
            return conflict("파일에서 확인한 프로젝트 단서가 저장한 규칙과 달라 직접 확인해야 합니다.")
        }
        return .init(matchedRuleIDs: matchedIDs, projectID: first.projectID, folder: first.folder,
                     reason: "이 원본 폴더에서 같은 확장자와 파일명 시작 부분에 적용하도록 저장한 규칙입니다.")
    }

    /// A grouping hint only. A common prefix (including IMG_) is never project evidence by itself.
    /// The returned prefix ends at the last shared space, underscore or hyphen before differing text.
    public static func sharedPrefix(names: [String]) -> String? {
        guard names.count >= 2, Set(names).count >= 2,
              names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\")
                  && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { return nil }
        let stems = names.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping }
        guard let first = stems.first, !first.isEmpty else { return nil }
        let others = stems.dropFirst().map { Array($0) }
        var common = ""
        for (index, character) in first.enumerated() {
            guard others.allSatisfy({ index < $0.count && normalizedName(String($0[index])) == normalizedName(String(character)) }) else { break }
            common.append(character)
        }
        guard let delimiter = common.lastIndex(where: { $0 == " " || $0 == "_" || $0 == "-" }) else { return nil }
        let prefix = String(common[...delimiter])
        guard prefix.count >= 2, prefix.utf8.count <= 255,
              prefix.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }), !prefix.contains(":") else { return nil }
        return prefix
    }

    /// Canonical Unicode and locale-stable case folding for file names, prefixes, extensions and rule deduplication.
    public static func normalizedName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
