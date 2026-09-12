import SwiftUI
import OrganizerCore
import OrganizerMotion

/// Every card uses integer spans of the same square cell. The metrics alone
/// subdivide one cell into four squares, retaining the outer grid's gap.
struct BentoGeometry {
    let cell: CGFloat
    let gap: CGFloat = 10
    init(size: CGSize) {
        cell = max(1, min((size.width - 50) / 6, (size.height - 30) / 4))
    }
    func span(_ cells: Int) -> CGFloat { cell * CGFloat(cells) + gap * CGFloat(cells - 1) }
    var width: CGFloat { span(6) }
    var height: CGFloat { span(4) }
    var smallCell: CGFloat { (cell - gap) / 2 }
}
private struct GridPlacement: ViewModifier {
    let grid: BentoGeometry
    let column: Int
    let row: Int
    let columns: Int
    let rows: Int
    func body(content: Content) -> some View {
        content.frame(width: grid.span(columns), height: grid.span(rows))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .offset(x: CGFloat(column) * (grid.cell + grid.gap), y: CGFloat(row) * (grid.cell + grid.gap))
    }
}
private extension View {
    func cell(_ grid: BentoGeometry, _ rect: GridRect) -> some View {
        cell(grid, rect.x, rect.y, rect.width, rect.height)
    }
    func cell(_ grid: BentoGeometry, _ column: Int, _ row: Int, _ columns: Int = 1, _ rows: Int = 1) -> some View {
        modifier(GridPlacement(grid: grid, column: column, row: row, columns: columns, rows: rows))
    }
    func tile(_ color: Color = Theme.soft) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color, in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var watch: FolderWatchService
    @ObservedObject var scope: ScopeSelectionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion = PuzzleMotionController()
    private var projectFlow: Bool { !model.showFolderBatch && (model.projectReviewActive || model.quickFile == nil) }
    private var phase: PuzzlePhase {
        if projectFlow {
            if review.lastRun != nil { return .completion }
            if review.preparedPlan != nil { return .preview }
            if review.isActive { return .recommendation }
            return .intake
        }
        if model.quickRun != nil { return .completion }
        if model.confirmExecute { return .preview }
        if model.plan != nil || model.quickFile != nil { return .recommendation }
        return .intake
    }
    private var expanded: Bool {
        model.page != .organize || model.showFolderBatch || (phase != .intake && phase != .completion)
    }
    private var phaseTitle: String {
        switch phase {
        case .intake: return "정리할 범위를 골라요"
        case .recommendation: return review.isAnalyzing ? "정리 위치를 찾고 있어요" : "추천 위치를 확인해요"
        case .preview: return "이대로 정리할까요?"
        case .completion: return review.lastRun?.state == .undone ? "원래 위치로 돌아왔어요" : review.lastRun?.state == .completed ? "정리가 끝났어요" : "정리 결과를 확인해요"
        }
    }
    private var activeFileCount: Int {
        review.rows.isEmpty ? review.batches.first(where: { $0.id == review.activeBatchID })?.files.count ?? 0 : review.rows.count
    }
    private var laterCount: Int {
        if phase == .intake || phase == .completion { return review.pendingCount }
        return review.batches.filter { $0.id != review.activeBatchID }.reduce(0) { $0 + $1.files.count }
    }
    private var stepNumber: String {
        switch phase { case .intake: return "01"; case .recommendation: return "02"; case .preview, .completion: return "03" }
    }
    private func startNewScope() {
        review.returnToInbox(); model.resetQuickMove(); model.invalidate(); scope.resetSelection(); model.showFolderBatch = false; model.page = .organize
    }
    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(1, proxy.size.width - 32)
            let initialGrid = BentoGeometry(size: CGSize(width: availableWidth, height: max(1, proxy.size.height - 104)))
            let headerHeight = max(64, initialGrid.smallCell / 2 + 20)
            let grid = BentoGeometry(size: CGSize(width: availableWidth, height: max(1, proxy.size.height - headerHeight - 40)))
            VStack(spacing: 0) {
                navigation(grid, height: headerHeight)
                ZStack(alignment: .topLeading) {
                    sourceTile(grid).cell(grid, motion.board[.source])
                    destinationTile(grid).cell(grid, motion.board[.destination])
                    headline(grid).cell(grid, motion.board[.headline])
                    totalTile(grid).cell(grid, motion.board[.total])
                    metrics(grid).cell(grid, motion.board[.metrics])
                    workspace.tile(Color(white: 0.97)).cell(grid, motion.board[.workspace])
                    actionTile(grid).cell(grid, motion.board[.action]).allowsHitTesting(!motion.isRouting)
                    guideTile.cell(grid, motion.board[.guide])
                }
                .frame(width: grid.width, height: grid.height, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                statusBar.frame(minHeight: 40).padding(.horizontal, 20)
            }
        }
        .font(Theme.body()).tracking(0.14).foregroundStyle(Color.black).background(Color.white)
        .onChange(of: model.page, initial: true) { _, _ in updateMotion() }
        .onChange(of: expanded) { _, _ in updateMotion() }
        .onChange(of: phase) { _, _ in updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
        .onDisappear { motion.stop() }
        .sheet(isPresented: $model.confirmExecute) { confirmation }
        .sheet(item: $model.confirmUndo) { run in
            VStack(alignment: .leading, spacing: 20) {
                Text("원래 위치로 되돌리기").font(Theme.body(21)).fontWeight(.semibold)
                Text("이동한 자료를 원래 위치로 되돌리고, 이 작업에서 만든 빈 폴더를 정리합니다. 이후 수정한 자료나 이름이 겹치는 항목이 있으면 멈춥니다.").fixedSize(horizontal: false, vertical: true)
                ScrollView { VStack(alignment: .leading, spacing: 16) { ForEach(run.entries.filter { $0.state != .pending && $0.state != .undone }) { entry in
                    VStack(alignment: .leading, spacing: 5) { Text(URL(fileURLWithPath: entry.source).lastPathComponent); PathText(path: entry.destination); Label(entry.source, systemImage: "arrow.turn.up.left").font(Theme.body(12)).textSelection(.enabled) }
                }
                    ForEach(run.createdDirectories, id: \.path) { directory in PathText(path: directory.path) }
                } }.frame(maxHeight: 300)
                HStack { Button("취소") { model.confirmUndo = nil }.buttonStyle(PillStyle(filled: false)); Spacer(); Button("원래 위치로 되돌리기") { model.handleRecord(run, undo: true) }.buttonStyle(PillStyle()) }
            }.padding(32).frame(width: 670).background(Color.white).font(Theme.body()).preferredColorScheme(.light)
        }
    }
    private func updateMotion() { motion.request(page: model.page, expanded: expanded, phase: phase, reduced: reduceMotion) }
    private func navigation(_ grid: BentoGeometry, height: CGFloat) -> some View {
        HStack {
            TileWordmark(cue: model.wordmarkCue)
            if model.isDemo { Text("DEMO").font(Theme.body(10)).padding(6).background(Theme.soft, in: Capsule()) }
            Spacer()
            HStack(spacing: grid.gap) {
                ForEach(AppModel.Page.allCases, id: \.self) { page in
                    Button { model.page = page } label: {
                        Text(page == .rules ? "설정" : page.rawValue).font(Theme.body(13))
                            .frame(width: grid.smallCell, height: grid.smallCell / 2)
                            .background(model.page == page ? Color.black : Theme.soft, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(model.page == page ? Color.white : Color.black)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityIdentifier("nav-\(page.rawValue)")
                }
            }
        }.padding(.leading, 18).frame(width: grid.width, height: height)
    }
    @ViewBuilder private func sourceTile(_ grid: BentoGeometry) -> some View {
        if projectFlow && model.page == .organize {
            VStack(alignment: .leading, spacing: 12) {
                Text("01 / SCOPE").font(Theme.body(10)).tracking(1)
                Image(systemName: scope.mode == .files ? "doc.on.doc" : "folder").font(.system(size: 26, weight: .light)).accessibilityHidden(true)
                Text(phase == .intake ? "선택한 범위" : "정리할 파일").font(Theme.body(15)).fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if phase != .intake {
                            Text("\(activeFileCount)개 파일").font(Theme.body(14))
                            ForEach(review.rows.prefix(5)) { row in
                                Text(row.evidence.name).font(Theme.body(11)).lineLimit(2).help(row.evidence.sourcePath)
                            }
                        } else if scope.mode == .files {
                            Text(scope.selectedFiles.isEmpty ? "아직 선택하지 않았어요" : "파일 \(scope.selectedFiles.count)개").font(Theme.body(12)).foregroundStyle(Theme.gray)
                            ForEach(scope.selectedFiles.prefix(4), id: \.path) { url in Text(url.lastPathComponent).font(Theme.body(11)).lineLimit(2).help(url.path) }
                        } else {
                            Text(scope.selectedLocationCount == 0 ? "위치를 선택해 주세요" : "\(scope.selectedLocationCount)곳 선택").font(Theme.body(12)).foregroundStyle(Theme.gray)
                            ForEach(scope.locations.filter(\.selected)) { location in Text(location.name).font(Theme.body(12)).help(location.path) }
                            Text(scope.includeSubfolders ? "하위 폴더 포함" : "바로 안의 파일만").font(Theme.body(10)).foregroundStyle(Theme.gray)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if phase != .intake {
                    Button("범위 다시 선택") { review.returnToInbox(); scope.refresh() }
                        .buttonStyle(PillStyle(filled: false, gridHeight: grid.smallCell / 2)).disabled(model.busy)
                        .accessibilityIdentifier("scope-back")
                }
            }.padding(18).tile()
        } else { legacySourceTile(grid) }
    }
    @ViewBuilder private func destinationTile(_ grid: BentoGeometry) -> some View {
        if projectFlow && model.page == .organize {
            VStack(alignment: .leading, spacing: 12) {
                Text("02 / SUGGEST").font(Theme.body(10)).tracking(1)
                Image(systemName: "folder.badge.gearshape").font(.system(size: 26, weight: .light)).accessibilityHidden(true)
                Text("정리 위치는\n자동으로").font(Theme.body(17)).fontWeight(.semibold)
                if phase == .intake {
                    Text("기존 프로젝트와 파일 종류를 살펴보고 알맞은 폴더를 제안해요.").font(Theme.body(12)).foregroundStyle(Theme.gray)
                } else if let project = review.singleSelectedProject {
                    PathText(path: project.rootPath)
                    Text("파일별 위치는 오른쪽에서 확인할 수 있어요.").font(Theme.body(11)).foregroundStyle(Theme.gray)
                } else {
                    Text("각 파일의 추천 위치를 확인하고 필요한 곳만 바꾸세요.").font(Theme.body(12)).foregroundStyle(Theme.gray)
                }
                Spacer(minLength: 0)
                Text(phase == .preview ? "실행 전까지\n원본은 그대로" : "추천이 맞으면\n한 번에 정리").font(Theme.body(11)).foregroundStyle(Theme.gray)
            }.padding(18).tile()
        } else { legacyDestinationTile(grid) }
    }
    private func legacySourceTile(_ grid: BentoGeometry) -> some View {
        VStack(spacing: grid.gap) {
            VStack(alignment: .leading, spacing: 14) {
                Text("01 / FILE").font(Theme.body(10)).tracking(1)
                Image(systemName: model.showFolderBatch ? "folder" : "doc").font(.system(size: 25, weight: .light)).accessibilityHidden(true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.showFolderBatch {
                            ForEach(model.sources, id: \.path) { url in
                                Text(url.lastPathComponent).font(Theme.body(13)).help(url.path)
                            }
                            if model.sources.isEmpty { Text("폴더 선택 전").font(Theme.body(12)).foregroundStyle(Theme.gray) }
                        } else if projectFlow, !review.rows.isEmpty {
                            Text("\(activeFileCount)개 파일").font(Theme.body(14)).fontWeight(.medium)
                            ForEach(review.rows.prefix(5)) { row in Text(row.evidence.name).font(Theme.body(11)).lineLimit(1).help(row.evidence.sourcePath) }
                            if review.rows.count > 5 { Text("외 \(review.rows.count - 5)개").font(Theme.body(11)).foregroundStyle(Theme.gray) }
                        } else if let file = model.quickFile {
                            Text(file.lastPathComponent).font(Theme.body(14)).fontWeight(.medium).lineLimit(4)
                            PathText(path: file.deletingLastPathComponent().path)
                        } else { Text("파일 선택 전").font(Theme.body(12)).foregroundStyle(Theme.gray) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(18).tile()
            Button(model.showFolderBatch ? "폴더 추가…" : projectFlow && review.isActive ? "파일 추가…" : model.quickFile == nil ? "파일 선택…" : "파일 변경…") {
                if model.showFolderBatch { model.addFolders() } else { model.chooseFile() }
            }.buttonStyle(PillStyle(gridHeight: grid.smallCell / 2)).disabled(model.busy)
        }
    }
    private func legacyDestinationTile(_ grid: BentoGeometry) -> some View {
        VStack(spacing: grid.gap) {
            VStack(alignment: .leading, spacing: 14) {
                Text("02 / FOLDER").font(Theme.body(10)).tracking(1)
                Image(systemName: "folder").font(.system(size: 25, weight: .light)).accessibilityHidden(true)
                if projectFlow, let project = review.singleSelectedProject {
                    Text(project.name).font(Theme.body(14)).fontWeight(.medium).lineLimit(3)
                    PathText(path: project.rootPath)
                } else if projectFlow, review.selectedProjectIDs.count > 1 {
                    Text("프로젝트 \(review.selectedProjectIDs.count)개").font(Theme.body(14)).fontWeight(.medium)
                    Text("파일별 선택 위치").font(Theme.body(12)).foregroundStyle(Theme.gray)
                } else if projectFlow, let root = review.workspaceRoot {
                    Text(root.lastPathComponent).font(Theme.body(14)).fontWeight(.medium)
                    PathText(path: root.path)
                } else if let target = model.quickDestination, !model.showFolderBatch {
                    Text(target.name).font(Theme.body(14)).fontWeight(.medium).lineLimit(3)
                    PathText(path: target.id)
                } else if model.showFolderBatch && model.overlayDestinationConnected {
                    Text(model.destination.lastPathComponent).font(Theme.body(14)).fontWeight(.medium)
                    PathText(path: model.destination.path)
                } else { Text("폴더 선택 전").font(Theme.body(12)).foregroundStyle(Theme.gray) }
                Spacer(minLength: 0)
            }.padding(18).tile()
            Button(projectFlow ? "프로젝트 만들기" : "폴더 선택…") {
                if model.showFolderBatch { model.chooseDestination() } else if projectFlow { review.newProject() } else { model.chooseQuickFolder() }
            }.buttonStyle(PillStyle(filled: false, gridHeight: grid.smallCell / 2))
                .disabled(model.busy || (!projectFlow && !model.showFolderBatch && (model.quickFile == nil || model.quickRun != nil)))
        }
    }
    private func headline(_ grid: BentoGeometry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TILES / \(model.page == .history ? "HISTORY" : model.page == .rules ? "SETTINGS" : "ORGANIZE")").font(Theme.body(9)).tracking(1)
            Spacer(minLength: 0)
            Text(model.page == .history ? "이동 기록" : model.page == .rules ? "설정" : model.showFolderBatch ? "폴더 전체 정리" : phaseTitle)
                .font(Theme.display(min(29, grid.cell * 0.19))).lineLimit(1).minimumScaleFactor(0.8)
            if model.page == .organize && projectFlow {
                HStack(spacing: 12) {
                    phaseLabel("01 범위", active: phase == .intake)
                    Text("→")
                    phaseLabel("02 추천", active: phase == .recommendation)
                    Text("→")
                    phaseLabel("03 정리", active: phase == .preview || phase == .completion)
                }.font(Theme.body(11))
            } else {
                Text(model.page == .history ? "완료한 이동을 확인하고 되돌립니다." : model.page == .rules ? "추천과 정리 방식을 설정합니다." : "폴더 선택 → 미리보기 → 이동")
                    .font(Theme.body(12)).lineLimit(2)
            }
        }.padding(18).tile(Theme.blue)
    }
    private func phaseLabel(_ title: String, active: Bool) -> some View {
        Text(title).fontWeight(active ? .bold : .regular).opacity(active ? 1 : 0.55)
            .accessibilityAddTraits(active ? .isSelected : [])
    }
    private func totalTile(_ grid: BentoGeometry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.page == .history ? "HISTORY" : model.page == .rules ? "RULES" : "STEP").font(Theme.body(9)).tracking(1)
            Spacer(minLength: 0)
            PuzzleCounter(value: model.page == .history ? "\(model.records.count)" : model.page == .rules ? "\(review.projects.count)" : stepNumber, size: grid.cell * 0.34, ink: .white, paper: .black, maximumWidth: grid.cell - 36)
        }.padding(18).foregroundStyle(Color.white).tile(Color.black)
    }
    private func metrics(_ grid: BentoGeometry) -> some View {
        let side = grid.smallCell
        return VStack(spacing: grid.gap) {
            if model.showFolderBatch, model.plan != nil {
                HStack(spacing: grid.gap) { detailCell("이동 가능", "\(model.executable.count)", side, blue: true); detailCell("유지", "\(model.count(.keep))", side) }
                HStack(spacing: grid.gap) { detailCell("분류 필요", "\(model.count(.review))", side); detailCell("제외", "\(model.count(.excluded))", side) }
            } else if projectFlow, let run = review.lastRun {
                let restoredCount = run.entries.filter { $0.state == .undone }.count
                let processedCount = run.state == .undone ? restoredCount : run.movedCount
                HStack(spacing: grid.gap) {
                    detailCell("전체 파일", "\(activeFileCount)개", side, blue: true)
                    detailCell(run.state == .undone ? "복원 완료" : "이동 완료", "\(processedCount)개", side)
                }
                HStack(spacing: grid.gap) {
                    detailCell("원래 위치", "\(run.state == .undone ? activeFileCount : max(0, activeFileCount - run.movedCount))개", side)
                    detailCell("나중에 정리", "\(laterCount)개", side)
                }
            } else if projectFlow {
                HStack(spacing: grid.gap) {
                    detailCell(phase == .intake ? "대상 파일" : "전체 파일", phase == .intake && scope.isScanning ? "확인 중" : "\(phase == .intake ? scope.candidateCount : activeFileCount)개", side, blue: true)
                    detailCell(phase == .intake ? "선택 위치" : "정리 준비", "\(phase == .intake ? scope.selectedLocationCount : review.readyCount)개", side)
                }
                HStack(spacing: grid.gap) {
                    detailCell(phase == .intake ? "폴더 유지" : "확인 필요", "\(phase == .intake ? scope.preservedFolderCount : review.unresolvedCount)개", side)
                    detailCell("나중에 정리", "\(laterCount)개", side)
                }
            } else {
                HStack(spacing: grid.gap) { detailCell("FILE", model.quickFile?.pathExtension.uppercased().isEmpty == false ? model.quickFile!.pathExtension.uppercased() : "1개씩", side, blue: true); detailCell("NAME", "이름 유지", side) }
                HStack(spacing: grid.gap) { detailCell("MOVE", "직접 선택", side); detailCell("HISTORY", "되돌리기", side) }
            }
        }
    }
    private func detailCell(_ label: String, _ value: String, _ side: CGFloat, blue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Theme.body(8)).tracking(0.4).foregroundStyle(blue ? Color.black : Theme.gray)
            Text(value).font(Theme.body(12)).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.75)
        }.padding(10).frame(width: side, height: side, alignment: .leading).background(blue ? Theme.blue : Theme.soft, in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var workspace: some View {
        Group {
            switch model.page {
            case .organize:
                if model.showFolderBatch { BatchOrganizeView(model: model, embedded: true) }
                else if projectFlow {
                    if phase == .intake { ScopeSelectionView(scope: scope, review: review, owner: model) }
                    else { ProjectReviewView(review: review, owner: model, embedded: true) }
                }
                else { FileOrganizeView(model: model, embedded: true) }
            case .history: HistoryView(model: model)
            case .rules: RulesView(model: model, review: review, watch: watch)
            }
        }.id(model.page).transition(.opacity).padding(model.page == .organize ? 0 : 20)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: model.page)
    }
    private func actionTile(_ grid: BentoGeometry) -> some View {
        VStack(spacing: grid.gap) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NEXT / \(stepNumber)").font(Theme.body(9)).tracking(1)
                Spacer(minLength: 0)
                if model.busy || scope.isScanning { ProgressView().controlSize(.small) }
                else { Image(systemName: phase == .completion ? "checkmark" : "arrow.right").font(.system(size: 26, weight: .light)).accessibilityHidden(true) }
                Text(model.busy ? "확인 중" : phase == .intake ? "추천 위치 찾기" : phase == .recommendation ? "이동 전 최종 확인" : phase == .preview ? "선택한 파일 정리" : "다음 정리 시작")
                    .font(Theme.body(12)).lineLimit(2)
            }.padding(12).tile(Theme.blue)
            primaryAction.buttonStyle(PillStyle(gridHeight: max(34, grid.smallCell / 2)))
        }
    }
    @ViewBuilder private var primaryAction: some View {
        if model.busy { Button("중단", action: model.cancel).disabled(model.quickRun != nil || model.page == .history) }
        else if model.page != .organize { Button("새 정리", action: startNewScope) }
        else if model.showFolderBatch {
            if model.plan == nil { Button("미리보기", action: model.analyze).disabled(model.sources.isEmpty || !model.overlayDestinationConnected) }
            else { Button("\(model.chosen.count)개 이동…") { model.confirmExecute = true }.disabled(model.chosen.isEmpty) }
        } else if projectFlow {
            if phase == .completion { Button("새 정리", action: startNewScope).accessibilityIdentifier("organize-new") }
            else if let plan = review.preparedPlan {
                Button(plan.proposals.isEmpty ? "폴더 만들기" : "\(plan.proposals.count)개 정리", action: review.executePrepared)
                    .disabled(plan.proposals.isEmpty && review.newDirectoryPaths.isEmpty).accessibilityIdentifier("review-execute")
            } else if review.isActive {
                Button("이동안 확인") { review.prepare() }.disabled(!review.canPreview).accessibilityIdentifier("review-prepare")
            } else if scope.isScanning {
                Button("확인 중단", action: scope.cancel)
            } else {
                Button("정리안 보기") { scope.preview(using: review) }.disabled(!scope.canPreview || !review.storeReadable)
                    .accessibilityIdentifier("scope-preview")
            }
        } else if model.quickRun != nil { Button("다음 파일…", action: model.chooseFile) }
        else { Button("이동", action: model.executeQuickMove).disabled(model.quickDestination == nil) }
    }
    private var guideTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: phase == .completion || model.page == .history ? "arrow.uturn.backward" : "arrow.right")
                .font(.system(size: 34, weight: .light)).accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(model.page == .history ? "기록에서 복구" : model.page == .rules ? "나에게 맞게" : phase == .intake ? "범위만 고르면\n위치는 알아서" : phase == .recommendation ? "맞는 추천은\n그대로" : phase == .preview ? "확인한 만큼\n한 번에" : "필요하면\n되돌리기")
                .font(Theme.body(17)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            Text(model.page != .organize ? "완료한 작업은 기록에 남습니다." : phase == .intake ? "파일 · 선택 폴더 · 전체 중에서 시작하세요." : phase == .recommendation ? "틀린 위치만 바꾸세요. 확인 필요한 파일은 남겨둡니다." : phase == .preview ? "정리를 누르면 표시한 위치로 이동합니다." : "이동 내역을 확인하고 원래 위치로 복구할 수 있어요.")
                .font(Theme.body(11)).foregroundStyle(Theme.gray).fixedSize(horizontal: false, vertical: true)
        }.padding(18).tile()
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy { Text(model.progress.message).font(Theme.body(11)).lineLimit(1) }
            else if let value = model.error ?? model.message {
                Image(systemName: model.error != nil ? "exclamationmark.circle" : "checkmark").font(.system(size: 11))
                Text(value).font(Theme.body(11)).lineLimit(2).help(value).textSelection(.enabled)
                Button { model.error = nil; model.message = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("알림 닫기")
            }
            Spacer(minLength: 12)

        }
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(model.chosen.count)개 항목 이동").font(Theme.body(21)).fontWeight(.semibold)
            Text("아래 자료만 새 위치로 이동합니다. 폴더 안의 구성은 함께 유지됩니다.")
            ScrollView { VStack(alignment: .leading, spacing: 18) { ForEach(model.chosen) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(Theme.body(15)); PathText(path: item.source)
                    Label(item.destination ?? "", systemImage: "arrow.right").font(Theme.body(13)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
            } } }.frame(maxHeight: 380)
            Text("참조 확인은 선택한 폴더 안의 코드·문서에 한정됩니다. 다른 앱이나 폴더에서 사용하는 자료는 선택에서 빼 주세요.").font(Theme.body(12)).foregroundStyle(Theme.gray)
            HStack { Button("돌아가기") { model.confirmExecute = false }.buttonStyle(PillStyle(filled: false)); Spacer(); Button("\(model.chosen.count)개 이동 실행", action: model.execute).buttonStyle(PillStyle()) }
        }.padding(32).frame(width: 690).font(Theme.body()).background(Color.white).preferredColorScheme(.light)
    }
}

