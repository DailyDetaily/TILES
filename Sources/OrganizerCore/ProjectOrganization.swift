import Foundation

public enum ProjectTemplate: String, Sendable, Codable, CaseIterable, Identifiable {
    case simple, byKind, workflow, byDocument, byMonth
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .simple: return "간단하게"
        case .byKind: return "파일 종류별"
        case .workflow: return "작업 단계별"
        case .byDocument: return "문서 용도별"
        case .byMonth: return "월별"
        }
    }
    public var description: String {
        switch self {
        case .simple: return "참고자료·작업파일·결과물 폴더를 직접 골라 정리합니다."
        case .byKind: return "확장자로 확인한 문서·이미지·영상 등 종류별로 나눕니다."
        case .workflow: return "기획·작업·결과물·참고 단계를 직접 지정합니다."
        case .byDocument: return "파일명과 읽은 내용의 문서 유형 단서를 확인합니다."
        case .byMonth: return "파일 수정일의 연도와 월을 기준으로 나눕니다."
        }
    }
    public var defaultFolders: [String] {
        switch self {
        case .simple: return ["참고자료", "작업파일", "결과물"]
        case .byKind: return ["문서", "이미지", "영상", "음원", "압축", "코드", "기타"]
        case .workflow: return ["기획", "참고자료", "작업파일", "결과물"]
        case .byDocument: return ["계약서", "견적서", "청구서", "영수증", "일반 문서", "이미지", "기타"]
        case .byMonth: return []
        }
    }
}

/// Editable preview data. Calling validate does not create or inspect any directories.
public struct ProjectDefinition: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var aliases: [String]
    public var template: ProjectTemplate
    public var folders: [String]

    public init(id: UUID = UUID(), name: String, rootPath: String, aliases: [String] = [],
                template: ProjectTemplate = .simple, folders: [String]? = nil) {
        self.id = id; self.name = name; self.rootPath = rootPath
        self.aliases = aliases; self.template = template
        self.folders = folders ?? template.defaultFolders
    }

    public func validate() throws {
        try ProjectFolderTree.validateName(name)
        guard aliases.count <= 20 else { throw OrganizerError("프로젝트 별칭은 20개까지 사용할 수 있습니다.") }
        for alias in aliases { try ProjectFolderTree.validateName(alias) }
        // rootPath is the only absolute path in the model; folder entries must remain relative.
        guard rootPath.hasPrefix("/"), rootPath != "/", rootPath.utf8.count <= 4_096,
              !rootPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !rootPath.contains("\\"), !rootPath.contains("//"), !rootPath.hasSuffix("/") else {
            throw OrganizerError("프로젝트 위치는 올바른 로컬 절대 경로여야 합니다.")
        }
        for part in rootPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part != ".", part != ".." else { throw OrganizerError("프로젝트 위치에 빈 경로나 상위 경로를 사용할 수 없습니다.") }
        }
        try ProjectFolderTree.validate(folders)
    }
}

public enum ProjectFolderTree {
    public static let maximumFolders = 128
    public static let maximumDepth = 8

    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name != ".", name != "..", !name.hasPrefix("."), name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw OrganizerError("이름에 빈 값, 점으로 시작하는 이름, 경로 구분자 또는 제어 문자를 사용할 수 없습니다.")
        }
    }

    public static func validatePath(_ path: String) throws {
        guard !path.hasPrefix("/"), path.utf8.count <= 1_024 else { throw OrganizerError("프로젝트 안의 상대 폴더 경로를 입력해 주세요.") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= maximumDepth else { throw OrganizerError("폴더는 8단계까지 만들 수 있습니다.") }
        for component in components { try validateName(String(component)) }
    }

    public static func validate(_ folders: [String]) throws {
        _ = try normalized(folders)
    }

    /// Adds ancestors in stable order and rejects aliases that collide on common Mac volumes.
    public static func normalized(_ folders: [String]) throws -> [String] {
        guard folders.count <= maximumFolders else { throw OrganizerError("폴더는 128개까지 만들 수 있습니다.") }
        var result: [String] = [], seen: [String: String] = [:], explicit = Set<String>()
        for path in folders {
            try validatePath(path)
            let key = comparisonKey(path)
            guard explicit.insert(key).inserted else { throw OrganizerError("같은 이름의 폴더가 중복되어 있습니다: \(path)") }
            let parts = path.split(separator: "/")
            for length in 1...parts.count {
                let ancestor = parts.prefix(length).joined(separator: "/")
                let ancestorKey = comparisonKey(ancestor)
                if let existing = seen[ancestorKey] {
                    guard existing == ancestor else { throw OrganizerError("대소문자나 유니코드 표기만 다른 폴더가 겹칩니다: \(ancestor)") }
                } else {
                    seen[ancestorKey] = ancestor; result.append(ancestor)
                    guard result.count <= maximumFolders else { throw OrganizerError("상위 폴더를 포함해 128개까지 만들 수 있습니다.") }
                }
            }
        }
        return result
    }

    static func comparisonKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
