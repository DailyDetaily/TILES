import Foundation

public enum FolderTreeEdit: Sendable, Equatable {
    case add(path: String)
    case addChild(parent: String, name: String)
    case remove(path: String)
    case rename(path: String, to: String)
    case split(path: String, into: [String])
}

public struct FolderTreeEditResult: Sendable, Equatable {
    public var folders: [String]
    public var applied: Bool
    public var message: String
    public init(folders: [String], applied: Bool, message: String) {
        self.folders = folders; self.applied = applied; self.message = message
    }
}

/// A bounded local command grammar. This edits preview strings only and never touches disk.
public enum FolderTreeEditing {
    public static func apply(command: String, to folders: [String]) -> FolderTreeEditResult {
        guard command.utf8.count <= 2_048,
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .init(folders: folders, applied: false, message: "요청은 제어 문자 없이 2,048바이트 안으로 입력해 주세요.")
        }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let edit = parse(command) else {
            return .init(folders: folders, applied: false,
                         message: "지원하는 폴더 편집 요청을 찾지 못했습니다. 예: ‘자료 폴더 추가’, ‘자료 삭제’, ‘자료를 참고자료로 이름 변경’, ‘결과물을 웹용과 인쇄용으로 나눠줘’. 폴더 경로를 정확히 적어 주세요.")
        }
        return apply(edit, to: folders)
    }

    public static func apply(_ edit: FolderTreeEdit, to folders: [String]) -> FolderTreeEditResult {
        do {
            var updated = try ProjectFolderTree.normalized(folders)
            let message: String
            switch edit {
            case .add(let path):
                try ProjectFolderTree.validatePath(path)
                guard !updated.contains(path) else { throw OrganizerError("이미 있는 폴더입니다: \(path)") }
                updated.append(path)
                message = "미리보기에 ‘\(path)’ 폴더를 추가했습니다."
            case .addChild(let requested, let name):
                let parent = try resolve(requested, in: updated)
                try ProjectFolderTree.validatePath(name)
                let path = parent + "/" + name
                guard !updated.contains(path) else { throw OrganizerError("이미 있는 폴더입니다: \(path)") }
                updated.append(path)
                message = "미리보기의 ‘\(parent)’ 아래에 ‘\(name)’ 폴더를 추가했습니다."
            case .remove(let requested):
                let path = try resolve(requested, in: updated)
                updated.removeAll { $0 == path || $0.hasPrefix(path + "/") }
                message = "미리보기에서 ‘\(path)’와 그 아래 폴더를 제외했습니다. 실제 폴더는 삭제하지 않았습니다."
            case .rename(let requested, let replacement):
                let path = try resolve(requested, in: updated)
                try ProjectFolderTree.validatePath(replacement)
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                let target = replacement.contains("/") || parent.isEmpty ? replacement : parent + "/" + replacement
                try ProjectFolderTree.validatePath(target)
                guard target != path else { throw OrganizerError("기존 이름과 같습니다.") }
                guard !target.hasPrefix(path + "/") else { throw OrganizerError("폴더를 자기 하위 경로로 옮길 수 없습니다.") }
                updated = updated.map { value in
                    if value == path { return target }
                    return value.hasPrefix(path + "/") ? target + String(value.dropFirst(path.count)) : value
                }
                message = "미리보기에서 ‘\(path)’를 ‘\(target)’로 변경했습니다."
            case .split(let requested, let names):
                let path = try resolve(requested, in: updated)
                guard (2...12).contains(names.count) else { throw OrganizerError("나눌 하위 폴더는 2개부터 12개까지 적어 주세요.") }
                for name in names { try ProjectFolderTree.validateName(name) }
                updated.append(contentsOf: names.map { path + "/" + $0 })
                message = "미리보기의 ‘\(path)’ 아래에 \(names.joined(separator: "·")) 폴더를 만들었습니다."
            }
            updated = try ProjectFolderTree.normalized(updated)
            return .init(folders: updated, applied: true, message: message)
        } catch {
            return .init(folders: folders, applied: false, message: error.localizedDescription)
        }
    }

    private static func resolve(_ requested: String, in folders: [String]) throws -> String {
        try ProjectFolderTree.validatePath(requested)
        if folders.contains(requested) { return requested }
        // Leaf shorthand is accepted only if there is exactly one such branch.
        let matches = folders.filter { $0.split(separator: "/").last.map(String.init) == requested }
        guard matches.count == 1 else {
            if matches.isEmpty { throw OrganizerError("미리보기에 없는 폴더입니다: \(requested)") }
            throw OrganizerError("같은 이름이 여러 곳에 있습니다. 전체 상대 경로를 적어 주세요: \(requested)")
        }
        return matches[0]
    }

    private static func parse(_ command: String) -> FolderTreeEdit? {
        let polite = "(?:해\\s*줘|해주세요|해\\s*주세요|줘|주세요)?[.!]?"
        if let c = captures("^split\\s+(?:folder\\s+)?(.+?)\\s+into\\s+(.+?)[.!]?$", command) {
            return .split(path: clean(c[0]), into: splitNames(c[1]))
        }
        if let c = captures("^(.+?)(?:\\s*폴더)?(?:을|를)\\s+(.+?)(?:으로|로)\\s*(?:나눠|나누어|분리)" + polite + "$", command) {
            return .split(path: clean(c[0]), into: splitNames(c[1]))
        }
        if let c = captures("^rename\\s+(?:folder\\s+)?(.+?)\\s+to\\s+(.+?)[.!]?$", command) {
            return .rename(path: clean(c[0]), to: clean(c[1]))
        }
        if let c = captures("^(.+?)(?:\\s*폴더)?(?:을|를)\\s+(.+?)(?:으로|로)\\s*(?:이름\\s*(?:변경|바꿔)|변경)" + polite + "$", command) {
            return .rename(path: clean(c[0]), to: clean(c[1]))
        }
        if let c = captures("^(?:remove|delete)\\s+(?:folder\\s+)?(.+?)[.!]?$", command) {
            return .remove(path: clean(c[0]))
        }
        if let c = captures("^(.+?)(?:\\s*폴더)?(?:을|를)?\\s+(?:삭제|제거)" + polite + "$", command) {
            return .remove(path: clean(c[0]))
        }
        if let c = captures("^add\\s+(?:folder\\s+)?(.+?)[.!]?$", command) {
            return .add(path: clean(c[0]))
        }
        if let c = captures("^(.+?)(?:\\s*폴더)?(?:\\s*아래에|에)\\s+(.+?)\\s*폴더(?:을|를)?\\s*(?:추가|만들어)" + polite + "$", command) {
            return .addChild(parent: clean(c[0]), name: clean(c[1]))
        }
        if let c = captures("^(.+?)\\s*폴더(?:을|를)?\\s*(?:추가|만들어)" + polite + "$", command) {
            return .add(path: clean(c[0]))
        }
        return nil
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
    private static func clean(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("‘", "’"), ("“", "”")]
        if name.count >= 2, pairs.contains(where: { name.first == $0.0 && name.last == $0.1 }) {
            return String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name
    }
    private static func splitNames(_ names: String) -> [String] {
        guard let separator = try? NSRegularExpression(pattern: "\\s*(?:,|(?:와|과)\\s+|\\s+및\\s+|\\s+and\\s+|\\s+&\\s+)\\s*", options: [.caseInsensitive]) else { return [] }
        let marked = separator.stringByReplacingMatches(in: names, range: NSRange(names.startIndex..., in: names), withTemplate: "\n")
        return marked.components(separatedBy: "\n").map(clean)
    }
}
