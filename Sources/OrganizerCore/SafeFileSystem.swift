import Foundation
import CryptoKit
import Darwin

public enum SafeFileSystem {
    private static let metadataNames: Set<String> = [".DS_Store", ".localized"]

    static func systemError(_ action: String, _ path: String) -> OrganizerError {
        let code = errno
        let reason = code == EACCES || code == EPERM
            ? "접근 권한이 부족합니다. 해당 파일이 있는 폴더를 연결하거나 폴더 권한을 확인해 주세요."
            : String(cString: strerror(code))
        return OrganizerError("\(action): \(URL(fileURLWithPath: path).lastPathComponent) — \(reason)")
    }

    public static func exists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }

    static func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw systemError("파일을 확인할 수 없습니다", url.path) }
        return value
    }

    static func identity(_ value: stat) -> FileIdentity {
        let mode = value.st_mode & mode_t(S_IFMT)
        let kind = mode == mode_t(S_IFDIR) ? "directory" : mode == mode_t(S_IFREG) ? "file" : "other"
        return .init(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino), kind: kind)
    }

    public static func identity(at url: URL) throws -> FileIdentity { identity(try info(url)) }

    public static func isDirectory(_ url: URL) throws -> Bool { try identity(at: url).kind == "directory" }

    static func isAlias(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true
    }

    /// Walk every component with O_NOFOLLOW; opening only the final component would still follow an ancestor link.
    static func withDirectoryFD<T>(_ url: URL, _ body: (Int32) throws -> T) throws -> T {
        let normalized = PathSafety.lexicalURL(url)
        let path = normalized.path
        guard path.hasPrefix("/") else { throw OrganizerError("절대 경로가 필요합니다.") }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError("폴더를 열 수 없습니다", path) }
        defer { close(descriptor) }
        for component in normalized.pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw systemError("폴더 경로가 바뀌었거나 접근할 수 없습니다", path) }
            close(descriptor); descriptor = next
        }
        return try body(descriptor)
    }

    public static func validateDirectory(_ url: URL) throws {
        try withDirectoryFD(url) { _ in () }
    }

    public static func nearestExistingDirectory(_ url: URL) throws -> URL {
        var result = PathSafety.lexicalURL(url)
        while !exists(result) {
            let parent = result.deletingLastPathComponent()
            guard parent.path != result.path else { throw OrganizerError("저장할 폴더의 상위 위치를 찾을 수 없습니다.") }
            result = parent
        }
        try validateDirectory(result)
        return result
    }

    public static func children(_ url: URL) throws -> [URL] {
        try validateDirectory(url)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isAliasFileKey], options: [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func protectionReason(_ url: URL, rules: OrganizerRules, includeDescendantPaths: Bool = true) throws -> String? {
        let value = try info(url)
        let kind = identity(value).kind
        if (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { return "심볼릭 링크는 따라가거나 이동하지 않습니다." }
        if kind == "other" { return "일반 파일·폴더가 아닌 항목입니다." }
        if try isAlias(url) { return "기존 바로가기는 원래 연결을 유지합니다." }
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return "숨김 항목입니다." }
        if rules.isProtectedPath(url) { return "규칙에서 원래 경로를 유지하도록 지정한 폴더입니다." }
        if OrganizerRules.managedNames.contains(name) || name.hasPrefix("DerivedData") {
            return "앱 또는 개발 도구가 관리하는 폴더입니다."
        }
        if OrganizerRules.packageExtensions.contains(url.pathExtension.lowercased()) { return "앱·프로젝트 묶음의 구조를 유지합니다." }
        if kind == "directory" {
            if includeDescendantPaths && rules.protectedPaths.contains(where: { PathSafety.contains(url, URL(fileURLWithPath: $0)) }) {
                return "원래 위치를 유지해야 하는 경로가 이 폴더 안에 있습니다."
            }
            // Protection only needs marker names; sorting every ancestor directory is unnecessary.
            try validateDirectory(url)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            if names.contains(where: {
                OrganizerRules.projectMarkers.contains($0) ||
                ["xcodeproj", "xcworkspace"].contains(($0 as NSString).pathExtension.lowercased())
            }) { return "코드 프로젝트입니다. 내부 구조와 경로를 유지합니다." }
        } else {
            if OrganizerRules.protectedFileExtensions.contains(url.pathExtension.lowercased()) {
                return "원본 영상·음성, 편집 프로젝트 또는 인증 자료는 원래 위치를 유지합니다."
            }
            if name.hasPrefix("~$") { return "문서 앱이 사용하는 임시·잠금 파일입니다." }
        }
        return nil
    }

    public static func snapshot(_ root: URL, rules: OrganizerRules, cancelled: () -> Bool = { false }) throws -> TreeSnapshot {
        var entries: [SnapshotEntry] = []
        var totalBytes: Int64 = 0
        func visit(_ url: URL, _ relative: String) throws {
            if cancelled() { throw CancellationError() }
            guard entries.count < rules.maximumSnapshotEntries else { throw OrganizerError("파일 수가 조사 한도를 넘습니다. 더 작은 자료 폴더를 선택해 주세요.") }
            if let reason = try protectionReason(url, rules: rules) { throw OrganizerError(reason) }
            let before = try info(url)
            let node = identity(before)
            guard node.kind == "file" || node.kind == "directory" else { throw OrganizerError("지원하지 않는 파일 형식입니다.") }
            if node.kind == "directory" {
                entries.append(.init(relativePath: relative, identity: node, bytes: 0, modifiedSeconds: 0, modifiedNanoseconds: 0, sha256: nil))
                for child in try children(url) {
                    if metadataNames.contains(child.lastPathComponent) { continue }
                    let suffix = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                    try visit(child, suffix)
                }
            } else {
                totalBytes += before.st_size
                guard totalBytes <= rules.maximumSnapshotBytes else { throw OrganizerError("자료 용량이 자동 검증 한도를 넘습니다. 더 작은 폴더로 나누어 선택해 주세요.") }
                let hash: String = try withDirectoryFD(url.deletingLastPathComponent()) { parent in
                    let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw systemError("파일을 읽을 수 없습니다", url.path) }
                    defer { close(descriptor) }
                    var opened = stat()
                    guard fstat(descriptor, &opened) == 0, identity(opened) == node else { throw OrganizerError("확인 중 파일이 바뀌었습니다. 다시 분석해 주세요.") }
                    var hasher = SHA256(); var buffer = [UInt8](repeating: 0, count: 1_048_576)
                    while true {
                        if cancelled() { throw CancellationError() }
                        let count = read(descriptor, &buffer, buffer.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw systemError("파일 읽기에 실패했습니다", url.path)
                        }
                        hasher.update(data: Data(buffer.prefix(count)))
                    }
                    var after = stat()
                    guard fstat(descriptor, &after) == 0, identity(after) == node,
                          after.st_size == before.st_size,
                          after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
                        throw OrganizerError("확인 중 파일이 수정되었습니다. 다시 분석해 주세요.")
                    }
                    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
                }
                entries.append(.init(relativePath: relative, identity: node, bytes: before.st_size,
                                     modifiedSeconds: Int64(before.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec), sha256: hash))
            }
        }
        try visit(root, "")
        return .init(entries: entries, totalBytes: totalBytes)
    }

    public static func createDirectory(_ url: URL, expectedParent: FileIdentity? = nil) throws -> CreatedDirectory {
        let parent = url.deletingLastPathComponent()
        return try withDirectoryFD(parent) { descriptor in
            if let expectedParent {
                var value = stat()
                guard fstat(descriptor, &value) == 0, identity(value) == expectedParent else {
                    throw OrganizerError("새 폴더를 만들 상위 위치가 바뀌었습니다.")
                }
            }
            guard mkdirat(descriptor, url.lastPathComponent, mode_t(0o755)) == 0 else { throw systemError("폴더를 만들 수 없습니다", url.path) }
            var value = stat()
            guard fstatat(descriptor, url.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  identity(value).kind == "directory" else { throw OrganizerError("새 폴더의 상태가 바뀌었습니다.") }
            return .init(path: url.path, identity: identity(value))
        }
    }

    static func validateMovePermissions(source: URL, destinationParent: URL) throws {
        let parent = source.deletingLastPathComponent()
        guard access(parent.path, W_OK | X_OK) == 0 else {
            throw systemError("원본 폴더에서 파일을 이동할 수 없습니다", parent.path)
        }
        guard FileManager.default.isDeletableFile(atPath: source.path) else {
            throw OrganizerError("원본을 이동할 수 없습니다. 파일 잠금과 폴더 권한을 확인해 주세요.")
        }
        let anchor = try nearestExistingDirectory(destinationParent)
        guard access(anchor.path, W_OK | X_OK) == 0 else {
            throw systemError("목적지 폴더에 쓸 수 없습니다", anchor.path)
        }
    }

    public static func moveExclusively(from source: URL, to destination: URL, expectedIdentity: FileIdentity,
                                      expectedDestinationParent: FileIdentity? = nil, expectedSourceParent: FileIdentity? = nil) throws {
        try withDirectoryFD(source.deletingLastPathComponent()) { fromFD in
            if let expectedSourceParent {
                var value = stat()
                guard fstat(fromFD, &value) == 0, identity(value) == expectedSourceParent else {
                    throw OrganizerError("원본 파일이 있던 상위 폴더가 바뀌었습니다.")
                }
            }
            try withDirectoryFD(destination.deletingLastPathComponent()) { toFD in
                var current = stat(); var targetParent = stat(); var existing = stat()
                guard fstatat(fromFD, source.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      identity(current) == expectedIdentity else { throw OrganizerError("원본이 미리보기 이후 바뀌었습니다. 다시 분석해 주세요.") }
                guard fstat(toFD, &targetParent) == 0 else { throw systemError("목적지 확인에 실패했습니다", destination.path) }
                if let expectedDestinationParent, identity(targetParent) != expectedDestinationParent {
                    throw OrganizerError("선택했던 목적지 폴더가 바뀌었습니다. 이동하지 않았습니다.")
                }
                guard current.st_dev == targetParent.st_dev else { throw OrganizerError("첫 버전은 같은 디스크 안의 이동만 지원합니다.") }
                if fstatat(toFD, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw OrganizerError("같은 이름의 항목이 이미 있습니다: \(destination.lastPathComponent)")
                }
                guard errno == ENOENT else { throw systemError("목적지를 확인할 수 없습니다", destination.path) }
                let result = renameatx_np(fromFD, source.lastPathComponent, toFD, destination.lastPathComponent, UInt32(RENAME_EXCL))
                guard result == 0 else { throw systemError("덮어쓰기 없이 이동할 수 없습니다", destination.path) }
                // The journal records .moving before this syscall; recovery also handles a sync failure after the rename.
                try syncFD(fromFD); try syncFD(toFD)
            }
        }
    }

    static func syncFD(_ descriptor: Int32) throws {
        if fsync(descriptor) != 0, errno != EINVAL, errno != ENOTSUP {
            throw OrganizerError("디스크 저장 확인에 실패했습니다. 실행 기록에서 상태를 확인해 주세요.")
        }
    }

    public static func removeCreatedDirectoryIfEmpty(_ directory: CreatedDirectory) throws {
        let url = URL(fileURLWithPath: directory.path)
        if !exists(url) { return }
        try withDirectoryFD(url.deletingLastPathComponent()) { parent in
            var current = stat()
            guard fstatat(parent, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  identity(current) == directory.identity else { return }
            if unlinkat(parent, url.lastPathComponent, AT_REMOVEDIR) != 0,
               errno != ENOTEMPTY, errno != EEXIST, errno != ENOENT {
                throw systemError("빈 폴더를 복원할 수 없습니다", url.path)
            }
        }
    }
}
