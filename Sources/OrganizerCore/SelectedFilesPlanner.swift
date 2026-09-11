import Foundation
import Darwin

public struct SelectedFileDestination: Sendable {
    public var source: URL
    public var folder: URL
    public var expectedSourceIdentity: FileIdentity?

    public init(source: URL, folder: URL, expectedSourceIdentity: FileIdentity? = nil) {
        self.source = source; self.folder = folder; self.expectedSourceIdentity = expectedSourceIdentity
    }
}

/// Plans only the supplied files. Preview never creates a folder or changes a file.
public enum SelectedFilesPlanner {
    public static func plan(assignments: [SelectedFileDestination], destinationRoot: URL,
                            registeredRoot: URL? = nil, authorizedSources: [URL] = [], rules: OrganizerRules,
                            requiredDirectories: [URL] = [], cancelled: () -> Bool = { false },
                            progress: (EngineProgress) -> Void = { _ in }) throws -> ScanPlan {
        try rules.validate()
        guard assignments.count <= 500, !assignments.isEmpty || !requiredDirectories.isEmpty else {
            throw OrganizerError("옮길 파일이나 만들 폴더를 선택해 주세요. 파일은 한 번에 최대 500개까지 지원합니다.")
        }
        try validateLocalURL(destinationRoot)
        let root = try PathSafety.canonicalRoot(destinationRoot)
        try SafeFileSystem.validateDirectory(root)
        try Planner.validateDestination(root, rules: rules)
        if let registeredRoot {
            try validateLocalURL(registeredRoot)
            let registered = try PathSafety.canonicalRoot(registeredRoot)
            guard PathSafety.contains(registered, root) else { throw OrganizerError("선택한 폴더가 연결한 정리 위치 밖에 있습니다.") }
        }
        let rootIdentity = try SafeFileSystem.identity(at: root)
        guard try root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw OrganizerError("이 Mac의 로컬 디스크 안에서만 폴더를 만들거나 이동할 수 있습니다.")
        }
        let authorized = try authorizedSources.map { try PathSafety.canonicalRoot($0) }
        var roots: [URL] = [], proposals: [Proposal] = [], sources = Set<String>(), destinations = Set<String>()
        var fileIdentities = Set<String>()
        var sourceParents: [String: FileIdentity] = [:]
        var folders: [URL] = []
        for (index, assignment) in assignments.enumerated() {
            if cancelled() { throw CancellationError() }
            try validateLocalURL(assignment.source); try validateLocalURL(assignment.folder)
            let source = PathSafety.lexicalURL(assignment.source)
            let folder = PathSafety.lexicalURL(assignment.folder)
            progress(.init(index, assignments.count, "선택한 파일 확인 · \(source.lastPathComponent)"))
            let identity = try ExistingFileDrop.inspect(source)
            if let expected = assignment.expectedSourceIdentity, expected != identity {
                throw OrganizerError("선택한 원본이 다른 파일로 바뀌었습니다. 이동하지 않았습니다.")
            }
            guard sources.insert(key(source.path)).inserted,
                  fileIdentities.insert("\(identity.device):\(identity.inode)").inserted else {
                throw OrganizerError("같은 원본 파일을 여러 번 옮길 수 없습니다.")
            }
            guard PathSafety.contains(root, folder), folder.path != source.deletingLastPathComponent().path else {
                throw OrganizerError("목적지는 정리 위치 안의 다른 폴더여야 합니다.")
            }
            let parent = source.deletingLastPathComponent()
            let connected = authorized.filter { PathSafety.contains($0, source) && $0.path != source.path }
                .sorted { $0.path.count > $1.path.count }.first
            let sourceRoot = try PathSafety.canonicalRoot(connected ?? parent)
            try SafeFileSystem.validateDirectory(sourceRoot)
            sourceParents[parent.path] = try SafeFileSystem.identity(at: parent)
            guard access(parent.path, W_OK | X_OK) == 0 else {
                throw SafeFileSystem.systemError("원본 폴더에서 파일을 이동할 수 없습니다", parent.path)
            }
            guard FileManager.default.isDeletableFile(atPath: source.path) else {
                throw OrganizerError("원본을 이동할 수 없습니다. 파일 잠금과 폴더 권한을 확인해 주세요.")
            }
            try validateSourceAncestors(parent, rules: rules)
            try PathSafety.validateComponent(source.lastPathComponent)
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            guard destinations.insert(key(destination.path)).inserted, !SafeFileSystem.exists(destination) else {
                throw OrganizerError("같은 이름의 목적지가 겹치거나 이미 있습니다. 덮어쓰지 않습니다.")
            }
            guard identity.device == rootIdentity.device else { throw OrganizerError("첫 버전은 같은 디스크 안의 이동만 지원합니다.") }
            let snapshot = try SafeFileSystem.snapshot(source, rules: rules, cancelled: cancelled)
            guard snapshot.rootIdentity == identity else { throw OrganizerError("확인 중 원본이 바뀌었습니다. 다시 분석해 주세요.") }
            proposals.append(.init(source: source.path, destination: destination.path, decision: .move,
                                   reason: "직접 선택한 폴더", isDirectory: false, snapshot: snapshot))
            roots.append(sourceRoot); folders.append(folder)
        }
        let explicit = try requiredDirectories.map { url -> URL in
            try validateLocalURL(url)
            return PathSafety.lexicalURL(url)
        }
        let directories = try directoryPlan(folders: folders + explicit, explicit: explicit, root: root,
                                            rootIdentity: rootIdentity, rules: rules, cancelled: cancelled)
        for proposal in proposals {
            let source = URL(fileURLWithPath: proposal.source), destination = URL(fileURLWithPath: proposal.destination!)
            guard !directories.paths.contains(source.path),
                  !proposals.contains(where: { other in
                      other.id != proposal.id && (PathSafety.contains(source, URL(fileURLWithPath: other.destination!)) ||
                      PathSafety.contains(destination, URL(fileURLWithPath: other.source)) ||
                      PathSafety.contains(destination, URL(fileURLWithPath: other.destination!)))
                  }) else { throw OrganizerError("원본과 목적지 경로가 서로 겹칩니다.") }
        }
        let sourceRoots = try PathSafety.nonOverlappingRoots(roots)
        var rootIdentities: [String: FileIdentity] = [:]
        for sourceRoot in sourceRoots { rootIdentities[sourceRoot.path] = try SafeFileSystem.identity(at: sourceRoot) }
        progress(.init(assignments.count, assignments.count, "선택한 원본 폴더의 코드·문서 참조 확인"))
        let references = Planner.collectReferences(roots: sourceRoots, rules: rules, cancelled: cancelled)
        if cancelled() { throw CancellationError() }
        guard references.complete else { throw OrganizerError("코드·문서 참조 확인을 끝내지 못했습니다. 원본 폴더 범위를 줄여 주세요.") }
        for proposal in proposals {
            if let reference = references.reference(to: URL(fileURLWithPath: proposal.source)) {
                throw OrganizerError("\(proposal.name)을 참조하는 \(reference.lastPathComponent)이 있습니다. 기존 경로를 유지합니다.")
            }
        }
        var result = ScanPlan(sourceRoots: sourceRoots.map(\.path), sourceRootIdentities: rootIdentities,
                              destinationRoot: root.path, destinationAnchor: root.path, destinationAnchorIdentity: rootIdentity,
                              proposals: proposals, warnings: references.warnings, referenceFilesChecked: references.documents.count, rules: rules)
        result.directoryCreationPlan = directories
        result.sourceParentIdentities = sourceParents
        return result
    }

    public static func folderTreePlan(directories: [URL], destinationRoot: URL, registeredRoot: URL? = nil,
                                      rules: OrganizerRules) throws -> ScanPlan {
        try plan(assignments: [], destinationRoot: destinationRoot, registeredRoot: registeredRoot,
                 rules: rules, requiredDirectories: directories)
    }

    static func validateSourceAncestors(_ parent: URL, rules: OrganizerRules) throws {
        var ancestor = parent
        while ancestor.pathComponents.count >= 3 {
            if let reason = try SafeFileSystem.protectionReason(ancestor, rules: rules, includeDescendantPaths: false) {
                throw OrganizerError(reason)
            }
            ancestor.deleteLastPathComponent()
        }
    }

    private static func directoryPlan(folders: [URL], explicit: [URL], root: URL, rootIdentity: FileIdentity,
                                      rules: OrganizerRules, cancelled: () -> Bool) throws -> DirectoryCreationPlan {
        guard folders.count <= 2_000 else { throw OrganizerError("폴더는 한 번에 최대 2,000개까지 만들 수 있습니다.") }
        var paths: [String: String] = [key(root.path): root.path]
        for folder in folders {
            guard PathSafety.contains(root, folder), folder.pathComponents.count - root.pathComponents.count <= 32 else {
                throw OrganizerError("만들 폴더가 정리 위치 밖에 있거나 너무 깊습니다.")
            }
            var cursor = root
            for component in folder.pathComponents.dropFirst(root.pathComponents.count) {
                try PathSafety.validateComponent(component)
                cursor.appendPathComponent(component, isDirectory: true)
                guard !OrganizerRules.managedNames.contains(component), !component.hasPrefix("DerivedData"),
                      !OrganizerRules.projectMarkers.contains(component), !OrganizerRules.packageExtensions.contains(cursor.pathExtension.lowercased()),
                      !rules.isProtectedPath(cursor) else { throw OrganizerError("앱·코드·보호 경로에 정리 폴더를 만들 수 없습니다.") }
                if let existing = paths[key(cursor.path)], existing != cursor.path {
                    throw OrganizerError("대소문자나 유니코드 표기만 다른 폴더가 겹칩니다.")
                }
                paths[key(cursor.path)] = cursor.path
                guard paths.count <= 2_001 else { throw OrganizerError("폴더는 한 번에 최대 2,000개까지 만들 수 있습니다.") }
            }
        }
        let ordered = paths.values.sorted { a, b in
            let ac = URL(fileURLWithPath: a).pathComponents.count, bc = URL(fileURLWithPath: b).pathComponents.count
            return ac == bc ? a < b : ac < bc
        }
        var existing: [String: FileIdentity] = [:]
        for path in ordered {
            if cancelled() { throw CancellationError() }
            let url = URL(fileURLWithPath: path)
            try Planner.validateDestination(url, rules: rules)
            if SafeFileSystem.exists(url) {
                try SafeFileSystem.validateDirectory(url)
                let identity = try SafeFileSystem.identity(at: url)
                guard identity.device == rootIdentity.device else { throw OrganizerError("첫 버전은 같은 디스크 안의 이동만 지원합니다.") }
                guard access(path, W_OK | X_OK) == 0 else { throw SafeFileSystem.systemError("목적지 폴더에 쓸 수 없습니다", path) }
                existing[path] = identity
            }
        }
        return .init(paths: ordered, existingIdentities: existing, explicitDirectories: Array(Set(explicit.map(\.path))).sorted())
    }

    private static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { throw OrganizerError("이 Mac의 로컬 파일·폴더 경로만 지원합니다.") }
    }

    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
}
