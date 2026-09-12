import Foundation

public enum PuzzlePage: String, CaseIterable, Sendable {
    case organize = "정리", history = "기록", rules = "규칙"
}
public enum PuzzlePhase: String, CaseIterable, Sendable {
    case intake, recommendation, preview, completion
}
public enum PuzzleTile: String, CaseIterable, Hashable, Sendable {
    case source, destination, headline, total, metrics, workspace, action, guide
}
public struct GridRect: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(_ x: Int, _ y: Int, _ width: Int = 1, _ height: Int = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func overlaps(_ other: GridRect) -> Bool {
        x < other.x + other.width && x + width > other.x && y < other.y + other.height && y + height > other.y
    }
}
public struct PuzzleBoard: Equatable, Sendable {
    public var tiles: [PuzzleTile: GridRect]
    public subscript(_ tile: PuzzleTile) -> GridRect { get { tiles[tile]! } set { tiles[tile] = newValue } }
    public static func resting(page: PuzzlePage, expanded: Bool, phase: PuzzlePhase = .intake) -> Self {
        let slots = PuzzleRoute.slots
        let order: [PuzzleTile]
        let workspaceExpanded: Bool
        switch page {
        case .organize:
            switch phase {
            case .intake:
                order = [.total, .metrics, .action]
                workspaceExpanded = expanded
            case .recommendation:
                order = [.metrics, .action, .total]
                workspaceExpanded = true
            case .preview:
                order = [.action, .total, .metrics]
                workspaceExpanded = true
            case .completion:
                order = [.total, .metrics, .action]
                workspaceExpanded = false
            }
        case .history:
            order = [.action, .total, .metrics]
            workspaceExpanded = expanded
        case .rules:
            order = [.metrics, .action, .total]
            workspaceExpanded = expanded
        }
        var tiles: [PuzzleTile: GridRect] = [
            .source: .init(0, 0, 1, 2), .destination: .init(0, 2, 1, 2),
            .headline: .init(1, 0, 3, 1), .workspace: .init(1, 1, workspaceExpanded ? 4 : 3, 3),
            .guide: workspaceExpanded ? .init(5, 2, 1, 2) : .init(4, 1, 1, 3)
        ]
        for index in 0..<3 { tiles[order[index]] = slots[index] }
        return .init(tiles: tiles)
    }
    public var isValid: Bool {
        guard tiles.count == PuzzleTile.allCases.count else { return false }
        for tile in PuzzleTile.allCases {
            let a = self[tile]
            guard a.x >= 0, a.y >= 0, a.width > 0, a.height > 0, a.x + a.width <= 6, a.y + a.height <= 4 else { return false }
            for other in PuzzleTile.allCases where other != tile {
                if a.overlaps(self[other]) { return false }
            }
        }
        return true
    }
}
public struct PuzzleBeat: Sendable {
    public enum Kind: Sendable { case slide, resize }
    public let tile: PuzzleTile
    public let board: PuzzleBoard
    public let kind: Kind
    public var duration: TimeInterval { kind == .slide ? 0.09 : 0.12 }
}
public enum PuzzleRoute {
    // Clockwise 2×2 ring. The fourth slot becomes empty when the workspace folds.
    static let slots = [GridRect(4, 0), GridRect(5, 0), GridRect(5, 1), GridRect(4, 1)]
    public static func beats(from start: PuzzleBoard, to target: PuzzleBoard) -> [PuzzleBeat] {
        precondition(start.isValid && target.isValid)
        if start == target { return [] }
        var board = start
        var result: [PuzzleBeat] = []
        func change(_ tile: PuzzleTile, _ rect: GridRect) {
            let old = board[tile]
            guard old != rect else { return }
            let kind: PuzzleBeat.Kind = old.width == rect.width && old.height == rect.height ? .slide : .resize
            if kind == .slide { precondition(abs(old.x - rect.x) + abs(old.y - rect.y) == 1) }
            else { precondition(old.x == rect.x && old.y == rect.y) }
            board[tile] = rect
            precondition(board.isValid, "Motion must only enter a vacant slot")
            result.append(.init(tile: tile, board: board, kind: kind))
        }
        // Clear a corridor, in an order that also works after rapid retargeting.
        change(.workspace, .init(1, 1, 3, 3))
        if board[.guide].height == 3 { change(.guide, .init(4, 1, 1, 2)) }
        if board[.guide].y == 1 { change(.guide, .init(4, 2, 1, 2)) }
        if board[.guide].x == 4 { change(.guide, .init(5, 2, 1, 2)) }

        let moving: [PuzzleTile] = [.total, .metrics, .action]
        func arrangement(_ value: PuzzleBoard) -> [Int] {
            slots.map { slot in moving.firstIndex { value[$0] == slot } ?? -1 }
        }
        let initial = arrangement(board), goal = arrangement(target)
        struct Node { let state: [Int]; let moves: [(Int, Int)] }
        var queue = [Node(state: initial, moves: [])], visited: Set<[Int]> = [initial], cursor = 0
        var solution: [(Int, Int)]?
        while cursor < queue.count {
            let node = queue[cursor]; cursor += 1
            if node.state == goal { solution = node.moves; break }
            let empty = node.state.firstIndex(of: -1)!
            for next in 0..<4 where node.state[next] != -1 {
                guard abs(slots[next].x - slots[empty].x) + abs(slots[next].y - slots[empty].y) == 1 else { continue }
                var state = node.state; state.swapAt(next, empty)
                if visited.insert(state).inserted { queue.append(.init(state: state, moves: node.moves + [(node.state[next], empty)])) }
            }
        }
        guard let solution else { preconditionFailure("Unreachable puzzle arrangement") }
        for (tileIndex, slot) in solution { change(moving[tileIndex], slots[slot]) }

        if target[.workspace].width == 4 {
            change(.workspace, .init(1, 1, 4, 3))
        } else {
            change(.guide, .init(4, 2, 1, 2))
            change(.guide, .init(4, 1, 1, 2))
            change(.guide, .init(4, 1, 1, 3))
        }
        precondition(board == target)
        return result
    }
}
