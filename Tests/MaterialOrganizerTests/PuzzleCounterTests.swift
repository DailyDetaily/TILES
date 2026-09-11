import XCTest
import OrganizerMotion
@testable import MaterialOrganizer

final class PuzzleCounterTests: XCTestCase {
    func testZeroIsThreeByFiveAndSharesTheOtherDigitsBaseline() throws {
        let zero = try PuzzleAlphabet.cells(for: "0")
        XCTAssertEqual(try PuzzleAlphabet.width(of: "0"), 3)
        XCTAssertEqual(Set(zero.map(\.column)), Set(0..<3))
        XCTAssertEqual(Set(zero.map(\.row)), Set(1..<6))
        XCTAssertEqual(zero.count, 8)
        let nine = try PuzzleAlphabet.cells(for: "9")
        XCTAssertEqual(zero.map(\.row).max(), nine.map(\.row).max())
        XCTAssertEqual(nine.map(\.row).min(), 1)
    }

    func testMissingValueIsADashAndNeverBecomesZero() throws {
        let missing = try TileWordmarkMotion.Board(text: "—", columns: 5)
        let zero = try TileWordmarkMotion.Board(text: "0", columns: 5)
        XCTAssertEqual(try PuzzleAlphabet.normalized("—"), "-")
        XCTAssertEqual(missing.blocks.count, 3)
        XCTAssertNotEqual(missing.visibleCells, zero.visibleCells)
        var updated = missing
        for beat in try TileWordmarkMotion.route(from: updated, to: "0") { updated.apply(beat) }
        XCTAssertEqual(updated.visibleCells, zero.visibleCells)
    }

    @MainActor func testDigitGrowthKeepsExistingPiecesAndLatestNumber() async throws {
        let player = TileWordmarkPlayer(text: "9", columns: 5, allowsExpansion: true)
        let before = player.board.blocks
        try player.show("1000")
        XCTAssertEqual(player.board.blocks, before, "A wider number must not rebuild the current pieces")
        XCTAssertGreaterThan(player.board.columns, 5)
        try await Task.sleep(for: .milliseconds(70))
        try player.show("99")
        player.setPresentationMode(reduced: true, active: true)
        XCTAssertEqual(player.text, "99")
        XCTAssertEqual(player.displayColumns, try PuzzleAlphabet.width(of: "99"))
        XCTAssertEqual(player.board.visibleCells, try TileWordmarkMotion.Board(text: "99", columns: 8).visibleCells)
        try player.show("1000000")
        XCTAssertEqual(player.board.visibleCells, Set(try PuzzleAlphabet.cells(for: "1000000")))
        XCTAssertNil(player.segment)
        XCTAssertEqual(player.displayColumns, try PuzzleAlphabet.width(of: "1000000"))
        player.setPresentationMode(reduced: true, active: false)
    }

    @MainActor func testFixedHeaderStillRejectsOversizedTextWithoutChangingState() throws {
        let player = TileWordmarkPlayer()
        let before = player.board
        XCTAssertThrowsError(try player.show("HELLO WORLD"))
        XCTAssertEqual(player.board, before)
        XCTAssertEqual(player.text, "TILES")
    }
}
