import XCTest
import OrganizerCore
import OrganizerMotion
@testable import MaterialOrganizer

final class TileWordmarkTests: XCTestCase {
    func testOnlyCompletedOperationsDisplayDone() throws {
        XCTAssertEqual(TileWordmarkCue.tile.rawValue, "TILES")
        for state in [RunState.completed, .undone] {
            XCTAssertEqual(TileWordmarkCue.completion(for: state), .done)
        }
        for state in [RunState.running, .undoing, .interrupted, .attention] {
            XCTAssertEqual(TileWordmarkCue.completion(for: state), .check)
        }
        XCTAssertEqual(TileWordmarkCue.completion(for: .failure(CancellationError())), .stop)
        XCTAssertEqual(TileWordmarkCue.completion(for: .failure(NSError(domain: "test", code: 1))), .check)
        for cue in TileWordmarkCue.allCases {
            _ = try TileWordmarkMotion.Board(text: cue.rawValue)
        }
    }

    @MainActor func testRetargetFinishesActiveMoveAndRejectsInvalidTextWithoutMutation() async throws {
        let player = TileWordmarkPlayer()
        try player.show("HELLO")
        try await Task.sleep(for: .milliseconds(70))
        try player.show("DONE")
        let expected = try TileWordmarkMotion.Board(text: "DONE").visibleCells
        for _ in 0..<150 {
            if player.segment == nil && player.board.visibleCells == expected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(player.board.visibleCells, expected)
        XCTAssertNil(player.segment)
        let before = player.board
        XCTAssertThrowsError(try player.show("안녕"))
        XCTAssertEqual(player.board, before)
        XCTAssertEqual(player.text, "DONE")
        player.setPresentationMode(reduced: false, active: false)
    }

    @MainActor func testReducedMotionAndSuspensionCancelOldReturns() async throws {
        let player = TileWordmarkPlayer()
        player.setPresentationMode(reduced: true, active: true)
        try player.show("HELLO", returnAfter: 0.05)
        XCTAssertNil(player.segment)
        try player.show("WAIT")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.text, "WAIT")
        XCTAssertEqual(player.board.visibleCells, try TileWordmarkMotion.Board(text: "WAIT").visibleCells)
        player.setPresentationMode(reduced: false, active: true)
        try player.show("DONE", returnAfter: 0.05)
        try await Task.sleep(for: .milliseconds(20))
        player.setPresentationMode(reduced: false, active: false)
        XCTAssertNil(player.segment)
        XCTAssertEqual(player.board.visibleCells, try TileWordmarkMotion.Board(text: "DONE").visibleCells)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.text, "DONE")
        player.setPresentationMode(reduced: true, active: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.text, "TILES")
        XCTAssertEqual(player.board.visibleCells, try TileWordmarkMotion.Board(text: "TILES").visibleCells)
    }
}
