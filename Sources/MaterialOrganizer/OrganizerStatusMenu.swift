import AppKit
import SwiftUI

/// Uses the same AppModel as the main window; the display process never creates a menu item.
struct OrganizerStatusMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var watch: FolderWatchService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("TILES 열기") { showMain(.organize) }
        Button("확인 대기 \(review.pendingCount)개") { review.openPending(presentPanel: true) }.disabled(model.busy)
        Button("정리 내역") { showMain(.history) }
        Divider()
        Toggle("상단 드롭 영역 켜기", isOn: Binding(get: { model.folderOverlayEnabled }, set: model.setFolderOverlayEnabled))
        Button(model.folderDockEditing ? "위치·크기 편집 완료" : "위치·크기 편집…") {
            model.setFolderDockEditing(!model.folderDockEditing)
        }.disabled(model.busy)
        if watch.configuration.folderPath != nil {
            Toggle("감시 폴더 확인", isOn: Binding(get: { watch.configuration.enabled }, set: watch.setEnabled))
        }
        Button("감시 폴더 설정…") { showMain(.rules) }
        Menu("폴더 연결") {
            Button("원본 폴더 연결…") { showMain(.rules); model.addFolders() }
            Button("정리 위치 연결…") { showMain(.rules); model.chooseDestination() }
        }.disabled(model.busy)
        Divider()
        Button("TILES 종료") { NSApp.terminate(nil) }.keyboardShortcut("q").disabled(model.busy)
    }
    private func showMain(_ page: AppModel.Page) {
        model.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