struct BatchOrganizeView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Button { model.showFolderBatch = false } label: { Label("파일 정리", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(Theme.body(12)).disabled(model.busy)
                Spacer()
                Text("폴더 전체 정리").font(Theme.body(16)).fontWeight(.medium)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("확인할 폴더").fontWeight(.medium); Spacer(); Button("추가…", action: model.addFolders).buttonStyle(.plain) }
                    if model.sources.isEmpty { Text("자료가 들어 있는 폴더를 추가하세요.").foregroundStyle(Theme.gray) }
                    ForEach(model.sources, id: \.path) { url in
                        HStack {
                            Text(url.lastPathComponent).lineLimit(1).help(url.path)
                            Spacer()
                            Button { model.removeSource(url) } label: { Image(systemName: "xmark").font(.system(size: 10)).padding(4) }
                                .buttonStyle(.plain).accessibilityLabel("\(url.lastPathComponent) 제외")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.black.opacity(0.1)).frame(width: 1)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("모을 폴더").fontWeight(.medium); Spacer(); Button("선택…", action: model.chooseDestination).buttonStyle(.plain) }
                    if model.overlayDestinationConnected { Text(model.destination.lastPathComponent); PathText(path: model.destination.path) }
                    else { Text("정리한 자료를 모을 폴더를 선택하세요.").foregroundStyle(Theme.gray) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(Theme.body(13)).fixedSize(horizontal: false, vertical: true).padding(18)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8)).disabled(model.busy)
            if model.plan != nil { results }
            else {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.gray)
                    Text("폴더를 선택하고 이동할 항목을 확인하세요.").font(Theme.body(15))
                    Button("미리보기", action: model.analyze).buttonStyle(PillStyle())
                        .disabled(model.busy || model.sources.isEmpty || !model.overlayDestinationConnected)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.plan != nil {
                HStack {
                    Text("\(model.chosen.count)개 선택").font(Theme.body(13)).foregroundStyle(Theme.gray)
                    Spacer()
                    Button("선택한 항목 이동…") { model.confirmExecute = true }.buttonStyle(PillStyle()).disabled(model.busy || model.chosen.isEmpty)
                }
            }
        }.padding(embedded ? 18 : 32)
    }
    private var results: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("표시할 항목", selection: $model.filter) {
                    Text("전체 \(model.proposals.count)").tag(nil as Decision?)
                    ForEach(Decision.allCases, id: \.self) { Text("\($0.label) \(model.count($0))").tag($0 as Decision?) }
                }.labelsHidden().frame(width: 140)
                TextField("파일 찾기", text: $model.search).textFieldStyle(.roundedBorder)
                Button("이동 가능 항목 선택", action: model.selectRecommended).buttonStyle(.plain)
                Button("다시 확인", action: model.analyze).buttonStyle(.plain)
            }.font(Theme.body(12)).disabled(model.busy)
            if let plan = model.plan, !plan.warnings.isEmpty {
                Text(plan.warnings.joined(separator: " · ")).font(Theme.body(11)).foregroundStyle(Theme.gray).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView { LazyVStack(spacing: 8) {
                ForEach(model.visible) { item in ProposalRow(model: model, item: item) }
                if model.visible.isEmpty { Text("표시할 항목이 없습니다.").font(Theme.body(13)).padding(32).foregroundStyle(Theme.gray) }
            } }
        }
    }
}

