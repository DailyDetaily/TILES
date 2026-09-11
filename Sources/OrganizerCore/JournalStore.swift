import Foundation
import Darwin

public struct HistoryResult {
    public var records: [RunRecord]
    public var errors: [String]
}

public final class JournalStore: Sendable {
    public let directory: URL
    private let directoryIdentity: FileIdentity

    public init(directory: URL) throws {
        self.directory = try PathSafety.resolveExistingPrefix(directory)
        let existing = try SafeFileSystem.nearestExistingDirectory(self.directory)
        var current = existing
        let components = self.directory.pathComponents.dropFirst(existing.pathComponents.count)
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            _ = try SafeFileSystem.createDirectory(current)
        }
        try SafeFileSystem.validateDirectory(self.directory)
        directoryIdentity = try SafeFileSystem.identity(at: self.directory)
    }

    public func fileURL(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try validateStorage()
        return try SafeFileSystem.withDirectoryFD(directory) { parent in
            let descriptor = openat(parent, "operation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw OrganizerError("실행 기록 잠금 파일을 열 수 없습니다.") }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw OrganizerError("다른 창이나 앱에서 정리 작업이 진행 중입니다.") }
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    private func validateStorage() throws {
        try SafeFileSystem.validateDirectory(directory)
        guard try SafeFileSystem.identity(at: directory) == directoryIdentity else { throw OrganizerError("실행 기록 폴더가 바뀌었습니다. 앱을 다시 열어 주세요.") }
    }

    public func save(_ record: RunRecord) throws {
        try validateStorage()
        let url = fileURL(for: record.id)
        if SafeFileSystem.exists(url), try SafeFileSystem.identity(at: url).kind != "file" {
            throw OrganizerError("실행 기록을 일반 파일에 저장할 수 없습니다.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        guard data.count <= 32 * 1_024 * 1_024 else { throw OrganizerError("실행 기록이 너무 큽니다. 항목을 나누어 실행해 주세요.") }
        try data.write(to: url, options: .atomic)
        try SafeFileSystem.withDirectoryFD(directory) { parent in
            let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw OrganizerError("실행 기록 저장을 확인할 수 없습니다.") }
            defer { close(descriptor) }
            try SafeFileSystem.syncFD(descriptor); try SafeFileSystem.syncFD(parent)
        }
    }

    public func load(_ id: UUID) throws -> RunRecord {
        try validateStorage()
        let url = fileURL(for: id)
        guard try SafeFileSystem.identity(at: url).kind == "file",
              try SafeFileSystem.info(url).st_size <= 32 * 1_024 * 1_024 else { throw OrganizerError("실행 기록 파일의 형식이나 크기가 올바르지 않습니다.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RunRecord.self, from: Data(contentsOf: url))
        guard record.id == id else { throw OrganizerError("실행 기록의 식별자가 일치하지 않습니다.") }
        return record
    }

    public func history() throws -> HistoryResult {
        try validateStorage()
        var records: [RunRecord] = []; var errors: [String] = []
        for url in try SafeFileSystem.children(directory) where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do { records.append(try load(id)) }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return .init(records: records.sorted { $0.createdAt > $1.createdAt }, errors: errors)
    }
}
