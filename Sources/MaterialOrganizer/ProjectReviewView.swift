import AppKit
import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import OrganizerCore

struct ProjectReviewView: View {
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var owner: AppModel
    var embedded = false
    @State private var dragOver = false
    @State private var loadingDrop = false
    @State private var previewURL: URL?
    @State private var presentsProjectSetup = false
    @State private var setupProject: ProjectDefinition?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { header }
            if owner.busy && (review.isAnalyzing || review.isPreparing) { progress }
            else if let run = review.lastRun { completion(run) }
            else if let plan = review.preparedPlan { movePreview(plan) }
            else if review.activeBatchID != nil { reviewFiles }
            else { inbox }
            if let message = review.failure ?? review.notice { messageBar(message, failure: review.failure != nil) }
        }
        .padding(embedded ? 18 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(Theme.body()).foregroundStyle(Color.black)
        .background(embedded ? Color.clear : Color.white)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragOver, perform: receive)
        .sheet(isPresented: $presentsProjectSetup, onDismiss: finishProjectSetup) {
            ProjectSetupView(review: review, project: setupProject)
        }
        .onChange(of: review.showProjectSetup) { _, requested in routeProjectSetup(requested) }
        .onAppear { routeProjectSetup(review.showProjectSetup) }
        .quickLookPreview($previewURL)
        .accessibilityIdentifier("project-review")
    }

    private func routeProjectSetup(_ requested: Bool) {
        guard requested else { presentsProjectSetup = false; return }
        let hostTitle = embedded ? "TILES" : "TILES · 정리 추천"
        // Both hosts observe one model; only the window receiving the action presents its sheet.
        guard NSApp.keyWindow?.title == hostTitle else { return }
        setupProject = review.editingProject
        presentsProjectSetup = true
    }

    private func finishProjectSetup() {
        review.showProjectSetup = false
        review.editingProject = nil
        setupProject = nil
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(review.preparedPlan == nil ? "정리 추천" : "이동안 확인").font(Theme.body(21)).fontWeight(.semibold)
            Spacer()
            if review.activeBatchID != nil || review.lastRun != nil {
                Button("확인 대기", action: review.returnToInbox).buttonStyle(.plain).font(Theme.body(12)).disabled(owner.busy)
            }
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inboxDropTarget
                    if !review.batches.isEmpty { queuedBatches }
                }
            }
            HStack(spacing: 12) {
                Button { review.newProject() } label: { Label("프로젝트 만들기", systemImage: "folder.badge.plus") }
                    .buttonStyle(.plain).font(Theme.body(12)).accessibilityIdentifier("new-project")
                if !review.projects.isEmpty {
                    Menu("프로젝트 \(review.projects.count)개") {
                        ForEach(review.projects) { project in Button(project.name) { review.editProject(project) } }
                    }.font(Theme.body(12)).fixedSize()
                }
                Spacer()
                Button("폴더 전체 정리") { owner.showFolderBatch = true; owner.projectReviewActive = false }
                    .buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gray)
            }.disabled(owner.busy || !review.storeReadable)
        }
    }

    private var inboxDropTarget: some View {
        VStack(spacing: 16) {
                Image(systemName: "doc.on.doc").font(.system(size: 32, weight: .light)).accessibilityHidden(true)
                Text(dragOver ? "여기에 놓으세요" : "정리할 파일을 놓으세요").font(Theme.body(18)).fontWeight(.medium)
                Text("여러 파일을 프로젝트와 템플릿에 맞춰 정리합니다.")
                    .font(Theme.body(12)).foregroundStyle(Theme.gray).multilineTextAlignment(.center)
                Button("파일 선택…", action: owner.chooseFile).buttonStyle(PillStyle()).disabled(owner.busy || loadingDrop)
            }.frame(maxWidth: .infinity, minHeight: 165)
                .padding(16)
                .background(dragOver ? Theme.blue.opacity(0.10) : Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dragOver ? Theme.blue : Color.black.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                .accessibilityIdentifier("file-drop-area")
    }

    private var queuedBatches: some View {
        VStack(alignment: .leading, spacing: 12) {
                Text("확인 대기 · \(review.pendingCount)개 파일").font(Theme.body(13)).fontWeight(.medium)
                    LazyVStack(spacing: 7) {
                        ForEach(review.batches) { batch in
                            HStack {
                                Button { review.openBatch(batch) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: batch.origin == "직접 선택" ? "doc.on.doc" : "desktopcomputer")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(batch.origin) · \(batch.files.count)개 파일").font(Theme.body(12)).fontWeight(.medium)
                                            Text(batch.createdAt, style: .relative).font(Theme.body(10)).foregroundStyle(Theme.gray)
                                        }
                                        Spacer(); Image(systemName: "arrow.right").font(.system(size: 11))
                                    }.padding(11).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).accessibilityIdentifier("review-queue-\(batch.id)")
                                Button { review.dismissBatch(batch.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                    .buttonStyle(.plain).help("대기 목록에서 빼기 · 파일은 그대로 둡니다").accessibilityLabel("대기 목록에서 빼기")
                            }.disabled(owner.busy)
                        }
                    }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(review.isAnalyzing ? "파일을 확인하고 있습니다" : "이동안을 확인하고 있습니다")
                .font(Theme.body(18)).fontWeight(.medium)
            ProgressView(value: Double(owner.progress.completed), total: Double(max(1, owner.progress.total)))
                .tint(Theme.blue)
            Text(owner.progress.message).font(Theme.body(12)).foregroundStyle(Theme.gray)
            Text("파일은 원래 위치에 있습니다.").font(Theme.body(12)).foregroundStyle(Theme.gray)
            Spacer()
            HStack { Spacer(); Button("중단", action: owner.cancel).buttonStyle(PillStyle(filled: false)) }
        }.padding(.vertical, 16).accessibilityIdentifier("review-progress")
    }

    private var reviewFiles: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(review.rows.count)개 파일").font(Theme.body(18)).fontWeight(.medium)
                Text("\(review.readyCount)개 준비 · \(review.unresolvedCount)개 확인 필요").font(Theme.body(11)).foregroundStyle(Theme.gray)
                Spacer()
                Button("다시 분석", action: review.analyzeActive).buttonStyle(.plain).font(Theme.body(11)).disabled(owner.busy)
            }
            HStack(spacing: 12) {
                Toggle("내용 확인", isOn: Binding(get: { review.contentEnabled }, set: { review.setContentEnabled($0) }))
                    .toggleStyle(.checkbox).font(Theme.body(11)).help("이 기기에서 지원 문서의 텍스트와 이미지 OCR을 확인합니다. 외부 서버로 보내지 않습니다.")
                Text("기기 안에서 분석").font(Theme.body(10)).foregroundStyle(Theme.gray)
                Spacer()
                Button("프로젝트 추가", action: review.newProject).buttonStyle(.plain).font(Theme.body(11)).accessibilityIdentifier("new-project")
            }.disabled(owner.busy)
            Hairline().opacity(0.6)
            assignmentBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if review.projects.isEmpty {
                        HStack(spacing: 12) {
                            Text("프로젝트와 정리 방식을 먼저 선택하세요.").font(Theme.body(12))
                            Spacer()
                            Button("프로젝트 만들기", action: review.newProject).buttonStyle(PillStyle(filled: false))
                        }.padding(14).background(Theme.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(groupKeys, id: \.self) { key in
                        let grouped = review.rows.filter { review.projectName($0) == key }
                        Text("\(key) · \(grouped.count)개").font(Theme.body(11)).foregroundStyle(Theme.gray).padding(.top, 5)
                        ForEach(grouped) { row in
                            ProjectReviewFileRow(review: review, owner: owner, rowID: row.id, preview: { previewURL = $0 })
                        }
                    }
                }.padding(.trailing, 2)
            }
            HStack(spacing: 14) {
                Button("나중에", action: review.returnToInbox).buttonStyle(PillStyle(filled: false)).disabled(owner.busy)
                Spacer()
                if review.unresolvedCount > 0 { Text("확인 필요한 파일은 남겨둡니다").font(Theme.body(10)).foregroundStyle(Theme.gray) }
                Button("\(review.readyCount)개 이동안 확인") { review.prepare() }
                    .buttonStyle(PillStyle()).disabled(!review.canPreview).accessibilityIdentifier("review-prepare")
            }
        }
    }

    private var groupKeys: [String] {
        let names = Set(review.rows.map { review.projectName($0) })
        return names.sorted { a, b in a == "프로젝트 확인 필요" ? false : b == "프로젝트 확인 필요" ? true : a.localizedStandardCompare(b) == .orderedAscending }
    }

    private var assignmentBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                inclusionControl
                assignmentMenus
                Spacer(minLength: 0)
            }.frame(minWidth: 430)
            VStack(alignment: .leading, spacing: 8) {
                inclusionControl
                assignmentMenus
            }
        }.disabled(owner.busy)
    }

    private var inclusionControl: some View {
        HStack(spacing: 12) {
            Toggle("전체", isOn: Binding(get: { !review.rows.isEmpty && review.rows.allSatisfy(\.included) }, set: { review.includeAll($0) }))
                .toggleStyle(.checkbox).font(Theme.body(11)).accessibilityIdentifier("review-include-all")
            Text("포함한 파일에 적용").font(Theme.body(10)).foregroundStyle(Theme.gray)
        }
    }

    private var assignmentMenus: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(review.projects) { project in Button(project.name) { review.assignProject(project.id) } }
            } label: { Label("프로젝트", systemImage: "folder") }
                .font(Theme.body(12)).fixedSize().disabled(review.projects.isEmpty || !review.rows.contains(where: \.included))
                .accessibilityIdentifier("review-bulk-project")
            if let project = review.singleSelectedProject {
                Menu {
                    Button("프로젝트 폴더에 두기") { review.assignFolder("") }
                    Divider()
                    ForEach(project.folders, id: \.self) { path in Button(path) { review.assignFolder(path) } }
                } label: { Label("하위 폴더", systemImage: "folder.badge.gearshape") }
                    .font(Theme.body(12)).fixedSize().accessibilityIdentifier("review-bulk-folder")
            }
        }
    }

    private func movePreview(_ plan: ScanPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plan.proposals.isEmpty ? "폴더 구조 확인" : "옮길 위치를 확인하세요").font(Theme.body(18)).fontWeight(.medium)
            Text("파일 \(plan.proposals.count)개 이동 · 새 폴더 \(review.newDirectoryPaths.count)개")
                .font(Theme.body(12)).foregroundStyle(Theme.gray)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !review.newDirectoryPaths.isEmpty {
                        Text("만들 폴더").font(Theme.body(12)).fontWeight(.medium).padding(.top, 4)
                        ForEach(review.newDirectoryPaths, id: \.self) { path in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "folder.badge.plus").foregroundStyle(Theme.blue)
                                PathText(path: path)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if !plan.proposals.isEmpty {
                        Text("파일별 이동 위치").font(Theme.body(12)).fontWeight(.medium).padding(.top, 8)
                        ForEach(plan.proposals) { proposal in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(proposal.name).font(Theme.body(13)).fontWeight(.medium)
                                PathText(path: proposal.source)
                                HStack(alignment: .top, spacing: 8) { Image(systemName: "arrow.down.right").font(.system(size: 11)); PathText(path: proposal.destination ?? "") }
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if plan.proposals.isEmpty && review.newDirectoryPaths.isEmpty {
                        Text("이 구조의 폴더가 모두 준비되어 있습니다.").font(Theme.body(13)).padding(.vertical, 24)
                    }
                    ForEach(plan.warnings, id: \.self) { Text($0).font(Theme.body(11)).foregroundStyle(Theme.gray) }
                }.padding(.trailing, 2)
            }
            if review.unresolvedCount > 0 && !plan.proposals.isEmpty {
                Text("확인 필요한 \(review.unresolvedCount)개 파일은 원래 위치에 남습니다.").font(Theme.body(11)).foregroundStyle(Theme.gray)
            }
            HStack {
                Button("돌아가기", action: review.backToReview).buttonStyle(PillStyle(filled: false)).disabled(owner.busy)
                Spacer()
                if owner.busy { ProgressView().controlSize(.small); Button("중단", action: owner.cancel).buttonStyle(PillStyle(filled: false)) }
                else {
                    Button(executeLabel(plan), action: review.executePrepared).buttonStyle(PillStyle())
                        .disabled(plan.proposals.isEmpty && review.newDirectoryPaths.isEmpty).accessibilityIdentifier("review-execute")
                }
            }
        }.accessibilityIdentifier("review-plan")
    }

    private func executeLabel(_ plan: ScanPlan) -> String {
        if plan.proposals.isEmpty { return "폴더 \(review.newDirectoryPaths.count)개 만들기" }
        return review.newDirectoryPaths.isEmpty ? "\(plan.proposals.count)개 정리" : "폴더 만들고 \(plan.proposals.count)개 정리"
    }

    private func completion(_ run: RunRecord) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Image(systemName: run.state == .undone ? "arrow.uturn.backward.circle" : run.state == .completed ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 44, weight: .light)).foregroundStyle(run.state == .completed ? Theme.blue : Color.black).accessibilityHidden(true)
            Text(run.state == .undone ? "원래 위치로 되돌렸습니다" : run.state == .completed ? "정리 완료" : "정리 상태를 확인하세요")
                .font(Theme.body(21)).fontWeight(.medium)
            if run.state != .undone {
                Text("파일 \(run.movedCount)개 이동 · 폴더 \(run.createdDirectories.count)개 생성").font(Theme.body(13)).foregroundStyle(Theme.gray)
            }
            if let message = run.message { Text(message).font(Theme.body(12)).multilineTextAlignment(.center).textSelection(.enabled) }
            HStack(spacing: 12) {
                if run.canUndo { Button("되돌리기", action: review.undo).buttonStyle(PillStyle(filled: false)).accessibilityIdentifier("review-undo") }
                Button("확인 대기", action: review.returnToInbox).buttonStyle(PillStyle()).accessibilityIdentifier("review-next")
            }.disabled(owner.busy)
            if let entry = run.entries.first {
                Button("Finder에서 보기") { owner.showInFinder(run.state == .undone ? entry.source : entry.destination) }.buttonStyle(.plain).font(Theme.body(12))
            } else if run.state != .undone, let directory = run.createdDirectories.first {
                Button("폴더 열기") { owner.showInFinder(directory.path) }.buttonStyle(.plain).font(Theme.body(12))
            }
            Spacer(minLength: 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("review-completion")
    }

    private func messageBar(_ text: String, failure: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: failure ? "exclamationmark.circle" : "info.circle").font(.system(size: 12))
            Text(text).font(Theme.body(11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { review.failure = nil; review.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("안내 닫기")
        }.padding(11).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("review-message")
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard !owner.busy, !loadingDrop else { return false }
        loadingDrop = true
        let accepted = ReviewFileDrop.load(providers) { result in
            loadingDrop = false
            switch result {
            case .success(let urls): owner.acceptFilesForReview(urls)
            case .failure(let error): review.failure = error.localizedDescription
            }
        }
        if !accepted { loadingDrop = false; review.failure = "일반 파일을 한 번에 1~500개 놓아 주세요." }
        return accepted
    }
}

