import SwiftUI
import OrganizerMotion

@MainActor final class PuzzleMotionController: ObservableObject {
    @Published private(set) var board = PuzzleBoard.resting(page: .organize, expanded: false)
    @Published private(set) var isRouting = false
    private var destination = PuzzleBoard.resting(page: .organize, expanded: false)
    private var runner: Task<Void, Never>?
    private var initialized = false
    private var generation = 0

    func request(page: PuzzlePage, expanded: Bool, phase: PuzzlePhase = .intake, reduced: Bool) {
        destination = .resting(page: page, expanded: expanded, phase: phase)
        if reduced || !initialized {
            initialized = true; generation += 1; runner?.cancel(); runner = nil
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { board = destination; isRouting = false }
            return
        }
        guard runner == nil, board != destination else { return }
        generation += 1
        let token = generation
        isRouting = true
        runner = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == token, self.board != self.destination {
                let plannedDestination = self.destination
                let route = PuzzleRoute.beats(from: self.board, to: plannedDestination)
                guard !route.isEmpty else { break }
                for beat in route {
                    // A landing is the safe retarget point: never cut diagonally
                    // across another tile halfway through an existing slide.
                    guard !Task.isCancelled, self.generation == token else { return }
                    if self.destination != plannedDestination { break }
                    withAnimation(.timingCurve(0.22, 0.0, 0.18, 1.0, duration: beat.duration)) { self.board = beat.board }
                    do { try await Task.sleep(for: .seconds(beat.duration)) } catch { return }
                }
            }
            guard self.generation == token else { return }
            self.isRouting = false; self.runner = nil
        }
    }
    func stop() { generation += 1; runner?.cancel(); runner = nil; isRouting = false }
}
