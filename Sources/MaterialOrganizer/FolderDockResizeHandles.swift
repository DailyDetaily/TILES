import AppKit
import OrganizerCore

/// Edit-only chrome lives beside the clipped shelf, on its padded transparent canvas.
@MainActor final class FolderDockResizeHandles: NSView {
    private let state: FolderOverlayState
    private var dockBounds = CGRect.zero
    private var editingGesture = false
    private let glass = NSVisualEffectView()
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    init(state: FolderOverlayState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.autoresizingMask = [.width, .height]; addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(dockBounds: CGRect) {
        self.dockBounds = dockBounds
        updateMask()
        window?.invalidateCursorRects(for: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateMask()
    }
    private func corner(at point: CGPoint) -> FolderDockGeometry.Corner? {
        FolderDockGeometry.corner(at: .init(x: point.x - dockBounds.minX, y: point.y - dockBounds.minY),
                                  size: dockBounds.size)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, state.mode == .editing,
              corner(at: convert(point, from: superview)) != nil else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard state.mode == .editing, !state.dragging,
              let corner = corner(at: convert(event.locationInWindow, from: nil)) else { return }
        editingGesture = true; state.beginEdit(NSEvent.mouseLocation, corner)
    }
    override func mouseDragged(with event: NSEvent) {
        guard editingGesture else { return }; state.changeEdit(NSEvent.mouseLocation)
    }
    override func mouseUp(with event: NSEvent) {
        guard editingGesture else { return }; editingGesture = false; state.endEdit()
    }
    override func resetCursorRects() {
        guard state.mode == .editing else { return }
        for corner in FolderDockGeometry.Corner.allCases {
            let rect = FolderDockGeometry.handlePath(corner: corner, size: dockBounds.size)
                .boundingBoxOfPath.insetBy(dx: -FolderDockGeometry.handleHitWidth / 2,
                                          dy: -FolderDockGeometry.handleHitWidth / 2)
                .offsetBy(dx: dockBounds.minX, dy: dockBounds.minY)
            addCursorRect(rect, cursor: .crosshair)
        }
    }
    private func updateMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        glass.frame = bounds
        let dockBounds = self.dockBounds
        // Match the shelf's material, including system appearance and transparency settings.
        glass.maskImage = NSImage(size: bounds.size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: dockBounds.minX, y: dockBounds.minY)
            context.setLineWidth(FolderDockGeometry.handleLineWidth)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.setStrokeColor(NSColor.white.cgColor)
            for corner in FolderDockGeometry.Corner.allCases {
                context.addPath(FolderDockGeometry.handlePath(corner: corner, size: dockBounds.size))
                context.strokePath()
            }
            return true
        }
    }
}
