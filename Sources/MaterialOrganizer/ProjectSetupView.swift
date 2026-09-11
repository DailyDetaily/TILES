import AppKit
import SwiftUI
import OrganizerCore

@MainActor
struct ProjectSetupView: View {
    @ObservedObject var review: ProjectReviewModel
    var project: ProjectDefinition? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var basePath: String?
    @State private var rootOverride: String?
    @State private var template: ProjectTemplate
    @State private var folders: [String]
    @State private var aliasesText: String
    @State private var showsAliases = false
    @State private var selectedPath: String?
    @State private var addPath = ""
    @State private var renameText = ""
    @State private var command = ""
    @State private var message: String?
    @State private var failure: String?
    @State private var previous: SetupTreeSnapshot?
    @State private var importing = false
    @State private var importGeneration = UUID()
    @State private var importTask: Task<SetupFolderImport, Error>?
    @FocusState private var focusedField: SetupField?

    init(review: ProjectReviewModel, project: ProjectDefinition? = nil) {
        self.review = review; self.project = project
        _name = State(initialValue: project?.name ?? "")
        _basePath = State(initialValue: review.workspaceRoot?.path)
        _rootOverride = State(initialValue: project?.rootPath)
        _template = State(initialValue: project?.template ?? .simple)
        _folders = State(initialValue: project?.folders ?? ProjectTemplate.simple.defaultFolders)
        _aliasesText = State(initialValue: project?.aliases.joined(separator: ", ") ?? "")
    }