private struct ProjectReviewFileRow: View {
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var owner: AppModel
    let rowID: UUID
    var preview: (URL) -> Void
    @State private var expanded = false

    private var currentRow: ProjectReviewRow? { review.rows.first { $0.id == rowID } }

    var body: some View {
        if let row = currentRow { rowContent(row) }
    }

    private func rowContent(_ row: ProjectReviewRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    fileIdentity(row)
                    projectMenu(row).frame(width: 112)
                    folderMenu(row).frame(width: 115)
                    expandButton(row)
                }.frame(minWidth: 620)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) { fileIdentity(row); expandButton(row) }
                    HStack(spacing: 12) {
                        projectMenu(row).frame(maxWidth: .infinity, alignment: .leading)
                        folderMenu(row).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, 28)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    PathText(path: row.evidence.sourcePath)
                    if row.explicitlyAssigned { Text("직접 선택한 프로젝트").font(Theme.body(11)).fontWeight(.medium) }
                    ForEach(Array(row.evidence.projectCandidates.enumerated()), id: \.offset) { _, candidate in
                        Text("\(candidate.projectName): \(candidate.reasons.joined(separator: " · "))").font(Theme.body(11))
                    }
                    ForEach(Array(row.evidence.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason).font(Theme.body(10)).foregroundStyle(Theme.gray)
                    }
                    if let excerpt = row.evidence.observedTextExcerpt {
                        Text("읽은 내용 일부").font(Theme.body(10)).foregroundStyle(Theme.gray)
                        Text(excerpt).font(Theme.body(11)).lineLimit(6).textSelection(.enabled)
                    }
                    HStack { Button("미리보기", action: showPreview); Button("Finder에서 보기", action: showInFinder) }
                        .buttonStyle(.plain).font(Theme.body(11)).padding(.top, 3)
                        .disabled(!canAccessSource(row))
                }.padding(.leading, 27)
            }
        }.padding(12)
            .background(row.included ? Color.white : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(row.isReady ? Theme.blue.opacity(0.35) : Color.black.opacity(0.07), lineWidth: 1))
            .disabled(owner.busy).accessibilityIdentifier("review-file-\(row.evidence.name)")
    }

    private func fileIdentity(_ row: ProjectReviewRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { currentRow?.included ?? false }, set: { review.setIncluded(rowID, $0) }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("\(row.evidence.name) 정리에 포함")
                .disabled(row.evidence.sourceIdentity == nil)
            Button(action: showPreview) {
                if canAccessSource(row) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.evidence.sourcePath)).resizable().frame(width: 28, height: 28)
                } else {
                    Image(systemName: "doc").font(.system(size: 24)).frame(width: 28, height: 28).foregroundStyle(Theme.gray)
                }
            }.buttonStyle(.plain).help("파일 미리보기").accessibilityLabel("\(row.evidence.name) 미리보기")
                .disabled(!canAccessSource(row))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.evidence.name).font(Theme.body(12)).fontWeight(.medium).lineLimit(2).help(row.evidence.sourcePath)
                Text(row.evidence.readStatus.label).font(Theme.body(10)).foregroundStyle(readStatusColor(row)).lineLimit(2)
                if !row.explicitlyAssigned {
                    Text(row.evidence.projectMatch.label).font(Theme.body(10)).foregroundStyle(Theme.gray).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func readStatusColor(_ row: ProjectReviewRow) -> Color {
        switch row.evidence.issueSeverity {
        case .error: return .red
        case .warning: return .orange
        case .none, .notice: return Theme.gray
        }
    }

    private func projectMenu(_ row: ProjectReviewRow) -> some View {
        Menu {
            ForEach(review.projects) { project in Button(project.name) { review.assignProject(project.id, to: rowID) } }
        } label: { Text(review.project(row.projectID)?.name ?? "프로젝트 선택").font(Theme.body(11)).lineLimit(1) }
            .disabled(review.projects.isEmpty).accessibilityIdentifier("row-project-\(row.evidence.name)")
    }

    private func expandButton(_ row: ProjectReviewRow) -> some View {
        Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10)).frame(width: 24, height: 24) }
            .buttonStyle(.plain).help("추천 근거와 원본 위치").accessibilityLabel("\(row.evidence.name) 추천 근거")
    }
    @ViewBuilder private func folderMenu(_ row: ProjectReviewRow) -> some View {
        if let project = review.project(row.projectID) {
            Menu {
                Button("프로젝트 폴더에 두기") { review.assignFolder("", to: rowID) }
                Divider()
                ForEach(folderOptions(project, row: row), id: \.self) { folder in Button(folder) { review.assignFolder(folder, to: rowID) } }
            } label: { Text(row.folder.map { $0.isEmpty ? "프로젝트 폴더" : $0 } ?? "용도 선택").font(Theme.body(11)).lineLimit(1) }
                .accessibilityIdentifier("row-folder-\(row.evidence.name)")
        } else { Text("위치 확인 필요").font(Theme.body(10)).foregroundStyle(Theme.gray) }
    }
    private func folderOptions(_ project: ProjectDefinition, row: ProjectReviewRow) -> [String] {
        var paths = project.folders
        if let proposed = row.evidence.suggestedFolder(for: project), !paths.contains(proposed) { paths.append(proposed) }
        return paths
    }

    private func canAccessSource(_ row: ProjectReviewRow) -> Bool {
        row.evidence.sourceIdentity != nil && row.evidence.readStatus != .cancelled && row.evidence.readStatus != .invalidFile
    }

    private func showPreview() {
        guard let row = currentRow, canAccessSource(row) else { return }
        preview(URL(fileURLWithPath: row.evidence.sourcePath))
    }

    private func showInFinder() {
        guard let row = currentRow, canAccessSource(row) else { return }
        owner.showInFinder(row.evidence.sourcePath)
    }
}

enum ReviewFileDrop {
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor (Result<[URL], Error>) -> Void) -> Bool {
        guard !providers.isEmpty, providers.count <= 500,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        let batch = ReviewDropLoading(count: providers.count)
        for (index, provider) in providers.enumerated() {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let result = batch.store(url, at: index, error: error) {
                    Task { @MainActor in completion(result) }
                }
            }
        }
        return true
    }
}
private final class ReviewDropLoading: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?]
    private var remaining: Int
    private var failed = false
    init(count: Int) { urls = Array(repeating: nil, count: count); remaining = count }
    func store(_ url: URL?, at index: Int, error: Error?) -> Result<[URL], Error>? {
        lock.lock(); defer { lock.unlock() }
        urls[index] = url
        if error != nil || url?.isFileURL != true { failed = true }
        remaining -= 1
        guard remaining == 0 else { return nil }
        if failed { return .failure(OrganizerError("일부 파일 경로를 읽지 못해 묶음을 받지 않았습니다. 파일 선택에서 다시 선택해 주세요.")) }
        return .success(urls.compactMap { $0 })
    }
}
