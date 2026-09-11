import XCTest
@testable import OrganizerMotion

final class TileWordmarkMotionTests: XCTestCase {
    private func validate(_ route: [TileWordmarkMotion.Beat], board: inout TileWordmarkMotion.Board,
                          file: StaticString = #filePath, line: UInt = #line) {
        for beat in route {
            let before = board
            let distance = abs(beat.from.column - beat.to.column) + abs(beat.from.row - beat.to.row)
            switch beat.kind {
            case .slide:
                XCTAssertEqual(distance, 1, file: file, line: line)
                XCTAssertFalse(before.visibleCells.contains(beat.to), file: file, line: line)
                // A unit square's swept path cannot cross a fixed square.
                for p in [0.25, 0.5, 0.75] {
                    let x = Double(beat.from.column) + Double(beat.to.column - beat.from.column) * p
                    let y = Double(beat.from.row) + Double(beat.to.row - beat.from.row) * p
                    for fixed in before.blocks where fixed.id != beat.blockID {
                        let overlaps = x < Double(fixed.cell.column + 1) && x + 1 > Double(fixed.cell.column)
                            && y < Double(fixed.cell.row + 1) && y + 1 > Double(fixed.cell.row)
                        XCTAssertFalse(overlaps, file: file, line: line)
                    }
                }
            case .flipOn:
                XCTAssertEqual(distance, 0, file: file, line: line)
                XCTAssertFalse(before.visibleCells.contains(beat.to), file: file, line: line)
            case .flipOff:
                XCTAssertEqual(distance, 0, file: file, line: line)
                XCTAssertTrue(before.visibleCells.contains(beat.from), file: file, line: line)
            }
            board.apply(beat)
            let delta = beat.kind == .flipOn ? 1 : beat.kind == .flipOff ? -1 : 0
            XCTAssertEqual(board.blocks.count, before.blocks.count + delta, file: file, line: line)
            XCTAssertEqual(Set(board.blocks.map(\.id)).count, board.blocks.count, file: file, line: line)
            XCTAssertEqual(board.visibleCells.count, board.blocks.count, file: file, line: line)
            XCTAssertTrue(board.blocks.allSatisfy {
                (0..<board.columns).contains($0.cell.column) && (0..<TileWordmarkMotion.rows).contains($0.cell.row)
            }, file: file, line: line)
            for block in before.blocks where block.id != beat.blockID {
                XCTAssertTrue(board.blocks.contains(block), file: file, line: line)
            }
        }
    }

    func testAllGlyphPairsUseOnlyLegalMovesAndNecessaryFlips() throws {
        XCTAssertEqual(PuzzleAlphabet.characters.count, 36)
        XCTAssertEqual(PuzzleAlphabet.symbols.count, 35)
        var distinct = Set<Set<TileWordmarkMotion.Cell>>()
        for source in PuzzleAlphabet.supportedCharacters {
            let initial = try TileWordmarkMotion.Board(text: String(source), columns: 5)
            distinct.insert(initial.visibleCells)
            for destination in PuzzleAlphabet.supportedCharacters {
                var board = initial
                let target = try TileWordmarkMotion.Board(text: String(destination), columns: 5)
                let route = try TileWordmarkMotion.route(from: board, to: String(destination))
                XCTAssertEqual(route.filter { $0.kind != .slide }.count,
                               abs(target.blocks.count - initial.blocks.count))
                validate(route, board: &board)
                for flip in route where flip.kind == .flipOn {
                    XCTAssertFalse(target.visibleCells.contains(flip.to), "New faces must turn outside the destination glyph")
                    let arrived = try XCTUnwrap(board.blocks.first { $0.id == flip.blockID })
                    XCTAssertNotEqual(arrived.cell, flip.to, "The flipped piece itself must slide")
                    XCTAssertTrue(target.visibleCells.contains(arrived.cell))
                }
                XCTAssertEqual(board.visibleCells, target.visibleCells, "\(source) -> \(destination)")
            }
        }
        XCTAssertEqual(try PuzzleAlphabet.cells(for: "S"), try PuzzleAlphabet.cells(for: "5"))
        XCTAssertEqual(distinct.count, PuzzleAlphabet.supportedCharacters.count - 1,
                       "The requested S shares the 5 silhouette; all other glyphs remain distinct")
    }

    func testMessagesCanRetargetAfterEveryIntermediateLanding() throws {
        let messages = ["TILES", "HELLO", "DONE!", "READY", "WAIT", "CHECK", "STOP", "0123", "9876", "!?", "50%", "…"]
        for source in messages {
            for destination in messages {
                var board = try TileWordmarkMotion.Board(text: source)
                let initialCount = board.blocks.count
                let route = try TileWordmarkMotion.route(from: board, to: destination)
                let target = try TileWordmarkMotion.Board(text: destination)
                XCTAssertEqual(route.filter { $0.kind != .slide }.count, abs(target.blocks.count - initialCount))
                var verified = board
                validate(route, board: &verified)
                for beat in route {
                    board.apply(beat)
                    var retargeted = board
                    for returning in try TileWordmarkMotion.route(from: board, to: "TILES") {
                        retargeted.apply(returning)
                    }
                    XCTAssertEqual(retargeted.visibleCells, try TileWordmarkMotion.Board(text: "TILES").visibleCells)
                }
                XCTAssertEqual(board.visibleCells, target.visibleCells)
            }
        }
    }

