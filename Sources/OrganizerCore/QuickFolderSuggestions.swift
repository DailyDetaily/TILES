import Foundation
import Darwin

/// An explicit user choice used only to suggest a folder, never to move automatically.
public struct FolderSuggestionRule: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var prefix: String
    public var folderPath: String
    public init(prefix: String, folderPath: String) {
        self.id = UUID(); self.prefix = prefix; self.folderPath = folderPath
    }
}

public enum QuickFolderSuggestions {
    /// A bounded list of known paths; this does not crawl the user's folders.
    public static func recommendations(source: URL, catalogue: [FolderDestination], rules: OrganizerRules,
                                       remembered: [FolderSuggestionRule], commonFolders: [URL]) throws -> [FolderRecommendation] {
        let sourceIdentity = try ExistingFileDrop.inspect(source)
        let parentIdentity = try SafeFileSystem.identity(at: source.deletingLastPathComponent())
        var candidates: [(FolderRecommendation, Int)] = []
        for rule in remembered where OrganizerRules.hasPrefix(source.lastPathComponent, rule.prefix) {
            if let folder = destination(URL(fileURLWithPath: rule.folderPath), rules: rules) {
                candidates.append((.init(destination: folder, reason: "이름이 ‘\(rule.prefix)’로 시작"), 0))
            }
        }
        for item in FolderRecommendations.cachedRecommendations(source: source, catalogue: catalogue, rules: rules) {
            let reason = item.reason.hasPrefix("이름 규칙") ? "이름 규칙 일치" : item.destination.lastUsed != nil ? "최근 사용" : "연결한 폴더"
            candidates.append((.init(destination: item.destination, reason: reason), item.destination.category == Planner.categoryFor(source.lastPathComponent, rules: rules) && item.destination.category != nil ? 1 : 2))
        }
        for url in commonFolders {
            if let folder = destination(url, rules: rules) {
                candidates.append((.init(destination: folder, reason: "Mac의 기본 폴더"), 3))
            }
        }
        candidates.sort {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let a = $0.0.destination.lastUsed ?? .distantPast, b = $1.0.destination.lastUsed ?? .distantPast
            return a == b ? $0.0.id < $1.0.id : a > b
        }
        var seen = Set<String>()
        return candidates.compactMap { item -> FolderRecommendation? in
            let folder = item.0.destination
            guard folder.identity != parentIdentity, folder.identity.device == sourceIdentity.device,
                  let current = destination(URL(fileURLWithPath: folder.path), rules: rules), current.identity == folder.identity,
                  seen.insert("\(folder.identity.device):\(folder.identity.inode)").inserted else { return nil }
            return item.0
        }.prefix(3).map { $0 }
    }

    public static func destination(_ url: URL, rules: OrganizerRules) -> FolderDestination? {
        guard let canonical = try? PathSafety.canonicalRoot(url),
              (try? SafeFileSystem.validateDirectory(canonical)) != nil,
              (try? Planner.validateDestination(canonical, rules: rules)) != nil,
              access(canonical.path, R_OK | W_OK | X_OK) == 0,
              let identity = try? SafeFileSystem.identity(at: canonical), identity.kind == "directory" else { return nil }
        return .init(path: canonical.path, identity: identity)
    }
}
