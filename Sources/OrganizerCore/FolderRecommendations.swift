import Foundation
import Darwin

public struct FolderDestination: Sendable, Codable, Equatable {
    public var path: String
    public var identity: FileIdentity
    public var category: String?
    public var lastUsed: Date?
    public var isRegisteredRoot: Bool
    public init(path: String, identity: FileIdentity, category: String? = nil,
                lastUsed: Date? = nil, isRegisteredRoot: Bool = false) {
        self.path = path; self.identity = identity; self.category = category
        self.lastUsed = lastUsed; self.isRegisteredRoot = isRegisteredRoot
    }
}

public struct FolderRecommendation: Sendable, Codable, Equatable, Identifiable {
    public var destination: FolderDestination
    public var reason: String
    public var id: String { destination.path }
    public var name: String { URL(fileURLWithPath: id).lastPathComponent }
    public init(destination: FolderDestination, reason: String) {
        self.destination = destination; self.reason = reason
    }
}

/// Adapts the existing name policy and committed journal; it does not classify file contents.
public enum FolderRecommendations {
    /// Called off the main thread while idle. Only registered-root, configured category and journal paths are inspected.
    public static func catalogue(root: URL, rules: OrganizerRules, records: [RunRecord]) throws -> [FolderDestination] {
        try rules.validate()
        let root = try PathSafety.canonicalRoot(root)
        try SafeFileSystem.validateDirectory(root)
        try Planner.validateDestination(root, rules: rules)
        var recent: [String: Date] = [:]
        for record in records where record.state == .completed {
            for entry in record.entries where entry.state == .moved {
                let parent = URL(fileURLWithPath: entry.destination).deletingLastPathComponent()
                if PathSafety.contains(root, parent) {
                    recent[parent.path] = max(recent[parent.path] ?? .distantPast, record.updatedAt)
                }
            }
        }
        let categories = Dictionary(uniqueKeysWithValues: rules.categories.map { (root.appendingPathComponent($0).path, $0) })
        let recentPaths = recent.keys.sorted {
            recent[$0] == recent[$1] ? $0 < $1 : recent[$0]! > recent[$1]!
        }.prefix(24)
        let paths = Set([root.path] + Array(categories.keys) + Array(recentPaths))
        return paths.sorted().compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard PathSafety.contains(root, url),
                  (try? SafeFileSystem.validateDirectory(url)) != nil,
                  (try? Planner.validateDestination(url, rules: rules)) != nil,
                  access(path, R_OK | W_OK | X_OK) == 0,
                  let identity = try? SafeFileSystem.identity(at: url), identity.kind == "directory" else { return nil }
            return FolderDestination(path: path, identity: identity, category: categories[path],
                                     lastUsed: recent[path], isRegisteredRoot: path == root.path)
        }
    }

    /// Metadata-only, bounded by the cached catalogue. No enumeration, hashing, OCR or network request.
    public static func recommendations(source: URL, catalogue: [FolderDestination], rules: OrganizerRules) throws -> [FolderRecommendation] {
        let identity = try ExistingFileDrop.inspect(source)
        let parentIdentity = try SafeFileSystem.identity(at: source.deletingLastPathComponent())
        let current = catalogue.filter { folder in
            let url = URL(fileURLWithPath: folder.path)
            return folder.identity != parentIdentity && identity.device == folder.identity.device &&
                (try? SafeFileSystem.validateDirectory(url)) != nil &&
                (try? SafeFileSystem.identity(at: url)) == folder.identity && access(folder.path, R_OK | W_OK | X_OK) == 0
        }
        return cachedRecommendations(source: source, catalogue: current, rules: rules)
    }

    /// The native gesture uses only this pure path/name lookup. Even a metadata syscall can trigger TCC UI.
    /// Existence, identities, local-file support and permissions are rechecked after the drag ends.
    public static func cachedRecommendations(source: URL, catalogue: [FolderDestination], rules: OrganizerRules) -> [FolderRecommendation] {
        let category = Planner.categoryFor(source.lastPathComponent, rules: rules)
        let parent = PathSafety.lexicalURL(source.deletingLastPathComponent()).path.precomposedStringWithCanonicalMapping.lowercased()
        var eligible: [(FolderRecommendation, Int)] = []
        for folder in catalogue {
            guard folder.path.precomposedStringWithCanonicalMapping.lowercased() != parent else { continue }
            let reason: String, rank: Int
            if let category, folder.category == category {
                reason = "이름 규칙 일치 · \(category)"; rank = 0
            } else if folder.lastUsed != nil {
                reason = "최근 사용 · 완료된 이동 기록"; rank = 1
            } else if folder.isRegisteredRoot {
                reason = "고정 · 연결한 정리 위치"; rank = 2
            } else { continue }
            eligible.append((.init(destination: folder, reason: reason), rank))
        }
        eligible.sort {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let a = $0.0.destination.lastUsed ?? .distantPast, b = $1.0.destination.lastUsed ?? .distantPast
            return a == b ? $0.0.id < $1.0.id : a > b
        }
        var paths = Set<String>(), identities = Set<String>()
        return eligible.compactMap { item -> FolderRecommendation? in
            let folder = item.0.destination
            guard paths.insert(folder.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  identities.insert("\(folder.identity.device):\(folder.identity.inode)").inserted else { return nil }
            return item.0
        }.prefix(3).map { $0 }
    }
}