    func testNormalizationLimitsAndUnchangedWord() throws {
        XCTAssertEqual(try PuzzleAlphabet.cells(for: "hello 9"), try PuzzleAlphabet.cells(for: "HELLO 9"))
        XCTAssertEqual(try TileWordmarkMotion.Board(text: "TILES").blocks.count, 45)
        XCTAssertEqual(try PuzzleAlphabet.width(of: "TILES"), 19)
        XCTAssertTrue(try TileWordmarkMotion.route(from: .init(text: "TILES"), to: "tiles").isEmpty)
        XCTAssertThrowsError(try TileWordmarkMotion.Board(text: "한글"))
        XCTAssertThrowsError(try TileWordmarkMotion.Board(text: "HELLO", columns: 5))
        XCTAssertThrowsError(try TileWordmarkMotion.Board(text: "TILE", columns: 0))
        XCTAssertThrowsError(try TileWordmarkMotion.Board(text: " "))
        let wide = try TileWordmarkMotion.Board(text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", columns: 200)
        XCTAssertGreaterThan(wide.blocks.count, 300)
    }

    func testPunctuationAliasesSpacingAndMixedMessages() throws {
        let asciiSymbols = (33...126).compactMap { value -> Character? in
            guard !(48...57).contains(value), !(65...90).contains(value), !(97...122).contains(value) else { return nil }
            return Character(UnicodeScalar(value)!)
        }
        XCTAssertTrue(Set(asciiSymbols).isSubset(of: Set(PuzzleAlphabet.symbols)))
        XCTAssertEqual(try PuzzleAlphabet.normalized("‘done！’ “ok？” − – — … × ÷"), "'DONE!' \"OK?\" - - - … × ÷")
        XCTAssertEqual(try PuzzleAlphabet.width(of: "DONE!"), 19)
        XCTAssertEqual(try PuzzleAlphabet.cells(for: "!").map(\.row), [1, 2, 3, 5])
        XCTAssertEqual(try PuzzleAlphabet.cells(for: "."), [.init(0, 5)])
        XCTAssertEqual(try PuzzleAlphabet.cells(for: "…"), [.init(0, 5), .init(2, 5), .init(4, 5)])
        let hello = try TileWordmarkMotion.Board(text: "HELLO!")
        XCTAssertEqual(try PuzzleAlphabet.width(of: "HELLO!"), 21)
        XCTAssertTrue(hello.blocks.allSatisfy { $0.cell.column < 21 })
        XCTAssertThrowsError(try TileWordmarkMotion.Board(text: "HELLO!", columns: 20))
        XCTAssertThrowsError(try PuzzleAlphabet.normalized("🙂"))
    }

    func testRemovalScattersAcrossTheWordAndCanBeReplayed() throws {
        let initial = try TileWordmarkMotion.Board(text: "READY")
        let first = try TileWordmarkMotion.route(from: initial, to: ".", seed: 7)
        XCTAssertEqual(first, try TileWordmarkMotion.route(from: initial, to: ".", seed: 7))
        var orders: [[TileWordmarkMotion.Beat]] = []
        for seed in UInt64(0)..<8 {
            var board = initial
            let route = try TileWordmarkMotion.route(from: board, to: ".", seed: seed)
            let cells = route.map(\.from)
            let rowOrder = cells.sorted { $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row }
            XCTAssertNotEqual(cells, rowOrder, "Disappearance must not scan from the upper left")
            XCTAssertTrue(cells.prefix(8).contains { $0.column < 9 })
            XCTAssertTrue(cells.prefix(8).contains { $0.column >= 9 })
            if !orders.contains(route) { orders.append(route) }
            validate(route, board: &board)
            XCTAssertEqual(board.visibleCells, Set(try PuzzleAlphabet.cells(for: ".")))
        }
        XCTAssertGreaterThan(orders.count, 1)
    }

    func testMultipleSeedsKeepPuzzleRulesWhileInterleavingTurns() throws {
        let pairs = [("TILES", "HELLO"), ("DONE!", "?"), ("!", "READY"), ("100", "0")]
        var interleavedRemoval = false
        for seed in UInt64(0)..<8 {
            for (source, destination) in pairs {
                var board = try TileWordmarkMotion.Board(text: source)
                let target = try TileWordmarkMotion.Board(text: destination)
                let route = try TileWordmarkMotion.route(from: board, to: destination, seed: seed)
                XCTAssertEqual(route.filter { $0.kind != .slide }.count,
                               abs(target.blocks.count - board.blocks.count))
                if let turn = route.firstIndex(where: { $0.kind == .flipOff }),
                   let slide = route.lastIndex(where: { $0.kind == .slide }), turn < slide {
                    interleavedRemoval = true
                }
                validate(route, board: &board)
                for flip in route where flip.kind == .flipOn {
                    XCTAssertFalse(target.visibleCells.contains(flip.to))
                    let arrived = try XCTUnwrap(board.blocks.first { $0.id == flip.blockID })
                    XCTAssertNotEqual(arrived.cell, flip.to)
                    XCTAssertTrue(target.visibleCells.contains(arrived.cell))
                }
                XCTAssertEqual(board.visibleCells, target.visibleCells)
            }
        }
        XCTAssertTrue(interleavedRemoval, "Slides and disappearance should share the transition")
    }
}
