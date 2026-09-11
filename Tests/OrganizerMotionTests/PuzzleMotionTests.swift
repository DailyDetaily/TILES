import XCTest
@testable import OrganizerMotion

final class PuzzleMotionTests: XCTestCase {
    private var targets: [PuzzleBoard] {
        [.resting(page: .organize, expanded: false)] + PuzzlePage.allCases.map { .resting(page: $0, expanded: true) }
    }
    func testAllRoutesLandWithoutCrossingOccupiedCells() {
        for start in targets { for target in targets {
            var previous = start
            for beat in PuzzleRoute.beats(from: start, to: target) {
                XCTAssertTrue(beat.board.isValid)
                let a = previous[beat.tile], b = beat.board[beat.tile]
                let changed = PuzzleTile.allCases.filter { previous[$0] != beat.board[$0] }
                XCTAssertEqual(changed, [beat.tile])
                if beat.kind == .slide {
                    XCTAssertEqual(abs(a.x - b.x) + abs(a.y - b.y), 1)
                    XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
                }
                // Sample the full swept rectangle, not just the endpoint. Thus a
                // diagonal shortcut or pass-through cannot accidentally pass.
                for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let x = Double(a.x) + Double(b.x - a.x) * fraction
                    let y = Double(a.y) + Double(b.y - a.y) * fraction
                    let w = Double(a.width) + Double(b.width - a.width) * fraction
                    let h = Double(a.height) + Double(b.height - a.height) * fraction
                    for other in PuzzleTile.allCases where other != beat.tile {
                        let r = previous[other]
                        let overlap = x < Double(r.x + r.width) - 0.00001 && x + w > Double(r.x) + 0.00001 && y < Double(r.y + r.height) - 0.00001 && y + h > Double(r.y) + 0.00001
                        XCTAssertFalse(overlap, "\(beat.tile) crosses \(other)")
                    }
                }
                previous = beat.board
            }
            XCTAssertEqual(previous, target)
        } }
    }
    func testRapidRetargetingFromEveryIntermediateLanding() {
        for start in targets { for target in targets {
            for beat in PuzzleRoute.beats(from: start, to: target) {
                for latest in targets {
                    let route = PuzzleRoute.beats(from: beat.board, to: latest)
                    XCTAssertEqual(route.last?.board ?? beat.board, latest)
                    XCTAssertTrue(route.allSatisfy { $0.board.isValid })
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
}
