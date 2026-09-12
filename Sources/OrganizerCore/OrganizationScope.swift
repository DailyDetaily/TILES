import Foundation
import Darwin

public enum OrganizationScopeMode: String, CaseIterable, Sendable {
    case files, folders, all

    public var title: String {
        switch self {
        case .files: return "파일"
        case .folders: return "선택 폴더"
        case .all: return "전체"
        }
    }
}

/// Metadata discovery only. Candidate URLs are bounded; totalCandidates includes overflow.
public struct OrganizationScopeResult: Sendable {
    public var files: [URL] = []
    public var totalCandidates = 0
    public var skippedCount = 0
    public var preservedFolderCount = 0
    public var unreadableCount = 0
    public var examinedCount = 0
    public var scanLimitReached = false
    public var warnings: [String] = []
    public var overflowCount: Int { max(0, totalCandidates - files.count) }
    public init() {}
}

public enum OrganizationScopeDiscovery {
    public static let batchLimit = 500

    /// Source folders stay in place. Recursion includes eligible files only, and never follows links,
    /// packages, hidden items, protected paths or code project directories.
    public static func scan(files: [URL], folders: [URL], includeSubfolders: Bool = false,
                            rules: OrganizerRules, cancelled: () -> Bool = { false }) throws -> OrganizationScopeResult {
        try rules.validate()
        var result = OrganizationScopeResult()
        var visitedPaths = Set<String>()
        var fileIdentities = Set<String>()
        var ancestorSafety: [String: Bool] = [:]
        let keys: Set<URLResourceKey> = [.isAliasFileKey, .isPackageKey, .isHiddenKey, .volumeIsLocalKey]

        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        func warning(_ text: String) { if result.warnings.count < 8 { result.warnings.append(text) } }
        func safeAncestors(_ parent: URL) throws -> Bool {
            if let cached = ancestorSafety[parent.path] { return cached }
            var ancestor = parent
            var safe = true
            while ancestor.pathComponents.count >= 3 {
                try checkCancellation()
                if let cached = ancestorSafety[ancestor.path] { safe = cached; break }
                if try SafeFileSystem.protectionReason(ancestor, rules: rules, includeDescendantPaths: false) != nil {
                    safe = false; break
                }
                ancestor.deleteLastPathComponent()
            }
            ancestorSafety[parent.path] = safe
            return safe
        }
        func visit(_ original: URL, rootFolder: Bool = false) throws {
            try checkCancellation()
            guard original.isFileURL, original.host == nil || original.host == "" || original.host == "localhost",
                  original.query == nil, original.fragment == nil else { result.skippedCount += 1; return }
            let url = PathSafety.lexicalURL(original)
            guard visitedPaths.insert(url.path.precomposedStringWithCanonicalMapping).inserted else { return }
            guard result.examinedCount < rules.maximumSnapshotEntries else { result.scanLimitReached = true; return }
            result.examinedCount += 1
            do {
                let info = try SafeFileSystem.info(url)
                let identity = SafeFileSystem.identity(info)
                let isFolder = identity.kind == "directory"
                if isFolder && !rootFolder { result.preservedFolderCount += 1 }
                guard !FolderWatchPolicy.excludes(name: url.lastPathComponent),
                      info.st_flags & UInt32(UF_HIDDEN | SF_DATALESS) == 0,
                      try SafeFileSystem.protectionReason(url, rules: rules, includeDescendantPaths: false) == nil else {
                    result.skippedCount += 1; return
                }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isAliasFile != true, values.isPackage != true, values.isHidden != true,
                      values.volumeIsLocal == true else { result.skippedCount += 1; return }
                if isFolder {
                    guard rootFolder || includeSubfolders else { return }
                    try SafeFileSystem.validateDirectory(url)
                    guard try safeAncestors(url.deletingLastPathComponent()) else { result.skippedCount += 1; return }
                    let initialIdentity = identity
                    let children = try SafeFileSystem.children(url)
                    for child in children {
                        if result.scanLimitReached { break }
                        try visit(child)
                    }
                    guard try SafeFileSystem.identity(at: url) == initialIdentity else {
                        throw OrganizerError("확인하는 동안 폴더가 바뀌었습니다. 다시 선택해 주세요.")
                    }
                } else if identity.kind == "file", !rootFolder {
                    guard try safeAncestors(url.deletingLastPathComponent()) else { result.skippedCount += 1; return }
                    let inspected = try ExistingFileDrop.inspect(url)
                    guard fileIdentities.insert("\(inspected.device):\(inspected.inode)").inserted else { return }
                    result.totalCandidates += 1
                    if result.files.count < batchLimit { result.files.append(url) }
                } else { result.skippedCount += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.skippedCount += 1; result.unreadableCount += 1
                warning("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Normalize aliases in system prefixes (such as /var) only after rejecting source links.
        for file in files.sorted(by: { $0.path < $1.path }) {
            if result.scanLimitReached { break }
            try visit(file)
        }
        for folder in folders.sorted(by: { $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count }) {
            if result.scanLimitReached { break }
            // A nested root intentionally selected by the user must still be scanned when recursion is off.
            let key = PathSafety.lexicalURL(folder).path.precomposedStringWithCanonicalMapping
            if !includeSubfolders { visitedPaths.remove(key) }
            try visit(folder, rootFolder: true)
        }
        try checkCancellation()
        result.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }
}

public struct OrganizationScopeConnection: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?
    public var identity: FileIdentity
    public init(path: String, bookmark: Data?, identity: FileIdentity) {
        self.path = path; self.bookmark = bookmark; self.identity = identity
    }
}

public struct OrganizationScopeState: Codable, Equatable, Sendable {
    public var version = 1
    public var connections: [OrganizationScopeConnection] = []
    public init(connections: [OrganizationScopeConnection] = []) { self.connections = connections }
    public func validate() throws {
        guard version == 1, connections.count <= 100 else { throw OrganizerError("정리 범위 기록의 버전이나 위치 수가 올바르지 않습니다.") }
        var paths = Set<String>()
        for connection in connections {
            guard connection.path.hasPrefix("/"), !connection.path.utf8.contains(0),
                  PathSafety.lexicalURL(URL(fileURLWithPath: connection.path)).path == connection.path,
                  connection.identity.kind == "directory", connection.bookmark?.isEmpty != true,
                  paths.insert(connection.path.precomposedStringWithCanonicalMapping).inserted else {
                throw OrganizerError("정리 범위에 올바르지 않은 폴더 정보가 있습니다.")
            }
        }
    }
}

/// A separate source-connection record. Corruption and external edits block writes rather than
/// replacing a previously saved connection list with empty defaults.
public final class OrganizationScopeStateStore {
    private let url: URL
    private var expectedBytes: Data?
    private var loaded = false
    private var blocked = false
    private let maximumBytes = 2 * 1_048_576
    public init(url: URL) { self.url = url }
    public func load() throws -> OrganizationScopeState {
        do {
            let bytes = try existingBytes()
            let value = try bytes.map { try JSONDecoder().decode(OrganizationScopeState.self, from: $0) } ?? .init()
            try value.validate(); expectedBytes = bytes; loaded = true
            return value
        } catch { blocked = true; throw OrganizerError("ScopeState.json을 읽을 수 없어 기존 기록을 유지합니다. \(error.localizedDescription)") }
    }
    public func save(_ value: OrganizationScopeState) throws {
        guard loaded, !blocked else { throw OrganizerError("정리 범위 기록을 읽을 수 없어 저장하지 않았습니다.") }
        do {
            try value.validate()
            guard try existingBytes() == expectedBytes else { throw OrganizerError("정리 범위 기록이 외부에서 바뀌어 기존 파일을 유지합니다.") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(value)
            guard bytes.count <= maximumBytes else { throw OrganizerError("정리 범위 기록이 너무 큽니다.") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic); expectedBytes = bytes
        } catch { blocked = true; throw error }
    }
    private func existingBytes() throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_flags & UInt32(SF_DATALESS) == 0,
              info.st_size <= maximumBytes else { throw OrganizerError("정리 범위 기록이 읽을 수 있는 일반 파일이 아닙니다.") }
        try SafeFileSystem.validateDirectory(url.deletingLastPathComponent())
        return try Data(contentsOf: url)
    }
}
