import SwiftUI
import OrganizerMotion

/// Numeric typography uses the same pieces and route as the header wordmark.
struct PuzzleCounter: View {
    var value: String
    var size: CGFloat
    var ink: Color
    var paper: Color
    var maximumWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var player: TileWordmarkPlayer

    init(value: String, size: CGFloat, ink: Color = .black, paper: Color = .white,
         maximumWidth: CGFloat? = nil) {
        self.value = value
        self.size = size
        self.ink = ink
        self.paper = paper
        self.maximumWidth = maximumWidth
        let text = (try? PuzzleAlphabet.normalized(value)) ?? "-"
        let width = (try? PuzzleAlphabet.width(of: text)) ?? 3
        _player = StateObject(wrappedValue: TileWordmarkPlayer(text: text.isEmpty ? "-" : text,
                                                             columns: max(5, width + 1),
                                                             allowsExpansion: true))
    }

    var body: some View {
        let width = CGFloat(max(1, player.displayColumns) - 1) * TileWordmarkFace.pitch + TileWordmarkFace.side
        let scale = min(max(0, size) * 0.78 / 29, max(0, maximumWidth ?? .infinity) / width)
        let boardHeight = CGFloat(TileWordmarkMotion.rows - 1) * TileWordmarkFace.pitch + TileWordmarkFace.side
        let faceHeight = boardHeight * scale
        let baselineOffset = TileWordmarkFace.pitch * scale / 2
        let lineHeight = max(0, size) * 1.08
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: player.segment == nil)) { context in
            TileWordmarkFace(blocks: player.board.blocks, text: value, columns: player.displayColumns,
                             ink: ink, paper: paper, beat: player.segment?.beat,
                             progress: player.segment?.progress(at: context.date) ?? 1)
        }
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width * scale, height: faceHeight, alignment: .topLeading)
        .offset(y: -baselineOffset)
        .frame(height: lineHeight)
        .alignmentGuide(.firstTextBaseline) { dimensions in
            dimensions[.bottom] - (lineHeight - faceHeight) / 2 - baselineOffset
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value)
        .onAppear {
            player.setPresentationMode(reduced: reduced, active: scenePhase == .active)
            try? player.show(value)
        }
        .onChange(of: value) { _, text in try? player.show(text) }
        .onChange(of: reduced) { _, flag in
            player.setPresentationMode(reduced: flag, active: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            player.setPresentationMode(reduced: reduced, active: phase == .active)
        }
        .onDisappear { player.setPresentationMode(reduced: reduced, active: false) }
    }
}
