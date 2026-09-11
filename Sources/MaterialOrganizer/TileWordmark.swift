import SwiftUI
import OrganizerMotion

/// Slides keep a square face. A turn projects that face around its horizontal
/// axis with perspective; the visible face changes color only when it passes the edge.
struct TileWordmarkFace: View {
    var blocks: [TileWordmarkMotion.Block]
    var text = TileWordmarkCue.tile.rawValue
    var columns = TileWordmarkMotion.columns
    var ink: Color = .black
    var paper: Color = .white
    var beat: TileWordmarkMotion.Beat?
    var progress: Double = 1
    static let side: CGFloat = 5
    static let pitch: CGFloat = 6
    var size: CGSize {
        CGSize(width: CGFloat(columns - 1) * Self.pitch + Self.side,
               height: CGFloat(TileWordmarkMotion.rows - 1) * Self.pitch + Self.side)
    }

    var body: some View {
        Canvas { context, _ in
            func square(_ x: CGFloat, _ y: CGFloat) {
                context.fill(Path(CGRect(x: x * Self.pitch, y: y * Self.pitch,
                                         width: Self.side, height: Self.side)), with: .color(ink))
            }
            for block in blocks {
                if let beat, block.id == beat.blockID { continue }
                square(CGFloat(block.cell.column), CGFloat(block.cell.row))
            }
            if let beat {
                let p = CGFloat(min(1, max(0, progress)))
                if beat.kind == .slide {
                    square(CGFloat(beat.from.column) + CGFloat(beat.to.column - beat.from.column) * p,
                           CGFloat(beat.from.row) + CGFloat(beat.to.row - beat.from.row) * p)
                } else {
                    let angle = CGFloat.pi * p
                    let tilt = sin(angle)
                    let half = Self.side / 2
                    let center = CGPoint(x: CGFloat(beat.to.column) * Self.pitch + half,
                                         y: CGFloat(beat.to.row) * Self.pitch + half)
                    // Rotate around X: the upper/lower edges trade places.
                    // Perspective makes the nearer edge wider, within the cell pitch.
                    let cameraDistance = Self.side * 3.2
                    let corners: [CGPoint] = [
                        CGPoint(x: -half, y: -half), CGPoint(x: half, y: -half),
                        CGPoint(x: half, y: half), CGPoint(x: -half, y: half)
                    ].map { corner in
                        let depth = corner.y * tilt
                        let perspective = cameraDistance / (cameraDistance - depth)
                        return CGPoint(x: center.x + corner.x * perspective,
                                       y: center.y + corner.y * cos(angle) * perspective)
                    }
                    let face = Path { path in
                        path.addLines(corners)
                        path.closeSubpath()
                    }
                    let black = beat.kind == .flipOn ? p >= 0.5 : p < 0.5
                    let turnLight = Double(abs(tilt))
                    context.fill(face, with: .color(black ? ink : paper))
                    context.fill(face, with: .color(black ? paper.opacity(0.10 * turnLight) : ink.opacity(0.14 * turnLight)))
                    if !black {
                        context.stroke(face, with: .color(ink.opacity(0.14 * turnLight)), lineWidth: 0.25)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

@MainActor final class TileWordmarkPlayer: ObservableObject {
    struct Segment {
        let beat: TileWordmarkMotion.Beat
        let startedAt: Date
        func progress(at date: Date) -> Double {
            let p = min(1, max(0, date.timeIntervalSince(startedAt) / beat.duration))
            return p * p * (3 - 2 * p)
        }
    }

    @Published private(set) var board: TileWordmarkMotion.Board
    @Published private(set) var segment: Segment?
    @Published private(set) var text: String
    @Published private(set) var displayColumns: Int
    private let allowsExpansion: Bool
    private var destination: String
    private var returnDelay: Double?
    private var runner: Task<Void, Never>?
    private var returnTask: Task<Void, Never>?
    private var revision = 0
    private var reduced = false
    private var active = true

    init(text: String = TileWordmarkCue.tile.rawValue, columns: Int = TileWordmarkMotion.columns, allowsExpansion: Bool = false) {
        board = try! .init(text: text, columns: columns)
        self.text = text
        displayColumns = try! PuzzleAlphabet.width(of: text)
        self.allowsExpansion = allowsExpansion
        destination = text
    }

    func show(_ text: String, returnAfter: Double? = nil) throws {
        let normalized = try PuzzleAlphabet.normalized(text)
        // Validate before changing any state; generic callers can supply text.
        let width = try PuzzleAlphabet.width(of: normalized)
        let capacity = allowsExpansion ? max(board.columns, width + 1) : board.columns
        _ = try TileWordmarkMotion.Board(text: normalized, columns: capacity)
        board.reserveColumns(capacity)
        displayColumns = max(displayColumns, width)
        revision += 1
        returnTask?.cancel()
        returnTask = nil
        destination = normalized
        self.text = normalized
        returnDelay = returnAfter
        if reduced || !active {
            finishImmediately()
            scheduleReturn()
        } else {
            startRunner()
        }
    }

    func setPresentationMode(reduced: Bool, active: Bool) {
        guard self.reduced != reduced || self.active != active else { return }
        self.reduced = reduced
        self.active = active
        returnTask?.cancel()
        returnTask = nil
        if reduced || !active { finishImmediately() }
        if active {
            if reduced { scheduleReturn() } else { startRunner() }
        }
    }

    private func startRunner() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let plannedDestination = self.destination
                    let route = try TileWordmarkMotion.route(from: self.board, to: plannedDestination,
                                                             seed: UInt64.random(in: .min ... .max))
                    // Keep a stable drawing extent throughout a route, including
                    // its staging cells. Shrink only after the number has settled.
                    let furthest = route.map { max($0.from.column, $0.to.column) + 1 }.max() ?? 0
                    self.displayColumns = max(self.displayColumns, furthest)
                    for beat in route {
                        try Task.checkCancellation()
                        if self.destination != plannedDestination { break }
                        self.segment = Segment(beat: beat, startedAt: .now)
                        try await Task.sleep(for: .seconds(beat.duration))
                        try Task.checkCancellation()
                        self.board.apply(beat)
                        self.segment = nil
                    }
                    if self.destination == plannedDestination { break }
                }
            } catch { return }
            self.runner = nil
            self.displayColumns = (try? PuzzleAlphabet.width(of: self.destination)) ?? self.board.columns
            self.scheduleReturn()
        }
    }

    private func finishImmediately() {
        runner?.cancel()
        runner = nil
        segment = nil
        board = try! .init(text: destination, columns: board.columns)
        displayColumns = try! PuzzleAlphabet.width(of: destination)
    }

    private func scheduleReturn() {
        guard active, runner == nil, let delay = returnDelay, destination != TileWordmarkCue.tile.rawValue else { return }
        let token = revision
        returnTask?.cancel()
        returnTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.revision == token else { return }
            try? self.show(TileWordmarkCue.tile.rawValue)
        }
    }
}

struct TileWordmark: View {
    var cue: TileWordmarkCue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var player = TileWordmarkPlayer()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: player.segment == nil)) { context in
            TileWordmarkFace(blocks: player.board.blocks, text: player.text, columns: player.board.columns,
                             beat: player.segment?.beat,
                             progress: player.segment?.progress(at: context.date) ?? 1)
        }
        // Keep the five-row wordmark at its original position while the
        // six-row grid accommodates taller symbols and the sliding routes.
        .offset(y: -TileWordmarkFace.pitch / 2)
        .frame(height: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("tile-puzzle-wordmark")
        .help(cue.explanation)
        .onAppear {
            player.setPresentationMode(reduced: reduceMotion, active: scenePhase == .active)
            if cue != .tile || scenePhase == .active { show(cue == .tile ? .hello : cue) }
        }
        .onHover { entered in
            if entered && cue == .tile && scenePhase == .active && player.text == TileWordmarkCue.tile.rawValue { show(.hello) }
        }
        .onChange(of: cue) { _, value in show(value) }
        .onChange(of: reduceMotion) { _, value in
            player.setPresentationMode(reduced: value, active: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            player.setPresentationMode(reduced: reduceMotion, active: phase == .active)
            if phase == .active && cue == .tile && player.text == TileWordmarkCue.tile.rawValue { show(.hello) }
        }
        .onDisappear { player.setPresentationMode(reduced: reduceMotion, active: false) }
    }

    private func show(_ cue: TileWordmarkCue) {
        try? player.show(cue.rawValue, returnAfter: cue.returnDelay)
    }
}
