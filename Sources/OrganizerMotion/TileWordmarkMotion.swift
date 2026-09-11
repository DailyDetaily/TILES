/// Square pieces slide into adjacent blank cells. Only the difference in ink
/// count turns over: new black faces start outside the target lettering and
/// slide into it; surplus black faces turn white.
public enum TileWordmarkMotion {
    public struct Cell: Equatable, Hashable, Sendable {
        public let column: Int
        public let row: Int
        public init(_ column: Int, _ row: Int) { self.column = column; self.row = row }
        func distance(to other: Cell) -> Int {
            abs(column - other.column) + abs(row - other.row)
        }
    }

    public struct Block: Identifiable, Equatable, Sendable {
        public let id: Int
        public var cell: Cell
    }

    public static let columns = 23
    public static let rows = PuzzleAlphabet.height
    public static let stepDuration = 0.036
    public static let flipDuration = 0.12

    public struct Board: Equatable, Sendable {
        public private(set) var columns: Int
        public private(set) var blocks: [Block]
        public private(set) var nextID: Int
        public var visibleCells: Set<Cell> { Set(blocks.map(\.cell)) }

        public init(text: String, columns: Int = TileWordmarkMotion.columns) throws {
            guard columns > 0 else { throw PuzzleAlphabet.Error.invalidCanvas }
            let cells = try TileWordmarkMotion.targetCells(text, columns: columns)
            self.columns = columns
            blocks = cells.enumerated().map { Block(id: $0.offset, cell: $0.element) }
            nextID = blocks.count
        }

        /// Growing a number's board keeps every existing piece and position.
        public mutating func reserveColumns(_ count: Int) {
            columns = max(columns, count)
        }

        public mutating func apply(_ beat: Beat) {
            precondition((0..<columns).contains(beat.to.column) && (0..<TileWordmarkMotion.rows).contains(beat.to.row))
            switch beat.kind {
            case .slide:
                precondition(beat.from.distance(to: beat.to) == 1)
                let index = blocks.firstIndex { $0.id == beat.blockID && $0.cell == beat.from }!
                precondition(!blocks.contains { $0.cell == beat.to })
                blocks[index].cell = beat.to
            case .flipOn:
                precondition(beat.from == beat.to && beat.blockID == nextID)
                precondition(!blocks.contains { $0.cell == beat.to })
                blocks.append(Block(id: nextID, cell: beat.to))
                nextID += 1
            case .flipOff:
                precondition(beat.from == beat.to)
                precondition(blocks.contains { $0.id == beat.blockID && $0.cell == beat.from })
                blocks.removeAll { $0.id == beat.blockID }
            }
        }
    }

    public struct Beat: Equatable, Sendable {
        public enum Kind: Sendable { case slide, flipOn, flipOff }
        public let kind: Kind
        public let blockID: Int
        public let from: Cell
        public let to: Cell
        public var duration: Double { kind == .slide ? stepDuration : flipDuration }
    }

