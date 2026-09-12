import XCTest
@testable import OrganizerMotion

final class PuzzleMotionTests: XCTestCase {
    private var targets: [PuzzleBoard] {
        let boards: [PuzzleBoard] = [.resting(page: .organize, expanded: false)]
            + PuzzlePage.allCases.map { .resting(page: $0, expanded: true) }
            + PuzzlePhase.allCases.map { .resting(page: .organize, expanded: false, phase: $0) }
        return boards.reduce(into: []) { result, board in
            if !result.contains(board) { result.append(board) }
        }
    }
    func testAllRoutesLandWithoutCrossingOccupiedCells() {
        for start in targets { for target in targets {
            assertLegalRoute(from: start, to: target)
        } }
    }
    func testRapidRetargetingFromEveryIntermediateLanding() {
        for start in targets { for target in targets {
            for beat in PuzzleRoute.beats(from: start, to: target) {
                for latest in targets {
                    assertLegalRoute(from: beat.board, to: latest)
                }
            }
        } }
    }
    func testNavigationUsesFourOrthogonalMovesAndHasBoundedRhythm() {
        for page in PuzzlePage.allCases { for next in PuzzlePage.allCases where page != next {
            let route = PuzzleRoute.beats(from: .resting(page: page, expanded: true), to: .resting(page: next, expanded: true))
            XCTAssertEqual(route.filter { $0.kind == .slide }.count, 4)
            XCTAssertLessThanOrEqual(route.reduce(0) { $0 + $1.duration }, 0.61)
        } }
    }
    func testNoMovementForAnUnchangedState() {
        for target in targets { XCTAssertTrue(PuzzleRoute.beats(from: target, to: target).isEmpty) }
    }

    func testOrganizePhasesBringRelevantTileBesideHeadline() {
        let leading: [(PuzzlePhase, PuzzleTile)] = [
            (.intake, .total), (.recommendation, .metrics), (.preview, .action), (.completion, .total)
        ]
        let intake = PuzzleBoard.resting(page: .organize, expanded: false)
        for (phase, tile) in leading {
            let board = PuzzleBoard.resting(page: .organize, expanded: false, phase: phase)
            XCTAssertTrue(board.isValid)
            XCTAssertEqual(board[tile], GridRect(4, 0))
            for anchor in [PuzzleTile.source, .destination, .headline] {
                XCTAssertEqual(board[anchor], intake[anchor])
            }
        }
    }

    func testReviewExpandsAndCompletionRestoresGuide() {
        for expanded in [false, true] {
            for phase in [PuzzlePhase.recommendation, .preview] {
                let board = PuzzleBoard.resting(page: .organize, expanded: expanded, phase: phase)
                XCTAssertEqual(board[.workspace], GridRect(1, 1, 4, 3))
                XCTAssertEqual(board[.guide], GridRect(5, 2, 1, 2))
            }
            let completed = PuzzleBoard.resting(page: .organize, expanded: expanded, phase: .completion)
            XCTAssertEqual(completed[.workspace], GridRect(1, 1, 3, 3))
            XCTAssertEqual(completed[.guide], GridRect(4, 1, 1, 3))
            let intake = PuzzleBoard.resting(page: .organize, expanded: expanded, phase: .intake)
            XCTAssertEqual(intake, .resting(page: .organize, expanded: expanded))
            XCTAssertEqual(intake[.workspace].width, expanded ? 4 : 3)
        }
    }

    func testOrganizePhaseDoesNotAlterOtherPages() {
        for page in [PuzzlePage.history, .rules] {
            for expanded in [false, true] {
                for phase in PuzzlePhase.allCases {
                    XCTAssertEqual(PuzzleBoard.resting(page: page, expanded: expanded, phase: phase),
                                   .resting(page: page, expanded: expanded))
                }
            }
        }
    }

    func testPhaseProgressionAndReturnAreFiniteThenRest() {
        let phases = PuzzlePhase.allCases
        for sequence in [phases, Array(phases.reversed())] {
            for (from, to) in zip(sequence, sequence.dropFirst()) {
                let start = PuzzleBoard.resting(page: .organize, expanded: false, phase: from)
                let target = PuzzleBoard.resting(page: .organize, expanded: false, phase: to)
                let route = PuzzleRoute.beats(from: start, to: target)
                XCTAssertFalse(route.isEmpty)
                let expectedSlides = start[.workspace].width == target[.workspace].width ? 4 : 6
                XCTAssertEqual(route.filter { $0.kind == .slide }.count, expectedSlides)
                XCTAssertLessThanOrEqual(route.reduce(0) { $0 + $1.duration }, 0.81)
                XCTAssertTrue(PuzzleRoute.beats(from: target, to: target).isEmpty)
            }
        }
        XCTAssertTrue(PuzzleRoute.beats(from: .resting(page: .organize, expanded: false, phase: .completion),
                                      to: .resting(page: .organize, expanded: false, phase: .intake)).isEmpty)
    }

    private func assertLegalRoute(from start: PuzzleBoard, to target: PuzzleBoard,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var previous = start
        for beat in PuzzleRoute.beats(from: start, to: target) {
            XCTAssertTrue(beat.board.isValid, file: file, line: line)
            let a = previous[beat.tile], b = beat.board[beat.tile]
            let changed = PuzzleTile.allCases.filter { previous[$0] != beat.board[$0] }
            XCTAssertEqual(changed, [beat.tile], file: file, line: line)
            if beat.kind == .slide {
                XCTAssertEqual(abs(a.x - b.x) + abs(a.y - b.y), 1, file: file, line: line)
                XCTAssertEqual(a.width, b.width, file: file, line: line)
                XCTAssertEqual(a.height, b.height, file: file, line: line)
            } else {
                XCTAssertEqual(a.x, b.x, file: file, line: line)
                XCTAssertEqual(a.y, b.y, file: file, line: line)
            }
            for anchor in [PuzzleTile.source, .destination, .headline] {
                XCTAssertEqual(beat.board[anchor], start[anchor], file: file, line: line)
            }
            // Sample the entire swept rectangle, including interrupted routes.
            for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
                let x = Double(a.x) + Double(b.x - a.x) * fraction
                let y = Double(a.y) + Double(b.y - a.y) * fraction
                let w = Double(a.width) + Double(b.width - a.width) * fraction
                let h = Double(a.height) + Double(b.height - a.height) * fraction
                for other in PuzzleTile.allCases where other != beat.tile {
                    let r = previous[other]
                    let overlap = x < Double(r.x + r.width) - 0.00001 && x + w > Double(r.x) + 0.00001 && y < Double(r.y + r.height) - 0.00001 && y + h > Double(r.y) + 0.00001
                    XCTAssertFalse(overlap, "\(beat.tile) crosses \(other)", file: file, line: line)
                }
            }
            previous = beat.board
        }
        XCTAssertEqual(previous, target, file: file, line: line)
    }
}
