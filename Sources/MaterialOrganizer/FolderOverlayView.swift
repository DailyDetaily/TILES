import AppKit
import SwiftUI
import Combine
import OrganizerCore
import UniformTypeIdentifiers

@MainActor final class FolderOverlayState: ObservableObject {
    enum Mode { case hidden, editing, preparing, folders, moving, success, failure, undone }
    @Published var mode: Mode = .hidden
    @Published var filename = ""
    @Published var detail = ""
    @Published var targets: [FolderDropTarget] = []
    var candidates: [FolderRecommendation] { targets.compactMap(\.candidate) }
    @Published var hoveredID: String?
    @Published var dragging = false
    @Published var canUndo = false
    @Published var folderPreviews: [String: [FolderContentPreview]] = [:]
    @Published var editingFolders: [FolderRecommendation] = []
    var close: () -> Void = {}
    var connect: () -> Void = {}
    var openFolder: () -> Void = {}
    var undo: () -> Void = {}
    var finishEditing: () -> Void = {}
    var resetLayout: () -> Void = {}
    var beginEdit: (CGPoint, FolderDockGeometry.Corner?) -> Void = { _, _ in }
    var changeEdit: (CGPoint) -> Void = { _ in }
    var endEdit: () -> Void = {}
    var expanded: Bool { mode != .hidden }
}