    private var isEditing: Bool { project != nil }
    private var hasActiveFiles: Bool { !review.rows.isEmpty }
    private var includedCount: Int { review.rows.filter(\.included).count }
    private var isBusy: Bool { importing || review.owner.busy }
    private var resolvedRoot: String? {
        if let rootOverride { return rootOverride }
        guard let basePath, !name.isEmpty, (try? ProjectFolderTree.validateName(name)) != nil else { return nil }
        return URL(fileURLWithPath: basePath).appendingPathComponent(name, isDirectory: true).path
    }
    private var saveLabel: String { isEditing ? "구조 저장" : (hasActiveFiles ? "이 프로젝트로 정리" : "폴더 미리보기") }
    private var visibleFolders: [String] { folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identitySection
                    templateSection
                    treeSection
                    conversationSection
                }.padding(24)
            }
            Hairline()
            footer
        }
        .frame(width: 680, height: 640)
        .font(Theme.body(13)).foregroundStyle(Color.black)
        .background(Color.white).tint(Theme.blue).preferredColorScheme(.light)
        .onAppear { if name.isEmpty { focusedField = .name } }
        .onDisappear { importGeneration = UUID(); importTask?.cancel() }
        .onChange(of: selectedPath) { _, path in renameText = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isEditing ? "프로젝트 구조" : "프로젝트 만들기").font(Theme.body(22)).fontWeight(.semibold)
                Text(isEditing ? "저장한 폴더 구성을 살펴보고 수정하세요." : "이름과 정리 방식을 고르고, 폴더 구성을 확인하세요.")
                    .font(Theme.body(12)).foregroundStyle(Theme.gray)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .buttonStyle(.plain).accessibilityLabel("프로젝트 설정 닫기")
                .accessibilityIdentifier("project-close")
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("프로젝트 이름").fontWeight(.medium)
                TextField("예: 여름 캠페인", text: $name)
                    .textFieldStyle(.roundedBorder).focused($focusedField, equals: .name)
                    .accessibilityLabel("프로젝트 이름").accessibilityIdentifier("project-name")
                    .disabled(isBusy)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(rootOverride == nil ? "보관할 기준 위치" : "프로젝트 폴더").fontWeight(.medium)
                    Spacer()
                    if !isEditing {
                        Button(basePath == nil ? "위치 선택…" : "위치 변경…", action: chooseBase)
                            .buttonStyle(.plain).foregroundStyle(Theme.gray)
                            .accessibilityIdentifier("project-base-folder")
                    }
                    Button("기존 폴더 사용…", action: chooseExisting)
                        .buttonStyle(.plain).foregroundStyle(Theme.gray)
                        .accessibilityIdentifier("project-existing-folder")
                }.disabled(isBusy)
                if let root = resolvedRoot {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Theme.gray)
                        PathText(path: root)
                    }
                    if rootOverride != nil {
                        Text("프로젝트 이름을 바꿔도 기존 폴더의 이름과 위치는 유지됩니다.")
                            .font(Theme.body(11)).foregroundStyle(Theme.gray)
                    }
                } else if let basePath {
                    PathText(path: basePath)
                    Text("이 위치 아래에 프로젝트 이름으로 폴더를 준비합니다.").font(Theme.body(11)).foregroundStyle(Theme.gray)
                } else {
                    Text("프로젝트를 모아 둘 폴더를 한 번 선택해 주세요.").font(Theme.body(12)).foregroundStyle(Theme.gray)
                }
                if importing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("선택한 폴더의 구성을 읽고 있습니다…").font(Theme.body(12)).foregroundStyle(Theme.gray)
                    }
                }
            }
            DisclosureGroup("프로젝트 별칭", isExpanded: $showsAliases) {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("쉼표로 구분: Summer, 여름 프로젝트", text: $aliasesText)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("프로젝트 별칭, 쉼표로 구분")
                        .accessibilityIdentifier("project-aliases").disabled(isBusy)
                    Text("파일명과 읽은 내용에서 프로젝트를 찾을 때 사용할 이름입니다.")
                        .font(Theme.body(11)).foregroundStyle(Theme.gray)
                }.padding(.top, 7)
            }.font(Theme.body(12))
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("정리 방식").fontWeight(.medium)
            Picker("정리 방식", selection: Binding(get: { template }, set: { selectTemplate($0) })) {
                ForEach(ProjectTemplate.allCases) { value in Text(value.label).tag(value) }
            }.pickerStyle(.segmented).labelsHidden().disabled(isBusy)
                .accessibilityIdentifier("project-template")
            Text(template.description).font(Theme.body(12)).foregroundStyle(Theme.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var treeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("폴더 미리보기").fontWeight(.medium)
                Text("\(folders.count)개").font(Theme.body(11)).foregroundStyle(Theme.gray)
                Spacer()
                if previous != nil {
                    Button("편집 되돌리기", action: undoTreeEdit).buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gray)
                        .accessibilityIdentifier("project-tree-undo").disabled(isBusy)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Label(name.isEmpty ? "프로젝트 이름" : name, systemImage: "folder.fill")
                    .font(Theme.body(12)).fontWeight(.medium).padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 5)
                if folders.isEmpty {
                    Text(template == .byMonth ? "선택한 파일의 수정일에 해당하는 달만 추가됩니다." : "하위 폴더가 없습니다. 아래에서 추가할 수 있습니다.")
                        .font(Theme.body(12)).foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading).padding(.horizontal, 12)
                } else {
                    List(selection: $selectedPath) {
                        ForEach(visibleFolders, id: \.self) { path in
                            HStack(spacing: 7) {
                                Image(systemName: "folder").foregroundStyle(Theme.gray)
                                Text(path.split(separator: "/").last.map(String.init) ?? path).font(Theme.body(12)).lineLimit(1)
                            }
                            .padding(.leading, CGFloat(path.split(separator: "/").count - 1) * 15)
                            .tag(path).help(path)
                            .accessibilityLabel(path).accessibilityIdentifier("project-tree-row-" + path)
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .frame(height: min(160, max(78, CGFloat(folders.count) * 25 + 10)))
                    .accessibilityLabel("프로젝트 하위 폴더 미리보기")
                    .accessibilityIdentifier("project-tree")
                }
            }
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(isBusy)
            HStack(spacing: 8) {
                TextField("추가할 상대 경로 · 예: 결과물/웹용", text: $addPath)
                    .textFieldStyle(.roundedBorder).focused($focusedField, equals: .add)
                    .accessibilityLabel("추가할 상대 폴더 경로").accessibilityIdentifier("project-folder-add-path")
                    .onSubmit(addFolder)
                Button("추가", action: addFolder).buttonStyle(PillStyle(filled: false))
                    .accessibilityIdentifier("project-folder-add").disabled(addPath.isEmpty)
            }.disabled(isBusy)
            if let selectedPath {
                HStack(spacing: 8) {
                    TextField("바꿀 이름 또는 상대 경로", text: $renameText)
                        .textFieldStyle(.roundedBorder).focused($focusedField, equals: .rename)
                        .accessibilityLabel("선택한 폴더의 새 이름").accessibilityIdentifier("project-folder-rename-name")
                        .onSubmit { editTree(.rename(path: selectedPath, to: renameText)) }
                    Button("이름 변경") { editTree(.rename(path: selectedPath, to: renameText)) }
                        .buttonStyle(PillStyle(filled: false)).accessibilityIdentifier("project-folder-rename")
                    Button("구성에서 제외") { editTree(.remove(path: selectedPath)) }
                        .buttonStyle(PillStyle(filled: false)).accessibilityIdentifier("project-folder-remove")
                        .help("미리보기에서 선택한 폴더와 하위 폴더를 제외합니다. 실제 폴더는 삭제하지 않습니다.")
                }.disabled(isBusy)
            }
        }
    }

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("말로 폴더 구성 수정").fontWeight(.medium)
            HStack(spacing: 8) {
                TextField("결과물을 웹용과 인쇄용으로 나눠줘", text: $command)
                    .textFieldStyle(.roundedBorder).focused($focusedField, equals: .command)
                    .accessibilityLabel("폴더 구성 편집 요청").accessibilityIdentifier("project-tree-command")
                    .onSubmit(applyCommand)
                Button("적용", action: applyCommand).buttonStyle(PillStyle(filled: false))
                    .accessibilityIdentifier("project-tree-command-apply").disabled(command.isEmpty)
            }.disabled(isBusy)
            Text("폴더 추가·제외·이름 변경·나누기 요청을 기기에서 처리합니다.")
                .font(Theme.body(11)).foregroundStyle(Theme.gray)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(Theme.body(12)).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("project-setup-error")
            } else if let message {
                Text(message).font(Theme.body(12)).foregroundStyle(Theme.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("project-setup-message")
            }
            Text("실제 폴더 생성과 파일 이동은 다음 미리보기에서 실행합니다.")
                .font(Theme.body(11)).foregroundStyle(Theme.gray)
            HStack(spacing: 12) {
                Button("취소") { dismiss() }.buttonStyle(PillStyle(filled: false)).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("project-cancel")
                Spacer()
                if !isEditing && hasActiveFiles {
                    Text("포함한 파일 \(includedCount)개에 적용").font(Theme.body(11)).foregroundStyle(Theme.gray)
                }
                Button(saveLabel, action: save).buttonStyle(PillStyle()).keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("project-save").disabled(isBusy || !review.storeReadable)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func selectTemplate(_ value: ProjectTemplate) {
        guard value != template, !isBusy else { return }
        previous = .init(template: template, folders: folders)
        template = value
        if value == .byMonth {
            let preview = ProjectDefinition(name: "미리보기", rootPath: "/미리보기", template: value)
            folders = Set(review.rows.filter(\.included).compactMap { $0.evidence.suggestedFolder(for: preview) }).sorted()
        } else { folders = value.defaultFolders }
        selectedPath = nil; failure = nil; message = "‘\(value.label)’ 구성을 미리보기에 적용했습니다."
    }

    private func undoTreeEdit() {
        guard let previous else { return }
        let current = SetupTreeSnapshot(template: template, folders: folders)
        template = previous.template; folders = previous.folders; self.previous = current
        selectedPath = nil; failure = nil; message = "직전 폴더 구성으로 되돌렸습니다."
    }
    private func editTree(_ edit: FolderTreeEdit) {
        applyResult(FolderTreeEditing.apply(edit, to: folders))
    }
    private func addFolder() {
        guard !addPath.isEmpty, !isBusy else { return }
        let result = FolderTreeEditing.apply(.add(path: addPath), to: folders)
        applyResult(result)
        if result.applied { addPath = ""; focusedField = .add }
    }
    private func applyCommand() {
        guard !command.isEmpty, !isBusy else { return }
        let result = FolderTreeEditing.apply(command: command, to: folders)
        applyResult(result)
        if result.applied { command = ""; focusedField = .command }
    }
    private func applyResult(_ result: FolderTreeEditResult) {
        if result.applied {
            previous = .init(template: template, folders: folders)
            folders = result.folders; selectedPath = nil; failure = nil; message = result.message
        } else { failure = result.message; message = nil }
    }

    private func chooseBase() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "프로젝트를 보관할 기준 폴더"; panel.prompt = "이 위치 사용"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false; panel.directoryURL = basePath.map { URL(fileURLWithPath: $0) } ?? review.owner.destination
        if panel.runModal() == .OK, let url = panel.url {
            if review.useWorkspace(url) {
                basePath = review.workspaceRoot?.path; rootOverride = nil; failure = nil
                message = "선택한 위치 아래에 프로젝트 이름으로 폴더를 준비합니다."
            } else { failure = review.failure ?? "이 위치를 사용할 수 없습니다." }
        }
    }

    private func chooseExisting() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "프로젝트로 사용할 기존 폴더"; panel.prompt = "구성 가져오기"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        panel.directoryURL = resolvedRoot.map { URL(fileURLWithPath: $0) } ?? review.workspaceRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        let rules = review.owner.rules, generation = UUID()
        importGeneration = generation; importing = true; failure = nil; message = nil
        let task = Task.detached(priority: .utility) { try SetupFolderReader.read(url, rules: rules) }
        importTask = task
        Task { @MainActor in
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result = await task.result
            guard generation == importGeneration else { return }
            importing = false; importTask = nil
            switch result {
            case .success(let imported):
                review.owner.remember(url); review.owner.persist()
                previous = .init(template: template, folders: folders)
                rootOverride = imported.rootPath; folders = imported.folders; selectedPath = nil
                if name.isEmpty { name = url.lastPathComponent }
                message = imported.message
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private func save() {
        guard !isBusy else { return }
        do {
            try ProjectFolderTree.validateName(name)
            guard let root = resolvedRoot else { focusedField = .name; throw OrganizerError("프로젝트 이름과 보관할 기준 위치를 확인해 주세요.") }
            let aliases = aliasesText.isEmpty ? [] : aliasesText.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let definition = ProjectDefinition(id: project?.id ?? UUID(), name: name, rootPath: root,
                                               aliases: aliases, template: template, folders: folders)
            try definition.validate()
            guard review.saveProject(definition, applyToIncluded: !isEditing && hasActiveFiles) else {
                failure = review.failure ?? "지금은 프로젝트를 저장할 수 없습니다."; return
            }
            if !isEditing && !hasActiveFiles { review.prepare(folderOnly: definition.id) }
            dismiss()
        } catch {
            failure = error.localizedDescription
            if (try? ProjectFolderTree.validateName(name)) == nil { focusedField = .name }
        }
    }
}

private enum SetupField: Hashable { case name, add, rename, command }
private struct SetupTreeSnapshot { var template: ProjectTemplate; var folders: [String] }
private struct SetupFolderImport: Sendable { var rootPath: String; var folders: [String]; var message: String }

/// Enumerates directory names only after an explicit picker action; never reads file contents.
private enum SetupFolderReader {
    static func read(_ selected: URL, rules: OrganizerRules) throws -> SetupFolderImport {
        let selectedValues = try selected.resourceValues(forKeys: [.volumeIsLocalKey, .isAliasFileKey])
        guard selectedValues.volumeIsLocal == true, selectedValues.isAliasFile != true else { throw OrganizerError("이 Mac에 있는 일반 폴더를 선택해 주세요.") }
        try SafeFileSystem.validateDirectory(selected)
        let root = try PathSafety.canonicalRoot(selected)
        try Planner.validateDestination(root, rules: rules)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
                                       .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .volumeIsLocalKey]
        let deadline = Date().addingTimeInterval(10)
        var folders: [String] = [], skipped = 0, inspected = 0, limited = false
        var queue: [(URL, String, Int)] = [(root, "", 0)]
        while !queue.isEmpty {
            try Task.checkCancellation()
            guard Date() < deadline, inspected < 2_000, folders.count < ProjectFolderTree.maximumFolders else { limited = true; break }
            let (parent, prefix, depth) = queue.removeFirst()
            guard let entries = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants], errorHandler: { _, _ in skipped += 1; return true }) else {
                skipped += 1; continue
            }
            while let child = entries.nextObject() as? URL {
                try Task.checkCancellation()
                guard Date() < deadline, inspected < 2_000, folders.count < ProjectFolderTree.maximumFolders else { limited = true; break }
                inspected += 1
                do {
                    let values = try child.resourceValues(forKeys: keys)
                    guard values.isDirectory == true else { continue }
                    guard values.isSymbolicLink != true, values.isAliasFile != true, values.isPackage != true, values.volumeIsLocal == true,
                          !(values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current),
                          try SafeFileSystem.identity(at: child).kind == "directory" else { skipped += 1; continue }
                    let relative = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                    try ProjectFolderTree.validatePath(relative)
                    try SafeFileSystem.validateDirectory(child)
                    try Planner.validateDestination(child, rules: rules)
                    folders.append(relative)
                    if depth + 1 < 3 { queue.append((child, relative, depth + 1)) }
                    else { limited = true }
                } catch { skipped += 1 }
            }
        }
        folders = try ProjectFolderTree.normalized(folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        var message = "기존 폴더의 구성 \(folders.count)개를 미리보기로 가져왔습니다. 파일은 읽거나 이동하지 않았습니다."
        if limited { message += " 최대 3단계·128개 폴더 범위만 확인했습니다." }
        if skipped > 0 { message += " 접근할 수 없거나 보호된 항목 \(skipped)개는 제외했습니다." }
        return .init(rootPath: root.path, folders: folders, message: message)
    }
}