struct ProposalRow: View {
    @ObservedObject var model: AppModel
    var item: Proposal
    @State private var hovered = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { model.toggle(item) } label: {
                Image(systemName: item.decision.executable ? (model.selected.contains(item.id) ? "checkmark.square.fill" : "square") : item.decision == .review ? "questionmark" : "lock")
                    .font(.system(size: 16)).frame(width: 20, height: 24)
            }.buttonStyle(.plain).disabled(!item.decision.executable || model.busy).accessibilityLabel("\(item.name) 선택").accessibilityValue(model.selected.contains(item.id) ? "선택됨" : "선택 안 됨")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(Theme.body(13)).lineLimit(2).textSelection(.enabled)
                PathText(path: URL(fileURLWithPath: item.source).deletingLastPathComponent().path)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(Theme.gray).padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                if let destination = item.destination {
                    Text(destination.replacingOccurrences(of: (model.plan?.destinationRoot ?? "") + "/", with: "")).font(Theme.body(13)).lineLimit(2).textSelection(.enabled).help(destination)
                } else { Text(item.decision == .review ? "분류를 확인해 주세요" : "현재 위치 유지").font(Theme.body(13)) }
                Text(item.reason).font(Theme.body(11)).foregroundStyle(Theme.gray).lineLimit(2).help(item.reason)
                if item.canAssignCategory {
                    Menu { ForEach(model.rules.categories, id: \.self) { category in Button(category) { model.assign(category, to: item) } } } label: { Text(item.category.map { "\($0) · 변경" } ?? "분류 선택").font(Theme.body(11)) }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(item.decision.label).font(Theme.body(10)).padding(.horizontal, 7).padding(.vertical, 4).background(Color.white, in: Capsule()).frame(width: 62)
        }.padding(14).background(model.selected.contains(item.id) || hovered ? Theme.soft : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }
            .contextMenu { Button("Finder에서 보기") { model.showInFinder(item.source) } }
    }
}