/// Folder icons and centered names, with a quiet instruction at the top edge.
@MainActor final class FolderOverlayView: NSView {
    private let state: FolderOverlayState
    private var observation: AnyCancellable?
    private var updatePending = false
    private let glass = NSVisualEffectView()
    private let instruction = overlayLabel(11)
    private var cards: [FolderDockItem] = []
    private var editingGesture = false
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    init(state: FolderOverlayState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true; layer?.borderWidth = 0
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.autoresizingMask = [.width, .height]; addSubview(glass)
        instruction.alignment = .center; instruction.textColor = .secondaryLabelColor
        addSubview(instruction)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("folder-dock")
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
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateContents() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return state.mode == .editing && result != nil ? self : result
    }
    override func mouseDown(with event: NSEvent) {
        guard state.mode == .editing, !state.dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !cards.contains(where: { $0.frame.contains(point) }) else { return }
        editingGesture = true; state.beginEdit(NSEvent.mouseLocation, nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard editingGesture else { return }; state.changeEdit(NSEvent.mouseLocation)
    }
    override func mouseUp(with event: NSEvent) {
        guard editingGesture else { return }; editingGesture = false; state.endEdit()
    }
    override func resetCursorRects() {
        guard state.mode == .editing else { return }; addCursorRect(bounds, cursor: .openHand)
    }
    private func updateContents() {
        layer?.cornerRadius = FolderDockGeometry.cornerRadius(size: bounds.size)
        glass.frame = bounds
        instruction.isHidden = !state.expanded
        instruction.frame = .init(x: 28, y: 5, width: max(1, bounds.width - 56), height: 17)
        if state.mode == .editing {
            instruction.stringValue = "빈 곳을 잡아 이동 · 모서리로 크기 조절"
        } else if state.mode == .folders {
            instruction.stringValue = state.hoveredID.flatMap { id in
                state.targets.first { $0.id == id }.map {
                    $0 == .recommendation ? "놓으면 정리 추천을 엽니다 · 원본 유지" : "\($0.name)로 바로 이동"
                }
            } ?? "\(state.filename) · 정리 추천 또는 바로 이동 · Esc 취소"
        } else {
            instruction.stringValue = state.detail
        }
        instruction.toolTip = instruction.stringValue
        let shown: [FolderDropTarget] = state.mode == .editing
            ? [.recommendation] + state.editingFolders.prefix(2).map(FolderDropTarget.folder)
            : state.targets
        let names = shown.map(\.name), identities = shown.map(\.id)
        if !state.expanded || cards.map(\.id) != identities {
            cards.forEach { $0.removeFromSuperview() }; cards = []
            if state.expanded {
                cards = names.enumerated().map { index, name in
                    let target = shown[index], candidate = target.candidate
                    return FolderDockItem(id: identities[index], name: name,
                        primary: index <= 1, recommendation: target == .recommendation,
                        previews: state.folderPreviews[identities[index]] ?? [],
                        description: candidate.map { "\($0.id), 바로 이동. \($0.reason)" } ?? "파일을 이동하지 않고 정리 추천 검토 화면을 엽니다")
                }
                cards.forEach { addSubview($0) }
            }
        }
        let frames = FolderDockGeometry.items(size: bounds.size, count: cards.count)
        for (index, card) in cards.enumerated() {
            card.update(previews: state.folderPreviews[card.id] ?? [])
            card.frame = frames[index]; card.active = state.mode == .folders && state.hoveredID == card.id
        }
        setAccessibilityLabel(state.mode == .editing ? "폴더 Dock 위치와 크기 편집" : "폴더 Dock, \(state.filename)")
        window?.invalidateCursorRects(for: self); needsDisplay = true
    }
}

@MainActor private final class FolderDockItem: NSView {
    let id: String
    private let name: String
    private var image: NSImage
    private let primary: Bool
    private let recommendation: Bool
    private var previews: [FolderContentPreview]
    var active = false { didSet { if oldValue != active { needsDisplay = true; setAccessibilitySelected(active) } } }
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    init(id: String, name: String, primary: Bool, recommendation: Bool, previews: [FolderContentPreview], description: String) {
        self.id = id; self.name = name; self.primary = primary; self.recommendation = recommendation; self.previews = previews
        image = recommendation ? Self.reviewImage() : FrostedFolderIcon.make(primary: primary, previews: previews)
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(name), \(description)"); toolTip = description
        setAccessibilityIdentifier(recommendation ? "folder-dock-recommendation" : "folder-dock-destination:\(id)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(previews: [FolderContentPreview]) {
        guard !recommendation, self.previews != previews else { return }; self.previews = previews
        image = FrostedFolderIcon.make(primary: primary, previews: previews); needsDisplay = true
    }
    /// A review sheet shares the existing blue palette while remaining distinct from a folder.
    private static func reviewImage() -> NSImage {
        NSImage(size: .init(width: 144, height: 132), flipped: true) { _ in
            let back = NSBezierPath(roundedRect: .init(x: 28, y: 12, width: 90, height: 104), xRadius: 12, yRadius: 12)
            NSColor(srgbRed: 0.055, green: 0.23, blue: 0.49, alpha: 1).setFill(); back.fill()
            let page = NSBezierPath(roundedRect: .init(x: 18, y: 20, width: 104, height: 106), xRadius: 13, yRadius: 13)
            let top = NSColor(srgbRed: 0.17, green: 0.52, blue: 0.91, alpha: 0.97)
            let bottom = NSColor(srgbRed: 0.07, green: 0.33, blue: 0.68, alpha: 1)
            NSGradient(starting: top, ending: bottom)?.draw(in: page, angle: 90)
            NSColor.white.withAlphaComponent(0.35).setStroke(); page.lineWidth = 0.9; page.stroke()
            for (y, width) in [(48.0, 48.0), (61.0, 61.0), (74.0, 37.0)] {
                NSColor.white.withAlphaComponent(0.74).setFill()
                NSBezierPath(roundedRect: .init(x: 36, y: y, width: width, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            }
            let symbol = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            let configuration = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            symbol?.withSymbolConfiguration(configuration)?.draw(
                in: .init(x: 80, y: 87, width: 30, height: 30), from: .zero, operation: .sourceOver,
                fraction: 0.95, respectFlipped: true, hints: nil)
            return true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if active {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
            path.fill(); NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke(); path.lineWidth = 1.5; path.stroke()
        }
        let side = max(24, min(128, min(bounds.width - 26, bounds.height - 43)))
        let iconHeight = side * 132 / 144
        let top = max(0, (bounds.height - iconHeight - 43) / 2)
        image.draw(in: .init(x: (bounds.width - side) / 2, y: top, width: side, height: iconHeight),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle; paragraph.alignment = .center
        (name as NSString).draw(in: .init(x: 5, y: top + iconHeight + 8, width: bounds.width - 10, height: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .medium),
                             .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        ((recommendation ? "검토 후 선택" : "바로 이동") as NSString).draw(
            in: .init(x: 5, y: top + iconHeight + 25, width: bounds.width - 10, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }
}

@MainActor final class FolderOverlayButton: NSButton {
    private let handler: () -> Void
    override var needsPanelToBecomeKey: Bool { false }
    init(title: String, action: @escaping () -> Void) {
        handler = action; super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(invoke)
        bezelStyle = .rounded; controlSize = .small; font = .systemFont(ofSize: 11)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

@MainActor func overlayLabel(_ size: CGFloat) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: size); label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1
    label.isSelectable = false; return label
}
