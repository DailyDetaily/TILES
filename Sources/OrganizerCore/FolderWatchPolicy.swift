import Foundation
import Darwin

public struct FolderWatchConfiguration: Codable, Equatable, Sendable {
    public var folderPath: String?
    public var waitInterval: TimeInterval
    public var enabled: Bool
    public init(folderPath: String? = nil, waitInterval: TimeInterval = 600, enabled: Bool = false) {
        self.folderPath = folderPath; self.waitInterval = waitInterval; self.enabled = enabled
    }
    public func validate() throws {
        guard waitInterval.isFinite, (0...31_536_000).contains(waitInterval) else {
            throw OrganizerError("감시 대기 시간이 올바르지 않습니다.")
        }
        if let folderPath {
            guard folderPath.hasPrefix("/"), !folderPath.utf8.contains(0),
                  PathSafety.lexicalURL(URL(fileURLWithPath: folderPath)).path == folderPath else {
                throw OrganizerError("감시 폴더 경로가 올바르지 않습니다.")
            }
        } else if enabled { throw OrganizerError("감시할 폴더를 먼저 선택해 주세요.") }
    }
}

/// Metadata only: no hash or file contents are read by a folder watcher.
public struct FolderWatchFingerprint: Codable, Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var changedSeconds: Int64
    public var changedNanoseconds: Int64
    public init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64,
                modifiedNanoseconds: Int64 = 0, changedSeconds: Int64? = nil, changedNanoseconds: Int64 = 0) {
        self.device = device; self.inode = inode; self.size = size; self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds; self.changedSeconds = changedSeconds ?? modifiedSeconds
        self.changedNanoseconds = changedNanoseconds
    }
    public var lastActivity: Date {
        let modified = Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000
        let changed = Double(changedSeconds) + Double(changedNanoseconds) / 1_000_000_000
        return Date(timeIntervalSince1970: max(modified, changed))
    }
    public var isValid: Bool {
        size >= 0 && (0..<1_000_000_000).contains(modifiedNanoseconds) &&
            (0..<1_000_000_000).contains(changedNanoseconds)
    }
}

public struct FolderWatchFileVersion: Codable, Equatable, Sendable {
    public var path: String
    public var fingerprint: FolderWatchFingerprint
    public init(path: String, fingerprint: FolderWatchFingerprint) { self.path = path; self.fingerprint = fingerprint }
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct FolderWatchObservation: Codable, Equatable, Sendable {
    public var fingerprint: FolderWatchFingerprint
    public var stableSince: Date
    public var lastSeenAt: Date
    public var observations: Int
    public var delivered: Bool
    public init(fingerprint: FolderWatchFingerprint, now: Date) {
        self.fingerprint = fingerprint; stableSince = now; lastSeenAt = now; observations = 1; delivered = false
    }
}

public struct FolderWatchState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int = currentVersion
    public var configuration: FolderWatchConfiguration
    public var bookmark: Data?
    public var rootIdentity: FileIdentity?
    public var observations: [String: FolderWatchObservation]
    public var pending: [FolderWatchFileVersion]
    public init(configuration: FolderWatchConfiguration = .init(), bookmark: Data? = nil, rootIdentity: FileIdentity? = nil,
                observations: [String: FolderWatchObservation] = [:], pending: [FolderWatchFileVersion] = []) {
        self.configuration = configuration; self.bookmark = bookmark; self.rootIdentity = rootIdentity
        self.observations = observations; self.pending = pending
    }
    public func validate() throws {
        guard version == Self.currentVersion else { throw OrganizerError("지원하지 않는 폴더 감시 기록 버전입니다. 기존 파일을 유지합니다.") }
        try configuration.validate()
        guard observations.count <= 100_000, pending.count <= 100_000 else {
            throw OrganizerError("폴더 감시 기록이 너무 큽니다. 기존 파일을 유지합니다.")
        }
        guard configuration.folderPath != nil || (observations.isEmpty && pending.isEmpty && rootIdentity == nil),
              configuration.folderPath == nil || rootIdentity?.kind == "directory" else {
            throw OrganizerError("폴더 감시 기록의 위치 정보가 올바르지 않습니다.")
        }
        func validPath(_ path: String) -> Bool {
            guard let root = configuration.folderPath, !path.utf8.contains(0) else { return false }
            let url = URL(fileURLWithPath: path)
            return path.hasPrefix("/") && PathSafety.lexicalURL(url).path == path &&
                url.deletingLastPathComponent().path == root && !FolderWatchPolicy.excludes(name: url.lastPathComponent)
        }
        for (path, observation) in observations {
            guard validPath(path), observation.fingerprint.isValid, (1...2).contains(observation.observations),
                  observation.stableSince.timeIntervalSince1970.isFinite, observation.lastSeenAt.timeIntervalSince1970.isFinite,
                  observation.lastSeenAt >= observation.stableSince else {
                throw OrganizerError("폴더 감시 기록에 올바르지 않은 파일 정보가 있습니다. 기존 파일을 유지합니다.")
            }
        }
        var paths = Set<String>()
        for item in pending {
            guard validPath(item.path), paths.insert(item.path).inserted,
                  let observation = observations[item.path], observation.fingerprint == item.fingerprint, !observation.delivered else {
                throw OrganizerError("폴더 감시 대기열이 올바르지 않습니다. 기존 파일을 유지합니다.")
            }
        }
    }
}

