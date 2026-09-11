import AppKit
import Combine

/// Bare native buttons sit outside the shelf, without a shared background bar.
@MainActor final class FolderDockControls: NSView {
    static let height: CGFloat = 28
    private let state: FolderOverlayState
    private var buttons: [FolderOverlayButton] = []
    private var observation: AnyCancellable?
    private var updatePending = false
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    init(state: FolderOverlayState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("폴더 Dock 동작")
        observation = state.objectWillChange.sink { [weak self] _ in
            guard let self, !self.updatePending else { return }; self.updatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.updatePending = false; self.updateContents()
            }
        }
        updateContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateContents() }
    private func updateContents() {
        window?.ignoresMouseEvents = state.dragging
        buttons.forEach { $0.removeFromSuperview() }; buttons = []
        var actions: [(String, CGFloat, () -> Void)] = []
        if state.mode == .editing {
            actions = [("기본값", 60, state.resetLayout), ("완료", 48, state.finishEditing)]
        } else {
            if !state.dragging && state.mode != .moving && state.mode != .preparing {
                if state.mode == .success { actions.append(("폴더 열기", 84, state.openFolder)) }
                if state.canUndo { actions.append(("되돌리기", 84, state.undo)) }
                if state.mode == .failure { actions.append(("설정 및 내역", 132, state.connect)) }
            }
        }
        if state.expanded && state.mode != .editing && !state.dragging && state.mode != .moving {
            actions.append(("닫기", 48, state.close))
        }
        let total = actions.reduce(CGFloat.zero) { $0 + $1.1 } + CGFloat(max(0, actions.count - 1)) * 8
        var x = (bounds.width - total) / 2
        for (name, width, action) in actions {
            let button = FolderOverlayButton(title: name, action: action)
            button.frame = .init(x: x, y: 2, width: width, height: 24)
            addSubview(button); buttons.append(button); x += width + 8
        }
        window?.ignoresMouseEvents = state.dragging || actions.isEmpty
    }
}
