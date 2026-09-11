import AppKit
import SwiftUI

/// Opened after Finder's drag session ends; it remains until the user closes it.
@MainActor final class ProjectReviewPanelController: NSObject, NSWindowDelegate {
    private let review: ProjectReviewModel
    private var panel: NSPanel?
    init(review: ProjectReviewModel) { self.review = review }

    func show() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 790, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "TILES · 정리 추천"
            window.minSize = NSSize(width: 710, height: 560)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView: ProjectReviewView(review: review, owner: review.owner)
                .preferredColorScheme(.light))
            panel = window
        }
        guard let panel else { return }
        if !panel.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: max(frame.minY, frame.maxY - panel.frame.height - 32)))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if review.owner.busy {
            review.failure = "작업을 완료하거나 중단한 뒤 닫아 주세요."
            return false
        }
        review.preserveOnClose()
        return true
    }
    func close() { panel?.orderOut(nil) }
}