public enum FolderWatchPolicy {
    public static let stabilityInterval: TimeInterval = 30
    public static let deliveryBatchLimit = 500
    private static let temporaryExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "temp", "filepart", "opdownload", "icloud", "swp", "swo"
    ]

    public static func excludes(name: String) -> Bool {
        let lower = name.lowercased()
        return name.isEmpty || name.hasPrefix(".") || name.hasPrefix("~$") || name.hasPrefix("~") ||
            lower.hasSuffix("~") || temporaryExtensions.contains((lower as NSString).pathExtension) ||
            lower.hasSuffix(".download.pending") || lower.contains(".crdownload.")
    }

    /// Two observations separated by at least 30 seconds are required even for an old existing file.
    /// A changed inode, size, mtime or ctime starts that observation window again.
    @discardableResult public static func observe(_ files: [FolderWatchFileVersion], state: inout FolderWatchState,
                                                   now: Date, stabilityInterval: TimeInterval = stabilityInterval) -> [FolderWatchFileVersion] {
        guard state.configuration.enabled, let root = state.configuration.folderPath else { return [] }
        let eligible = files.filter {
            $0.url.deletingLastPathComponent().path == root && $0.fingerprint.isValid && !excludes(name: $0.url.lastPathComponent)
        }
        let present = Set(eligible.map(\.path))
        state.observations = state.observations.filter { present.contains($0.key) }
        var pendingByPath: [String: FolderWatchFileVersion] = [:]
        var pendingOrder: [String] = []
        var orderedPaths = Set<String>()
        for file in state.pending where present.contains(file.path) {
            pendingByPath[file.path] = file
            if orderedPaths.insert(file.path).inserted { pendingOrder.append(file.path) }
        }
        var newReady: [FolderWatchFileVersion] = []
        for file in eligible.sorted(by: { $0.path < $1.path }) {
            var observation: FolderWatchObservation
            if var old = state.observations[file.path], old.fingerprint == file.fingerprint {
                // A wall-clock correction must not turn unobserved time into proof of stability.
                if now < old.lastSeenAt { old.stableSince = now; old.observations = 1 }
                else if now > old.lastSeenAt { old.observations = min(2, old.observations + 1) }
                old.lastSeenAt = now; observation = old
            } else {
                observation = .init(fingerprint: file.fingerprint, now: now)
                pendingByPath.removeValue(forKey: file.path)
            }
            state.observations[file.path] = observation
            let ready = observation.observations >= 2 &&
                now.timeIntervalSince(observation.stableSince) >= max(0, stabilityInterval) &&
                now.timeIntervalSince(file.fingerprint.lastActivity) >= state.configuration.waitInterval
            if !ready { pendingByPath.removeValue(forKey: file.path); continue }
            guard !observation.delivered,
                  pendingByPath[file.path] == nil else { continue }
            pendingByPath[file.path] = file
            if orderedPaths.insert(file.path).inserted { pendingOrder.append(file.path) }
            newReady.append(file)
        }
        state.pending = pendingOrder.compactMap { pendingByPath[$0] }
        return newReady
    }

    public static func markDelivered(_ files: [FolderWatchFileVersion], state: inout FolderWatchState) {
        var delivered: [String: FolderWatchFingerprint] = [:]
        for file in files {
            guard var observation = state.observations[file.path], observation.fingerprint == file.fingerprint else { continue }
            observation.delivered = true; state.observations[file.path] = observation
            delivered[file.path] = file.fingerprint
        }
        state.pending.removeAll { delivered[$0.path] == $0.fingerprint }
    }

    /// Immediate children only. lstat and resource metadata are used; no file contents, OCR or hashes.
    public static func scan(folder: URL, expectedIdentity: FileIdentity? = nil,
                            cancelled: () -> Bool = { false }) throws -> [FolderWatchFileVersion] {
        if cancelled() { throw CancellationError() }
        try SafeFileSystem.validateDirectory(folder)
        let rootIdentity = try SafeFileSystem.identity(at: folder)
        if let expectedIdentity, rootIdentity != expectedIdentity { throw OrganizerError("감시 폴더가 다른 폴더로 바뀌었습니다. 다시 선택해 주세요.") }
        let rootValues = try folder.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey, .volumeIsLocalKey])
        guard rootValues.isAliasFile != true, rootValues.isPackage != true, rootValues.volumeIsLocal == true else {
            throw OrganizerError("이 Mac의 일반 폴더를 선택해 주세요. 별칭이나 앱 묶음은 감시하지 않습니다.")
        }
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
        var files: [FolderWatchFileVersion] = []
        for url in children {
            if cancelled() { throw CancellationError() }
            guard !excludes(name: url.lastPathComponent), let info = try? SafeFileSystem.info(url),
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_flags & UInt32(SF_DATALESS) == 0,
                  info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey, .isHiddenKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .volumeIsLocalKey]),
                  values.isAliasFile != true, values.isPackage != true, values.isHidden != true, values.volumeIsLocal == true,
                  values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current,
                  access(url.path, R_OK) == 0 else { continue }
            let fingerprint = FolderWatchFingerprint(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), changedSeconds: Int64(info.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
            files.append(.init(path: url.path, fingerprint: fingerprint))
        }
        if cancelled() { throw CancellationError() }
        guard try SafeFileSystem.identity(at: folder) == rootIdentity else {
            throw OrganizerError("확인하는 동안 감시 폴더가 바뀌었습니다. 다시 선택해 주세요.")
        }
        return files.sorted { $0.path < $1.path }
    }
}