    /// Pass a vacancy along a path, preserving all intermediate occupancy.
    /// Turning over is needed only for the difference in black-face counts.
    public static func route(from board: Board, to text: String, seed: UInt64 = 0) throws -> [Beat] {
        let targets = try targetCells(text, columns: board.columns).sorted(by: ordered)
        let targetSet = Set(targets)
        var occupied = Dictionary(uniqueKeysWithValues: board.blocks.map { ($0.cell, $0.id) })
        var nextID = board.nextID
        var result: [Beat] = []
        var random = PuzzleOrder(seed: seed)
        // Mix the geometry into the supplied seed without Swift's process-random
        // Hasher. A recorded seed can reproduce a route exactly for verification.
        for cell in board.visibleCells.sorted(by: ordered) + targets {
            random.mix(UInt64(cell.column) &* 31 &+ UInt64(cell.row))
        }
        var lastFocus: Cell?
        var lastWasFlip = false

        func choose(_ candidates: [Cell]) -> Cell {
            candidates[Int.random(in: candidates.indices, using: &random)]
        }
        func dispersed(_ candidates: [Cell]) -> Cell {
            guard let lastFocus else { return choose(candidates) }
            let reach = candidates.map { $0.distance(to: lastFocus) }.max() ?? 0
            let threshold = max(1, (reach + 1) / 2)
            let elsewhere = candidates.filter { $0.distance(to: lastFocus) >= threshold }
            return choose(elsewhere.isEmpty ? candidates : elsewhere)
        }

        func slide(from: Cell, to: Cell) {
            let id = occupied.removeValue(forKey: from)!
            precondition(occupied[to] == nil)
            occupied[to] = id
            result.append(Beat(kind: .slide, blockID: id, from: from, to: to))
        }
        func transfer(from source: Cell, to hole: Cell) {
            let path = path(from: hole, to: source, using: &random)
            var vacancyIndex = 0
            for index in 1..<path.count where occupied[path[index]] != nil {
                for step in stride(from: index, to: vacancyIndex, by: -1) {
                    slide(from: path[step], to: path[step - 1])
                }
                vacancyIndex = index
            }
        }
        func nearbyPair(holes: [Cell], sources: [Cell]) -> (source: Cell, target: Cell) {
            let distances = holes.map { hole in sources.map { $0.distance(to: hole) }.min()! }
            let shortest = distances.min()!
            // Permit one extra step to work elsewhere, without sending pieces
            // on long decorative trips across the board.
            let candidates = zip(holes, distances).filter { $0.1 <= shortest + 1 }.map { $0.0 }
            let hole = dispersed(candidates)
            let distance = sources.map { $0.distance(to: hole) }.min()!
            return (choose(sources.filter { $0.distance(to: hole) == distance }), hole)
        }

        let background = (0..<rows).flatMap { row in
            (0..<board.columns).map { Cell($0, row) }
        }.filter { !targetSet.contains($0) }

        // Resolve one local puzzle at a time, then work in another region.
        // Interleave count changes with reuse; equal counts can only slide.
        while true {
            let missing = targets.filter { occupied[$0] == nil }
            let surplus = occupied.keys.filter { !targetSet.contains($0) }.sorted(by: ordered)
            guard !missing.isEmpty || !surplus.isEmpty else { break }
            let canReuse = !missing.isEmpty && !surplus.isEmpty
            let countDiffers = occupied.count != targets.count
            // Reuse between flips when possible. Randomly interspersed turns
            // avoid a separate row-by-row erase/reveal phase.
            let turn = countDiffers && (!canReuse || (!lastWasFlip && Int.random(in: 0..<3, using: &random) == 0))

            if turn && occupied.count > targets.count {
                let cell = dispersed(surplus)
                result.append(Beat(kind: .flipOff, blockID: occupied.removeValue(forKey: cell)!, from: cell, to: cell))
                lastFocus = cell
                lastWasFlip = true
            } else if turn && occupied.count < targets.count {
                let cell = dispersed(missing)
                let vacancies = background.filter { occupied[$0] == nil }
                guard let distance = vacancies.map({ $0.distance(to: cell) }).min() else {
                    throw PuzzleAlphabet.Error.invalidCanvas
                }
                let staging = choose(vacancies.filter { $0.distance(to: cell) <= distance + 1 })
                result.append(Beat(kind: .flipOn, blockID: nextID, from: staging, to: staging))
                occupied[staging] = nextID
                nextID += 1
                transfer(from: staging, to: cell)
                lastFocus = cell
                lastWasFlip = true
            } else {
                let pair = nearbyPair(holes: missing, sources: surplus)
                transfer(from: pair.source, to: pair.target)
                lastFocus = pair.target
                lastWasFlip = false
            }
        }
        return result
    }

    private static func targetCells(_ text: String, columns: Int) throws -> [Cell] {
        let width = try PuzzleAlphabet.width(of: text)
        guard width <= columns else {
            throw PuzzleAlphabet.Error.textTooWide(required: width, available: columns)
        }
        let cells = try PuzzleAlphabet.cells(for: text)
        guard !cells.isEmpty else { throw PuzzleAlphabet.Error.emptyText }
        return cells
    }

    private static func path(from start: Cell, to end: Cell, using random: inout PuzzleOrder) -> [Cell] {
        var result = [start]
        var x = start.column, y = start.row
        while x != end.column || y != end.row {
            let horizontal = abs(end.column - x)
            let vertical = abs(end.row - y)
            if Int.random(in: 0..<(horizontal + vertical), using: &random) < horizontal {
                x += x < end.column ? 1 : -1
            } else {
                y += y < end.row ? 1 : -1
            }
            result.append(Cell(x, y))
        }
        return result
    }

    private struct PuzzleOrder: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func mix(_ value: UInt64) { state = (state ^ value) &* 0x100000001b3 }
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return value ^ (value >> 31)
        }
    }

    private static func ordered(_ a: Cell, _ b: Cell) -> Bool {
        a.row == b.row ? a.column < b.column : a.row < b.row
    }
}
