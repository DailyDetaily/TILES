import AppKit
import SwiftUI

/// Monochrome 3×3 status icon: a filled T with transparent empty cells.
private let menuBarPuzzleIcon: NSImage = {
    let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { bounds in
        NSColor.black.setFill()
        let inset: CGFloat = 1
        let gap: CGFloat = 1.25
        let tile = (min(bounds.width, bounds.height) - inset * 2 - gap * 2) / 3
        let filledTiles = [(0, 0), (1, 0), (2, 0), (1, 1), (1, 2)]
        func tileRect(column columnIndex: Int, row rowIndex: Int) -> NSRect {
            let column = CGFloat(columnIndex)
            let row = CGFloat(rowIndex)
            return NSRect(x: inset + column * (tile + gap),
                          y: inset + row * (tile + gap),
                          width: tile, height: tile)
        }
        for (column, row) in filledTiles {
            NSBezierPath(roundedRect: tileRect(column: column, row: row),
                         xRadius: 0.9, yRadius: 0.9).fill()
        }
        return true
    }
    icon.isTemplate = true
    return icon
}()

@main enum MaterialOrganizerEntry {
    @MainActor static func main() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--folder-overlay-agent"), args.indices.contains(index + 1) {
            FolderOverlayAgent.run(nonce: args[index + 1])
        } else { MaterialOrganizerApp.main() }
    }
}

struct MaterialOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    @StateObject private var review: ProjectReviewModel
    @StateObject private var watch: FolderWatchService
    init() {
        Theme.registerFonts()
        let model = AppModel()
        let review = ProjectReviewModel(owner: model)
        let watch = FolderWatchService(stateDirectory: model.stateDirectory, isDemo: model.isDemo)
        watch.onReady = { [weak review] urls, origin in review?.enqueueWatchedFiles(urls, origin: origin) ?? false }
        watch.onOpenReview = { [weak review] in review?.openPending(presentPanel: true) }
        _model = StateObject(wrappedValue: model)
        _review = StateObject(wrappedValue: review)
        _watch = StateObject(wrappedValue: watch)
    }
    var body: some Scene {
        Window("TILES", id: "main") {
            OrganizerMainWindow(model: model, review: review, watch: watch, delegate: delegate)
                .frame(minWidth: 1060, minHeight: 688)
                .preferredColorScheme(.light)

        }
        .defaultSize(width: 1280, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("정리할 파일 선택…") { model.chooseFile() }.keyboardShortcut("o").disabled(model.busy)
                Button("폴더 전체 정리…") { model.showFolderBatch = true; model.page = .organize }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
                Button("다시 분석") { model.analyze() }.keyboardShortcut("r").disabled(model.busy || !model.showFolderBatch || model.sources.isEmpty || !model.overlayDestinationConnected)
            }
        }
        MenuBarExtra {
            OrganizerStatusMenu(model: model, review: review, watch: watch)
        } label: {
            Image(nsImage: menuBarPuzzleIcon)
                .accessibilityLabel("TILES")
        }
        .menuBarExtraStyle(.menu)
    }
}
private struct OrganizerMainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var watch: FolderWatchService
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView(model: model, review: review, watch: watch).onAppear {
            let action = openWindow
            model.openMainWindow = { action(id: "main") }
            delegate.model = model
            delegate.configure(review: review, watch: watch)
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            guard oldValue !== model else { return }
            overlay?.shutdown()
            if let model { overlay = FolderOverlayHost(model: model) }
        }
    }
    private var overlay: FolderOverlayHost?
    private var reviewPanel: ProjectReviewPanelController?
    private weak var review: ProjectReviewModel?
    private weak var watch: FolderWatchService?
    func configure(review: ProjectReviewModel, watch: FolderWatchService) {
        self.review = review; self.watch = watch
        if reviewPanel == nil { reviewPanel = ProjectReviewPanelController(review: review) }
        model?.openProjectReviewPanel = { [weak self] in self?.reviewPanel?.show() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true { model?.error = "진행 중인 작업을 중단하거나 완료한 뒤 앱을 종료해 주세요."; return .terminateCancel }
        return .terminateNow
    }
    // The menu bar remains the entry point after the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        watch?.shutdown(); review?.preserveOnClose(); reviewPanel?.close()
        overlay?.shutdown(); model?.releaseFolderAccess()
    }
}
