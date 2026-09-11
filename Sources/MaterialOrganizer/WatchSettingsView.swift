import SwiftUI
import OrganizerCore

struct WatchSettingsView: View {
    @ObservedObject var watch: FolderWatchService
    @ObservedObject var review: ProjectReviewModel
    private let delayOptions: [TimeInterval] = [60, 300, 600, 1_800, 3_600, 86_400]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { watch.configuration.enabled }, set: watch.setEnabled)) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("폴더 감시").font(Theme.body(15)).fontWeight(.medium)
                    Text("안정된 파일을 정리 추천 대기열에 모읍니다.")
                        .font(Theme.body(12)).foregroundStyle(Theme.gray)
                }
            }
            .toggleStyle(.switch).tint(Theme.blue)
            .disabled(!watch.isLoaded || watch.configuration.folderPath == nil)
            .accessibilityIdentifier("folder-watch-enabled")

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(watch.configuration.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "감시할 폴더를 선택하세요")
                        .font(Theme.body(13))
                    if let path = watch.configuration.folderPath { PathText(path: path) }
                    else { Text("바탕화면이나 받은 자료 폴더를 직접 선택할 수 있습니다.").font(Theme.body(12)).foregroundStyle(Theme.gray) }
                }
                Spacer(minLength: 12)
                Button(watch.configuration.folderPath == nil ? "폴더 선택…" : "폴더 변경…", action: watch.chooseFolder)
                    .buttonStyle(PillStyle(filled: false)).disabled(!watch.isLoaded)
                    .accessibilityIdentifier("folder-watch-choose")
            }.padding(14).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 16) {
                Text("마지막 변경 후 기다리기").font(Theme.body(13))
                Spacer()
                Picker("대기 시간", selection: Binding(get: { watch.configuration.waitInterval }, set: watch.setDelay)) {
                    ForEach(delayOptions, id: \.self) { seconds in Text(delayName(seconds)).tag(seconds) }
                    if !delayOptions.contains(watch.configuration.waitInterval) {
                        Text(delayName(watch.configuration.waitInterval)).tag(watch.configuration.waitInterval)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 140).disabled(!watch.isLoaded)
                .accessibilityIdentifier("folder-watch-delay")
            }
            Text("선택한 폴더 바로 안의 일반 파일만 확인합니다. 앱이 열려 있을 때만 동작하며, 파일은 자동으로 이동하지 않습니다.")
                .font(Theme.body(12)).foregroundStyle(Theme.gray).lineSpacing(3)

            HStack(alignment: .center, spacing: 12) {
                if watch.isScanning { ProgressView().controlSize(.small) }
                Text(watch.status).font(Theme.body(12)).foregroundStyle(Theme.gray)
                    .accessibilityIdentifier("folder-watch-status")
                Spacer(minLength: 4)
            }
            HStack(spacing: 12) {
                Button("지금 확인", action: watch.scanNow).buttonStyle(PillStyle(filled: false))
                    .disabled(!watch.configuration.enabled || watch.isScanning || !watch.isLoaded)
                    .accessibilityIdentifier("folder-watch-refresh")
                Button(review.pendingCount > 0 ? "검토 대기열 \(review.pendingCount)개" : "검토 대기열 열기") {
                    review.openPending(presentPanel: true)
                }
                .buttonStyle(PillStyle(filled: false))
                .accessibilityIdentifier("folder-watch-review")
                Spacer()
                if watch.notificationsAuthorized {
                    Label("알림 허용됨", systemImage: "bell.badge").font(Theme.body(12)).foregroundStyle(Theme.gray)
                } else {
                    Button("알림 허용…", action: watch.requestNotificationAuthorization)
                        .buttonStyle(PillStyle(filled: false)).accessibilityIdentifier("folder-watch-notifications")
                }
            }
            if watch.pendingCount > 0 {
                Text("파일 \(watch.pendingCount)개를 검토 대기열에 전달할 준비가 됐습니다.")
                    .font(Theme.body(12)).foregroundStyle(Theme.gray)
            }
        }.accessibilityIdentifier("folder-watch-settings")
    }

    private func delayName(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 { return "\(Int(seconds / 86_400))일" }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600))시간" }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))분" }
        return "\(Int(seconds))초"
    }
}