public enum ExistingFileDrop {
    public static let maximumBatchCount = 500

    /// Pure drag-time validation. File kind, identity, protection and permissions are checked after drop.
    /// Keep the original AppKit URLs so their security-scope extensions remain available.
    public static func validateInputs(urls: [URL], itemCount: Int, hasFilePromise: Bool, allowsMove: Bool) throws -> [URL] {
        try validateInputs(urls: urls, itemCount: itemCount, hasFilePromise: hasFilePromise, allowsFileHandoff: allowsMove)
    }

    /// A native generic handoff or copy for review is valid; the selected target checks its own operation.
    public static func validateInputs(urls: [URL], itemCount: Int, hasFilePromise: Bool, allowsFileHandoff: Bool) throws -> [URL] {
        guard !hasFilePromise else { throw OrganizerError("아직 만들어지지 않은 파일은 받지 않습니다. Finder에 저장한 뒤 끌어오세요.") }
        guard !urls.isEmpty, urls.count <= maximumBatchCount, itemCount == urls.count else {
            throw OrganizerError("로컬 일반 파일을 1개부터 \(maximumBatchCount)개까지 선택해 주세요.")
        }
        guard allowsFileHandoff else { throw OrganizerError("원본 앱이 파일 전달을 허용하지 않습니다. Finder에서 파일을 다시 끌어오세요.") }
        var paths = Set<String>()
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
                throw OrganizerError("웹 주소 대신 이 Mac에 저장된 일반 파일을 끌어오세요.")
            }
            let path = PathSafety.lexicalURL(url).path
            guard paths.insert(path).inserted else { throw OrganizerError("같은 파일이 중복 선택됐습니다. 파일을 다시 선택해 주세요.") }
        }
        return urls
    }

    public static func validateInput(urls: [URL], itemCount: Int, hasFilePromise: Bool, allowsMove: Bool) throws -> URL {
        guard !hasFilePromise else { throw OrganizerError("아직 만들어지지 않은 파일은 받지 않습니다. Finder에 저장한 뒤 파일 1개를 옮겨 주세요.") }
        guard itemCount == 1, urls.count == 1 else { throw OrganizerError("상단 정리는 일반 파일 1개씩 지원합니다.") }
        let url = urls[0]
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { throw OrganizerError("웹 주소 대신 로컬 파일 1개를 옮겨 주세요.") }
        guard allowsMove else { throw OrganizerError("원본 앱이 이동을 허용하지 않습니다. 복사 전용 드래그는 받지 않습니다.") }
        // Preserve the URL object supplied by AppKit and its possible security-scope extension.
        return url
    }

    public static func inspect(_ url: URL) throws -> FileIdentity {
        guard url.isFileURL else { throw OrganizerError("로컬 일반 파일만 지원합니다.") }
        let info = try SafeFileSystem.info(url), identity = SafeFileSystem.identity(info)
        guard identity.kind == "file" else { throw OrganizerError("일반 파일을 선택해 주세요. 폴더는 ‘폴더 전체 정리’에서 확인할 수 있습니다.") }
        // Avoid materializing a File Provider placeholder, even if it is not an iCloud ubiquitous item.
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw OrganizerError("먼저 파일을 이 Mac에 다운로드해 주세요.") }
        let values = try url.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey, .isUbiquitousItemKey,
                                                     .ubiquitousItemDownloadingStatusKey, .volumeIsLocalKey])
        guard values.isAliasFile != true, values.isPackage != true else { throw OrganizerError("별칭이나 앱 묶음 대신 일반 파일을 선택해 주세요.") }
        guard values.volumeIsLocal == true else { throw OrganizerError("이 Mac의 로컬 디스크 안에서만 이동할 수 있습니다.") }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            throw OrganizerError("먼저 파일을 이 Mac에 다운로드해 주세요.")
        }
        try SafeFileSystem.validateDirectory(url.deletingLastPathComponent())
        guard access(url.path, R_OK) == 0 else { throw SafeFileSystem.systemError("원본 파일을 읽을 수 없습니다", url.path) }
        return identity
    }
}

