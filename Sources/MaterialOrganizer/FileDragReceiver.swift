import AppKit

/// Receives only drags entering this actual view. It does not observe global drag starts.
@MainActor final class FileDragReceiver: NSView, NSSpringLoadingDestination {
    var entered: ((NSDraggingInfo) -> NSDragOperation)?
    var updated: ((NSDraggingInfo) -> NSDragOperation)?
    var exited: ((NSDraggingInfo?) -> Void)?
    var prepare: ((NSDraggingInfo) -> Bool)?
    var perform: ((NSDraggingInfo) -> Bool)?
    var ended: ((NSDraggingInfo) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return entered?(sender) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return updated?(sender) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        exited?(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { prepare?(sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { perform?(sender) ?? false }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        ended?(sender)
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    func springLoadingEntered(_ draggingInfo: NSDraggingInfo) -> NSSpringLoadingOptions { [] }
    func springLoadingUpdated(_ draggingInfo: NSDraggingInfo) -> NSSpringLoadingOptions { [] }
    func springLoadingActivated(_ activated: Bool, draggingInfo: NSDraggingInfo) {}
    func springLoadingHighlightChanged(_ draggingInfo: NSDraggingInfo) {}
}

@MainActor final class FolderOverlayPanel: NSPanel {
    var allowsEditMargin = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The controller already constrains the visible shelf. Its transparent edit
        // margin may cross the menu-bar boundary without shifting the shelf itself.
        allowsEditMargin ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
