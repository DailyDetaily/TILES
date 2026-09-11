import Foundation
import CoreGraphics

/// Review is an action, never a fabricated filesystem destination.
public enum FolderDropTarget: Sendable, Equatable, Identifiable {
    case recommendation
    case folder(FolderRecommendation)
    public var id: String {
        switch self { case .recommendation: return "tile:recommendation"; case .folder(let candidate): return candidate.id }
    }
    public var name: String {
        switch self { case .recommendation: return "정리 추천"; case .folder(let candidate): return candidate.name }
    }
    public var candidate: FolderRecommendation? {
        if case .folder(let candidate) = self { return candidate }; return nil
    }
}

/// Pure session guard: one candidate publication and at most one execution per native drag sequence.
public struct FolderDropSession: Sendable {
    public struct Token: Sendable, Equatable { public let sequence: Int; public let generation: UUID }
    public enum Phase: Sendable { case idle, preparing, ready, rejected, moving, finished, cancelled }
    public private(set) var phase: Phase = .idle
    public private(set) var token: Token?
    public private(set) var sources: [String] = []
    public var source: String? { sources.first }
    public private(set) var targets: [FolderDropTarget] = []
    public var candidates: [FolderRecommendation] { targets.compactMap(\.candidate) }
    public private(set) var message: String?
    public private(set) var hoveredID: String?
    private var retired: [Int] = []
    public init() {}

    @discardableResult public mutating func begin(sequence: Int, source: String?) -> Token? {
        begin(sequence: sequence, sources: source.map { [$0] } ?? [])
    }
    @discardableResult public mutating func begin(sequence: Int, sources: [String]) -> Token? {
        if let token, token.sequence == sequence { return token }
        guard !retired.contains(sequence), phase != .moving else { return nil }
        if let token { retire(token.sequence) }
        let token = Token(sequence: sequence, generation: UUID())
        self.token = token; self.sources = sources; targets = []; message = nil; hoveredID = nil; phase = .preparing
        return token
    }
    @discardableResult public mutating func freeze(_ candidates: [FolderRecommendation], message: String? = nil, for token: Token) -> Bool {
        freeze(targets: candidates.map(FolderDropTarget.folder), message: message, for: token)
    }
    @discardableResult public mutating func freeze(targets: [FolderDropTarget], message: String? = nil, for token: Token) -> Bool {
        guard self.token == token, phase == .preparing else { return false }
        var ids = Set<String>()
        self.targets = Array(targets.filter { ids.insert($0.id).inserted }.prefix(3)); self.message = message
        phase = self.targets.isEmpty ? .rejected : .ready
        return true
    }
    public mutating func hover(_ id: String?) { hoveredID = phase == .ready && targets.contains(where: { $0.id == id }) ? id : nil }
    public func canAccept(sequence: Int, source: String, allowsMove: Bool, busy: Bool) -> Bool {
        canAccept(sequence: sequence, sources: [source], allowsMove: allowsMove, busy: busy)
    }
    public func canAccept(sequence: Int, sources: [String], allowsMove: Bool, busy: Bool) -> Bool {
        canAccept(sequence: sequence, sources: sources, allowsOperation: allowsMove, busy: busy)
    }
    public func canAccept(sequence: Int, sources: [String], allowsOperation: Bool, busy: Bool) -> Bool {
        token?.sequence == sequence && self.sources == sources && !sources.isEmpty && sources.count <= ExistingFileDrop.maximumBatchCount && phase == .ready && allowsOperation && !busy &&
        targets.contains(where: { $0.id == hoveredID })
    }
    public mutating func accept(sequence: Int, source: String, allowsMove: Bool, busy: Bool) -> FolderRecommendation? {
        guard targets.first(where: { $0.id == hoveredID })?.candidate != nil else { return nil }
        return accept(sequence: sequence, sources: [source], allowsMove: allowsMove, busy: busy)?.candidate
    }
    public mutating func accept(sequence: Int, sources: [String], allowsMove: Bool, busy: Bool) -> FolderDropTarget? {
        accept(sequence: sequence, sources: sources, allowsOperation: allowsMove, busy: busy)
    }
    public mutating func accept(sequence: Int, sources: [String], allowsOperation: Bool, busy: Bool) -> FolderDropTarget? {
        guard canAccept(sequence: sequence, sources: sources, allowsOperation: allowsOperation, busy: busy),
              let result = targets.first(where: { $0.id == hoveredID }) else { return nil }
        retire(sequence); phase = .moving; hoveredID = nil
        return result
    }
    public mutating func ended(sequence: Int) {
        guard token?.sequence == sequence else { return }
        hoveredID = nil
        if phase != .moving && phase != .finished { phase = .cancelled; targets = [] }
        retire(sequence)
    }
    public mutating func finish() { if phase == .moving { phase = .finished } }
    public mutating func reset() {
        if let token { retire(token.sequence) }
        token = nil; sources = []; targets = []; message = nil; hoveredID = nil; phase = .idle
    }
    private mutating func retire(_ sequence: Int) {
        if !retired.contains(sequence) { retired.append(sequence) }
        if retired.count > 64 { retired.removeFirst(retired.count - 64) }
    }
}

/// All values are AppKit points in global screen coordinates, including negative display origins.
public enum FolderOverlayGeometry {
    public static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat, size: CGSize) -> CGRect {
        let width = min(size.width, max(1, visible.width - 24))
        let top = min(visible.maxY, screen.maxY - safeTop) - 8
        let x = min(max(screen.midX - width / 2, visible.minX + 12), visible.maxX - width - 12)
        return CGRect(x: x, y: top - size.height, width: width, height: size.height)
    }
}