extension Planner {
    /// Thin post-drop adapter to the same execute, reference checks, journal and undo engine.
    /// The dragged file supplies its original parent. Connected roots retain their existing reference-check scope.
    public static func singleFilePlan(source: URL, folder: FolderDestination, registeredRoot: URL,
                                      authorizedSources: [URL] = [], rules: OrganizerRules,
                                      expectedSourceIdentity: FileIdentity? = nil) throws -> ScanPlan {
        try rules.validate()
        let source = PathSafety.lexicalURL(source)
        let identity = try ExistingFileDrop.inspect(source)
        if let expectedSourceIdentity, identity != expectedSourceIdentity { throw OrganizerError("드래그한 원본이 다른 파일로 바뀌었습니다. 이동하지 않았습니다.") }
        let target = URL(fileURLWithPath: folder.path)
        let root = try PathSafety.canonicalRoot(registeredRoot)
        guard PathSafety.contains(root, target) else {
            throw OrganizerError("선택한 폴더가 연결한 정리 위치 밖에 있습니다.")
        }
        let parent = source.deletingLastPathComponent()
        let connectedRoot = authorizedSources.filter { PathSafety.contains($0, source) && $0.path != source.path }
            .sorted { $0.path.count > $1.path.count }.first
        let sourceRoot = try PathSafety.canonicalRoot(connectedRoot ?? parent)
        try SafeFileSystem.validateDirectory(sourceRoot)
        try SafeFileSystem.validateDirectory(target)
        guard try SafeFileSystem.identity(at: target) == folder.identity else { throw OrganizerError("선택한 폴더가 사라졌거나 바뀌었습니다.") }
        guard source.deletingLastPathComponent().path != target.path else { throw OrganizerError("이미 같은 폴더에 있는 파일입니다.") }
        guard identity.device == folder.identity.device else { throw OrganizerError("첫 버전은 같은 디스크 안의 이동만 지원합니다.") }
        guard access(parent.path, W_OK | X_OK) == 0 else {
            throw SafeFileSystem.systemError("원본 폴더에서 파일을 이동할 수 없습니다", parent.path)
        }
        guard FileManager.default.isDeletableFile(atPath: source.path) else {
            throw OrganizerError("원본을 이동할 수 없습니다. 파일 잠금과 폴더 권한을 확인해 주세요.")
        }
        guard access(target.path, W_OK | X_OK) == 0 else { throw SafeFileSystem.systemError("목적지 폴더에 쓸 수 없습니다", target.path) }
        var ancestor = parent
        // An automatically inferred parent must not bypass enclosing project/package protections.
        while ancestor.pathComponents.count >= 3 {
            if let reason = try SafeFileSystem.protectionReason(ancestor, rules: rules, includeDescendantPaths: false) { throw OrganizerError(reason) }
            ancestor.deleteLastPathComponent()
        }
        try validateDestination(target, rules: rules)
        try PathSafety.validateComponent(source.lastPathComponent)
        let destination = target.appendingPathComponent(source.lastPathComponent)
        guard !SafeFileSystem.exists(destination) else { throw OrganizerError("같은 이름의 항목이 이미 있습니다. 이동하지 않았습니다.") }
        let snapshot = try SafeFileSystem.snapshot(source, rules: rules)
        let proposal = Proposal(source: source.path, destination: destination.path, decision: .move,
                                reason: "직접 선택한 폴더", isDirectory: false, category: folder.category, snapshot: snapshot)
        return ScanPlan(sourceRoots: [sourceRoot.path], sourceRootIdentities: [sourceRoot.path: try SafeFileSystem.identity(at: sourceRoot)],
                        destinationRoot: root.path, destinationAnchor: root.path, destinationAnchorIdentity: try SafeFileSystem.identity(at: root),
                        proposals: [proposal], warnings: [], referenceFilesChecked: 0, rules: rules,
                        destinationParentIdentities: [target.path: folder.identity])
    }
}
