import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OrganizerCore

struct FileOrganizeView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    @State private var dragOver = false
    @State private var createFolder = false
    @State private var folderName = ""
    @State private var folderParent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @State private var folderError: String?
    private var stage: Int { model.quickRun != nil ? 3 : model.quickFile != nil ? 2 : 1 }
    private var folders: [FolderRecommendation] {
        guard let selected = model.quickDestination, !model.quickFolders.contains(where: { $0.id == selected.id }) else { return model.quickFolders }
        return model.quickFolders + [selected]
    }

    var body: some View {
        VStack(spacing: 24) {
            if !embedded { steps }
            if let run = model.quickRun { completion(run) }
            else if let file = model.quickFile { destinationPicker(file) }
            else { intake }
        }.padding(embedded ? 18 : 32)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragOver, perform: receive)
        .sheet(isPresented: $createFolder) { newFolderSheet }
    }

    private var steps: some View {
        HStack(spacing: 12) {
            step(1, "파일"); connector; step(2, "폴더"); connector; step(3, "완료")
            Spacer()
            if model.quickFile != nil && model.quickRun == nil {
                Button("처음으로", action: model.resetQuickMove).font(Theme.body(12)).buttonStyle(.plain).foregroundStyle(Theme.gray).disabled(model.busy)
            }
        }.accessibilityElement(children: .combine).accessibilityLabel("3단계 중 \(stage)단계, \(stage == 1 ? "파일 선택" : stage == 2 ? "폴더 선택" : "결과")")
    }
    private var connector: some View { Rectangle().fill(Color.black.opacity(0.12)).frame(width: 28, height: 1).accessibilityHidden(true) }
    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 7) {
            Group {
                if number < stage { Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)) }
                else { Text("\(number)").font(Theme.body(11)) }
            }.frame(width: 24, height: 24)
                .foregroundStyle(number <= stage ? Color.white : Theme.gray)
                .background(number == stage ? Color.black : number < stage ? Theme.blue : Theme.soft, in: RoundedRectangle(cornerRadius: 5))
            Text(title).font(Theme.body(12)).foregroundStyle(number == stage ? Color.black : Theme.gray)
        }
    }

    private var intake: some View {
        VStack(spacing: 18) {
            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white).frame(width: 80, height: 80)
                    Image(systemName: "doc.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(dragOver ? Theme.blue : Color.black)
                }.accessibilityHidden(true)
                VStack(spacing: 9) {
                    Text(dragOver ? "여기에 놓으세요" : "정리할 파일을 놓으세요").font(Theme.body(embedded ? 18 : 22)).fontWeight(.medium)
                    Text("파일 1개씩, 원하는 폴더로 이동합니다.").font(Theme.body(13)).foregroundStyle(Theme.gray)
                }
                if !embedded { Button("파일 선택…", action: model.chooseFile).buttonStyle(PillStyle()).disabled(model.busy) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dragOver ? Theme.blue.opacity(0.08) : Color(white: 0.975), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dragOver ? Theme.blue : Color.black.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                .accessibilityIdentifier("file-drop-area")
            HStack {
                Spacer()
                Button { model.showFolderBatch = true } label: { Label("폴더 전체 정리", systemImage: "folder") }
                    .buttonStyle(.plain).font(Theme.body(12)).foregroundStyle(Theme.gray).disabled(model.busy)
                    .help("폴더 안의 여러 항목을 이름 규칙으로 분석합니다.")
                Spacer()
            }.frame(height: 26)
        }
    }

    private func destinationPicker(_ file: URL) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 30) {
                if !embedded {
                VStack(alignment: .leading, spacing: 20) {
                    Text("선택한 파일").font(Theme.body(12)).foregroundStyle(Theme.gray)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 54, height: 54).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file.lastPathComponent).font(Theme.body(16)).fontWeight(.medium).lineLimit(3).textSelection(.enabled)
                        PathText(path: file.deletingLastPathComponent().path)
                    }
                    Button("파일 변경…", action: model.chooseFile).buttonStyle(.plain).font(Theme.body(12)).foregroundStyle(Theme.gray).disabled(model.busy)
                    Spacer(minLength: 0)
                }.padding(22).frame(width: 255, alignment: .topLeading).frame(maxHeight: .infinity)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("옮길 폴더를 선택하세요").font(Theme.body(embedded ? 17 : 20)).fontWeight(.medium)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            if folders.isEmpty {
                                Text("아래에서 폴더를 선택하거나 새로 만드세요.").font(Theme.body(13)).foregroundStyle(Theme.gray).padding(.vertical, 14)
                            }
                            ForEach(folders) { folder in folderRow(folder) }
                            HStack(spacing: 14) {
                                Button { model.chooseQuickFolder() } label: { Label("폴더 선택…", systemImage: "folder") }
                                Button { folderName = ""; folderError = nil; createFolder = true } label: { Label("새 폴더…", systemImage: "folder.badge.plus") }
                            }.font(Theme.body(12)).buttonStyle(.plain).padding(.vertical, 12)
                            if model.quickDestination != nil {
                                Hairline().opacity(0.45)
                                Toggle("다음에도 이 폴더 추천", isOn: $model.rememberQuickChoice).toggleStyle(.checkbox).font(Theme.body(12)).padding(.top, 7)
                                if model.rememberQuickChoice {
                                    HStack(spacing: 8) {
                                        Text("이름 시작").font(Theme.body(11)).foregroundStyle(Theme.gray)
                                        TextField("파일 이름의 시작 부분", text: $model.quickRulePrefix).textFieldStyle(.roundedBorder).font(Theme.body(12))
                                    }
                                    Text("이 이름으로 시작하는 파일에만 추천합니다.").font(Theme.body(11)).foregroundStyle(Theme.gray)
                                }
                            }
                        }.padding(.trailing, 2)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).disabled(model.busy)
            }
            if !embedded { HStack(spacing: 16) {
                if let target = model.quickDestination {
                    Label(target.name, systemImage: "arrow.right").font(Theme.body(13)).lineLimit(1).help(target.id)
                }
                Spacer()
                Button("이 폴더로 이동", action: model.executeQuickMove).buttonStyle(PillStyle())
                    .disabled(model.busy || model.quickDestination == nil)
            }.padding(.top, 24) }
        }
    }

    private func folderRow(_ folder: FolderRecommendation) -> some View {
        let chosen = model.quickDestination?.id == folder.id
        return Button { model.selectQuickFolder(folder) } label: {
            HStack(spacing: 13) {
                Image(systemName: "folder.fill").font(.system(size: 25, weight: .light)).foregroundStyle(chosen ? Theme.blue : Theme.gray)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Text(folder.name).font(Theme.body(14)).fontWeight(.medium).lineLimit(1)
                        Text(folder.reason).font(Theme.body(10)).foregroundStyle(Theme.gray).lineLimit(1)
                    }
                    Text(folder.id.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/"))
                        .font(Theme.body(11)).foregroundStyle(Theme.gray).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.system(size: 17)).foregroundStyle(chosen ? Theme.blue : Color.black.opacity(0.2))
            }.padding(15).background(chosen ? Theme.blue.opacity(0.07) : Color(white: 0.975), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? Theme.blue : Color.black.opacity(0.08), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("\(folder.name), \(folder.reason)")
            .accessibilityValue(chosen ? "선택됨" : "선택 안 됨").help(folder.id)
    }

    private func completion(_ run: RunRecord) -> some View {
        let undone = run.state == .undone
        let completed = run.state == .completed
        return VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(systemName: undone ? "arrow.uturn.backward.circle" : completed ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 42, weight: .light)).foregroundStyle(completed ? Theme.blue : Color.black).accessibilityHidden(true)
            Text(undone ? "원래 위치로 되돌렸습니다" : completed ? "이동 완료" : "이동 상태를 확인하세요").font(Theme.body(22)).fontWeight(.medium)
            if let entry = run.entries.first {
                VStack(spacing: 8) {
                    Text(URL(fileURLWithPath: entry.source).lastPathComponent).font(Theme.body(15)).lineLimit(2)
                    PathText(path: undone ? URL(fileURLWithPath: entry.source).deletingLastPathComponent().path : URL(fileURLWithPath: entry.destination).deletingLastPathComponent().path)
                }
                if let message = run.message { Text(message).font(Theme.body(12)).foregroundStyle(Theme.gray).multilineTextAlignment(.center).frame(maxWidth: 460) }
                HStack(spacing: 14) {
                    if !embedded { Button("다음 파일 선택…", action: model.chooseFile).buttonStyle(PillStyle()).disabled(model.busy) }
                    if run.canUndo { Button("되돌리기", action: model.undoQuickMove).buttonStyle(PillStyle(filled: false)).disabled(model.busy) }
                    else if !completed && !undone { Button("기록 확인") { model.page = .history }.buttonStyle(PillStyle(filled: false)) }
                }
                Button("Finder에서 보기") { model.showInFinder(undone || entry.state == .pending ? entry.source : entry.destination) }
                    .buttonStyle(.plain).font(Theme.body(12)).foregroundStyle(Theme.gray)
            }
            Spacer(minLength: 0)
            Button("처음으로", action: model.resetQuickMove).buttonStyle(.plain).font(Theme.body(12)).foregroundStyle(Theme.gray).disabled(model.busy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("새 폴더").font(Theme.body(21)).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                Text("폴더 이름").font(Theme.body(12))
                TextField("예: 리서치 자료", text: $folderName).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("만들 위치").font(Theme.body(12)); Spacer(); Button("변경…", action: chooseParent).buttonStyle(.plain).font(Theme.body(12)) }
                PathText(path: folderParent.path)
            }
            if let folderError { Text(folderError).font(Theme.body(12)).foregroundStyle(Theme.gray).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("취소") { createFolder = false }.buttonStyle(PillStyle(filled: false)).keyboardShortcut(.cancelAction)
                Spacer()
                Button("만들고 선택") {
                    if model.createQuickFolder(name: folderName, parent: folderParent) { createFolder = false }
                    else { folderError = model.error; model.error = nil }
                }.buttonStyle(PillStyle()).disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 470).font(Theme.body()).background(Color.white).preferredColorScheme(.light)
    }
    private func chooseParent() {
        let panel = NSOpenPanel(); panel.title = "새 폴더를 만들 위치"; panel.prompt = "위치 선택"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = folderParent
        if panel.runModal() == .OK, let url = panel.url { model.remember(url); folderParent = url }
    }
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy else { return false }
        guard providers.count == 1 else { model.error = "파일은 1개씩 놓아 주세요. 폴더 단위 정리는 ‘폴더 전체 정리’에서 할 수 있습니다."; return false }
        providers[0].loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            DispatchQueue.main.async {
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                    model.error = "파일을 읽지 못했습니다. ‘파일 선택’에서 다시 선택해 주세요."; return
                }
                model.acceptFile(url)
            }
        }
        return true
    }
}
