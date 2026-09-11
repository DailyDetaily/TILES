import Foundation

public struct OrganizerError: Sendable, Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Decision: String, Sendable, Codable, CaseIterable {
    case move, rename, keep, review, excluded
    public var label: String {
        switch self {
        case .move: return "이동"
        case .rename: return "이름 변경"
        case .keep: return "유지"
        case .review: return "분류 필요"
        case .excluded: return "제외"
        }
    }
    public var executable: Bool { self == .move || self == .rename }
}

public struct FileIdentity: Sendable, Codable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var kind: String
}

public struct SnapshotEntry: Sendable, Codable, Equatable {
    public var relativePath: String
    public var identity: FileIdentity
    public var bytes: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var sha256: String?
}

public struct TreeSnapshot: Sendable, Codable, Equatable {
    public var entries: [SnapshotEntry]
    public var totalBytes: Int64
    public var fileCount: Int { entries.filter { $0.identity.kind == "file" }.count }
    public var rootIdentity: FileIdentity { entries.first!.identity }
}

public struct Proposal: Sendable, Codable, Identifiable {
    public var id: UUID
    public var source: String
    public var destination: String?
    public var decision: Decision
    public var reason: String
    public var isDirectory: Bool
    public var category: String?
    public var snapshot: TreeSnapshot?
    public var canAssignCategory: Bool
    public init(source: String, destination: String? = nil, decision: Decision, reason: String,
                isDirectory: Bool, category: String? = nil, snapshot: TreeSnapshot? = nil,
                canAssignCategory: Bool = false) {
        self.id = UUID(); self.source = source; self.destination = destination
        self.decision = decision; self.reason = reason; self.isDirectory = isDirectory
        self.category = category; self.snapshot = snapshot; self.canAssignCategory = canAssignCategory
    }
    public var name: String { URL(fileURLWithPath: source).lastPathComponent }
}

public struct ScanPlan: Sendable, Codable, Identifiable {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var sourceRoots: [String]
    public var sourceRootIdentities: [String: FileIdentity]
    public var destinationRoot: String
    public var destinationAnchor: String
    public var destinationAnchorIdentity: FileIdentity
    public var proposals: [Proposal]
    public var warnings: [String]
    public var referenceFilesChecked: Int
    public var rules: OrganizerRules
    /// Set by an existing-folder drop. Nil retains the batch planner's directory creation policy.
    public var destinationParentIdentities: [String: FileIdentity]? = nil
    /// Explicit, previewed directory creation. Nil preserves legacy planning behavior.
    public var directoryCreationPlan: DirectoryCreationPlan? = nil
    /// Immediate source parents, independent of the wider reference-check roots.
    public var sourceParentIdentities: [String: FileIdentity]? = nil
}

public struct DirectoryCreationPlan: Sendable, Codable {
    /// Parent-first paths including the existing destination root.
    public var paths: [String]
    /// Every directory that existed during preview, including intermediate parents.
    public var existingIdentities: [String: FileIdentity]
    /// Explicit template branches, created even when they receive no file.
    public var explicitDirectories: [String]
}

public enum EntryState: String, Sendable, Codable {
    case pending, moving, moved, undoing, undone, attention
}

public struct RunEntry: Sendable, Codable, Identifiable {
    public var id: UUID
    public var source: String
    public var destination: String
    public var snapshot: TreeSnapshot
    public var state: EntryState
    public var note: String?
}

public struct CreatedDirectory: Sendable, Codable {
    public var path: String
    public var identity: FileIdentity
}

public enum RunState: String, Sendable, Codable {
    case running, completed, interrupted, undoing, undone, attention
    public var label: String {
        switch self {
        case .running: return "실행 중"
        case .completed: return "완료"
        case .interrupted: return "일부 완료"
        case .undoing: return "되돌리는 중"
        case .undone: return "되돌림 완료"
        case .attention: return "상태 확인 필요"
        }
    }
}

public struct RunRecord: Sendable, Codable, Identifiable {
    public var version: Int = 1
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var state: RunState
    public var sourceRoots: [String]
    public var sourceRootIdentities: [String: FileIdentity]
    public var destinationRoot: String
    public var destinationAnchor: String
    public var destinationAnchorIdentity: FileIdentity
    public var rules: OrganizerRules
    public var entries: [RunEntry]
    public var createdDirectories: [CreatedDirectory]
    public var message: String?
    public var destinationParentIdentities: [String: FileIdentity]? = nil
    public var directoryCreationPlan: DirectoryCreationPlan? = nil
    public var sourceParentIdentities: [String: FileIdentity]? = nil
    public var movedCount: Int { entries.filter { $0.state == .moved }.count }
    public var canUndo: Bool {
        state != .undone && (!createdDirectories.isEmpty || entries.contains { [.moved, .moving, .undoing].contains($0.state) })
    }
}

public struct EngineProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var message: String
    public init(_ completed: Int, _ total: Int, _ message: String) {
        self.completed = completed; self.total = total; self.message = message
    }
}
