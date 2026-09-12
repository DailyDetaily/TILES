import SwiftUI
import UniformTypeIdentifiers
import OrganizerCore

/// The three entry points stage a scope; none of them moves or analyzes content.
struct ScopeSelectionView: View {
    @ObservedObject var scope: ScopeSelectionModel
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var owner: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @State private var dragOver = false
    @State private var loadingDrop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("무엇을 정리할까요?").font(Theme.body(19)).fontWeight(.semibold)
                Spacer()
                if scope.isScanning { ProgressView().controlSize(.small).accessibilityLabel("정리 대상 확인 중") }
            }
            HStack(spacing: 10) {
                modeTile(.files, title: "파일", detail: "직접 고르기", icon: "doc.on.doc", number: "01")
                modeTile(.folders, title: "선택 폴더", detail: "위치를 골라서", icon: "folder", number: "02")
                modeTile(.all, title: "전체", detail: "연결한 위치 모두", icon: "square.grid.2x2", number: "03")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if scope.mode == .files { files } else { folders }
                    if let message = scope.error ?? scope.notice {
                        Label(message, systemImage: scope.error == nil ? "info.circle" : "exclamationmark.circle")
                            .font(Theme.body(11)).foregroundStyle(Theme.gray).fixedSize(horizontal: false, vertical: true)
                    }
                    if scope.preservedFolderCount > 0 {
                        Text("기존 폴더 \(scope.preservedFolderCount)개는 구성 그대로 유지합니다.")
                            .font(Theme.body(11)).foregroundStyle(Theme.gray)
                    }
                }.padding(.vertical, 2)
            }
            HStack {
                Text(scope.isScanning ? "대상 파일을 확인하고 있습니다…" : scope.canPreview ? "범위가 준비됐어요. 정리안을 확인하세요." : "범위를 고르면 정리할 파일 수를 알려드려요.")
                    .font(Theme.body(11)).foregroundStyle(Theme.gray)
                Spacer(minLength: 4)
                if review.pendingCount > 0 {
                    Menu("나중에 정리 · \(review.pendingCount)") {
                        ForEach(review.batches) { batch in
                            Button("\(batch.origin) · \(batch.files.count)개") { review.openBatch(batch) }
                        }
                    }.font(Theme.body(11)).fixedSize()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dragOver ? Theme.blue.opacity(0.08) : Color.clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragOver, perform: receive)
        .disabled(owner.busy)
        .accessibilityIdentifier("scope-selection")
    }

    private func modeTile(_ mode: OrganizationScopeMode, title: String, detail: String, icon: String, number: String) -> some View {
        let selected = scope.mode == mode
        return Button {
            withAnimation(reduceMotion ? nil : .timingCurve(0.22, 0, 0.18, 1, duration: 0.18)) { scope.setMode(mode) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 22, weight: .light))
                    Spacer()
                    if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                }
                Spacer(minLength: 0)
                Text(title).font(Theme.body(16)).fontWeight(.semibold)
                Text(detail).font(Theme.body(10)).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.gray)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .aspectRatio(1, contentMode: .fit)
            .foregroundStyle(selected ? Color.white : Color.black)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black).matchedGeometryEffect(id: "scope-choice", in: selection)
                } else { RoundedRectangle(cornerRadius: 8).fill(Color.white) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
        .accessibilityIdentifier("scope-mode-\(number)")
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 10) {
            if scope.selectedFiles.isEmpty {
                VStack(spacing: 10) {
                    Text(dragOver ? "여기에 놓으세요" : "파일을 이곳에 놓으세요").font(Theme.body(15)).fontWeight(.medium)
                    Text("필요한 파일만 골라 한 번에 정리합니다.").font(Theme.body(11)).foregroundStyle(Theme.gray)
                    Button("파일 선택…", action: scope.chooseFiles).buttonStyle(PillStyle())
                        .accessibilityIdentifier("scope-choose-files")
                }.frame(maxWidth: .infinity, minHeight: 104).padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    Text("선택한 파일 \(scope.selectedFiles.count)개").font(Theme.body(12)).fontWeight(.medium)
                    Spacer()
                    Button("파일 추가…", action: scope.chooseFiles).buttonStyle(.plain).font(Theme.body(11))
                }
                LazyVStack(spacing: 6) {
                    ForEach(scope.selectedFiles, id: \.path) { url in
                        HStack(spacing: 10) {
                            Image(systemName: "doc").foregroundStyle(Theme.gray)
                            Text(url.lastPathComponent).font(Theme.body(12)).lineLimit(1).help(url.path)
                            Spacer()
                            Button { scope.removeFile(url) } label: {
                                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24)
                            }.buttonStyle(.plain).accessibilityLabel("\(url.lastPathComponent) 선택에서 제외")
                        }.padding(.horizontal, 12).padding(.vertical, 5).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(scope.mode == .all ? "전체에 포함할 위치" : "정리할 위치").font(Theme.body(12)).fontWeight(.medium)
                Spacer()
                Button("폴더 추가…", action: scope.addFolders).buttonStyle(.plain).font(Theme.body(11))
                    .accessibilityIdentifier("scope-add-folders")
            }
            if scope.mode == .all {
                Text("연결한 위치만 포함합니다. 아래에서 뺄 수 있어요.")
                    .font(Theme.body(11)).foregroundStyle(Theme.gray)
            }
            LazyVStack(spacing: 6) {
                ForEach(scope.locations) { location in
                    Button { scope.toggleLocation(location.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: location.selected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(location.selected ? Color.black : Theme.gray)
                            Image(systemName: location.name == "바탕화면" ? "desktopcomputer" : location.name == "다운로드" ? "arrow.down.to.line" : "folder")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name).font(Theme.body(12)).fontWeight(.medium)
                                PathText(path: location.path)
                            }
                            Spacer(minLength: 0)
                            if !location.isConnected { Text("연결").font(Theme.body(10)).foregroundStyle(Theme.gray) }
                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(location.selected ? Theme.blue.opacity(0.14) : Color.white, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel(location.name)
                        .accessibilityValue(location.selected ? "포함" : "제외")
                        .accessibilityIdentifier("scope-location-\(location.name)")
                }
            }
            Toggle("하위 폴더의 파일도 포함", isOn: $scope.includeSubfolders)
                .toggleStyle(.checkbox).font(Theme.body(11)).padding(.top, 2)
                .accessibilityIdentifier("scope-recursive")
            Text(scope.includeSubfolders ? "일반 하위 폴더의 파일을 포함합니다. 앱·코드 프로젝트 내부는 유지합니다." : "선택한 위치 바로 안의 파일을 확인합니다. 기존 폴더는 유지합니다.")
                .font(Theme.body(10)).foregroundStyle(Theme.gray).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard !owner.busy, !loadingDrop else { return false }
        loadingDrop = true
        let accepted = ReviewFileDrop.load(providers) { result in
            loadingDrop = false
            switch result {
            case .success(let urls): scope.setMode(.files); scope.addFiles(urls)
            case .failure(let error): owner.error = error.localizedDescription
            }
        }
        if !accepted { loadingDrop = false }
        return accepted
    }
}
