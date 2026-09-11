import AppKit
import SwiftUI
import OrganizerCore
import OrganizerMotion

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct SavedSettings: Codable {
    var sources: [String] = []
    var destination: String
    var bookmarks: [String: Data] = [:]
    var rules: OrganizerRules = .standard()
    var folderOverlayEnabled: Bool? = nil
    var folderDockLayout: FolderDockLayout? = nil
    var folderSuggestionRules: [FolderSuggestionRule]? = nil
}

@MainActor final class AppModel: ObservableObject {
    typealias Page = PuzzlePage
    @Published var page: Page = .organize
    @Published var sources: [URL] = []
    @Published var destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/자료")
    @Published var plan: ScanPlan?
    @Published var selected = Set<UUID>()
    @Published var filter: Decision?
    @Published var search = ""
    @Published var busy = false
    @Published var progress = EngineProgress(0, 0, "")
    @Published var message: String?
    @Published var error: String?
    @Published private(set) var wordmarkResult: TileWordmarkCue?
    @Published var records: [RunRecord] = []
    @Published var rules = OrganizerRules.standard()
    @Published var confirmExecute = false
    @Published var confirmUndo: RunRecord?
    @Published var showFolderBatch = false
    @Published private(set) var quickFile: URL?
    @Published private(set) var quickFolders: [FolderRecommendation] = []
    @Published private(set) var quickDestination: FolderRecommendation?
    @Published private(set) var quickRun: RunRecord?
    @Published var rememberQuickChoice = false
    @Published var quickRulePrefix = ""
    @Published private(set) var folderSuggestionRules: [FolderSuggestionRule] = []
    @Published private(set) var folderOverlayEnabled = false
    @Published private(set) var folderConfigurationRevision = 0
    @Published private(set) var folderDockLayout = FolderDockLayout()
    @Published private(set) var folderDockEditing = false
    @Published var projectReviewActive = false
    var openMainWindow: (() -> Void)?
    var openProjectReviewPanel: (() -> Void)?
    var receiveReviewFiles: (([URL], (() -> Void)?) -> Void)?
    var releaseReviewAccess: (() -> Void)?
    let isDemo: Bool
    let stateDirectory: URL
    private var engine: Organizer?
    private var bookmarks: [String: Data] = [:]
    private var scopedURLs: [URL] = []
    private var connectedPaths = Set<String>()
    private var cancellation = CancellationFlag()
    private var canPersist = true
    private var quickSourceIdentity: FileIdentity?
    private var quickScopedFile: URL?

    init(demoRootURL: URL? = nil) {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let demoRoot = demoRootURL?.path ?? argument("--demo-root")
        isDemo = demoRoot != nil
        if let demoRoot {
            let root = (try? PathSafety.canonicalRoot(URL(fileURLWithPath: demoRoot))) ?? URL(fileURLWithPath: demoRoot)
            stateDirectory = root.appendingPathComponent("AppState")
            sources = [root.appendingPathComponent("받은 자료")]
            destination = root.appendingPathComponent("자료")
        } else {
            stateDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MaterialOrganizer")
        }
        do {
            engine = Organizer(store: try JournalStore(directory: stateDirectory.appendingPathComponent("History")))
            if !isDemo, FileManager.default.fileExists(atPath: settingsURL.path) {
                let settings = try JSONDecoder().decode(SavedSettings.self, from: Data(contentsOf: settingsURL))
                try settings.rules.validate()
                bookmarks = settings.bookmarks; rules = settings.rules
                for (path, data) in bookmarks {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                        if !stale, let canonical = try? PathSafety.canonicalRoot(url), canonical.path == path {
                            connectedPaths.insert(path)
                        }
                    }
                }
                sources = settings.sources.map { URL(fileURLWithPath: $0) }
                destination = URL(fileURLWithPath: settings.destination)
                folderOverlayEnabled = settings.folderOverlayEnabled ?? false
                folderDockLayout = (settings.folderDockLayout ?? .init()).sanitized
                folderSuggestionRules = settings.folderSuggestionRules ?? []
            }
            refreshHistory()
        } catch { self.error = error.localizedDescription; canPersist = false }
    }
    private var settingsURL: URL { stateDirectory.appendingPathComponent("Settings.json") }
    var wordmarkCue: TileWordmarkCue {
        if error != nil { return .check }
        if busy { return .wait }
        if let wordmarkResult { return wordmarkResult }
        return plan == nil && quickFile == nil ? .tile : .ready
    }
    var proposals: [Proposal] { plan?.proposals ?? [] }
    var executable: [Proposal] { proposals.filter { $0.decision.executable } }
    var chosen: [Proposal] { proposals.filter { selected.contains($0.id) && $0.decision.executable } }
    var visible: [Proposal] {
        proposals.filter { (filter == nil || $0.decision == filter) && (search.isEmpty || $0.source.localizedCaseInsensitiveContains(search) || ($0.destination ?? "").localizedCaseInsensitiveContains(search)) }
    }
    func count(_ decision: Decision) -> Int { proposals.filter { $0.decision == decision }.count }
    func showInFinder(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    func persist(invalidateFolders: Bool = true) {
        if invalidateFolders { folderConfigurationRevision += 1 }
        guard !isDemo, canPersist else { return }
        do {
            let saved = SavedSettings(sources: sources.map(\.path), destination: destination.path, bookmarks: bookmarks, rules: rules,
                                      folderOverlayEnabled: folderOverlayEnabled, folderDockLayout: folderDockLayout,
                                      folderSuggestionRules: folderSuggestionRules)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: settingsURL, options: .atomic)
        } catch { self.error = "설정을 저장하지 못했습니다. \(error.localizedDescription)" }
    }
    func invalidate() { plan = nil; selected = []; message = nil; filter = nil; search = ""; wordmarkResult = nil }
    func remember(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
           let canonical = try? PathSafety.canonicalRoot(url) {
            bookmarks[canonical.path] = data; connectedPaths.insert(canonical.path)
        }
    }
    func addFolders() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "확인할 폴더 선택"; panel.prompt = "폴더 추가"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            let roots = try PathSafety.nonOverlappingRoots(sources + panel.urls)
            panel.urls.forEach(remember); sources = roots; invalidate(); persist()
        } catch { self.error = error.localizedDescription }
    }
    func removeSource(_ url: URL) { guard !busy else { return }; sources.removeAll { $0 == url }; invalidate(); persist() }
    func chooseDestination() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "자료를 모을 폴더 선택"; panel.prompt = "정리 위치 선택"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Planner.validateDestination(url, rules: rules)
            remember(url); destination = try PathSafety.canonicalRoot(url); invalidate(); persist()
        } catch { self.error = error.localizedDescription }
    }
    func addProtectedFolder() {
        let panel = NSOpenPanel(); panel.title = "원래 위치를 유지할 폴더"; panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !rules.protectedPaths.contains(url.path) { rules.protectedPaths.append(url.path); invalidate(); persist() }
    }
    func saveRules(_ updated: OrganizerRules) {
        guard !busy else { return }
        do { try updated.validate(); rules = updated; invalidate(); persist(); message = "규칙을 저장했습니다. 정리 화면에서 다시 분석해 주세요." }
        catch { self.error = error.localizedDescription }
    }
    func assign(_ category: String, to item: Proposal) {
        guard !busy, var current = plan else { return }
        do {
            try Planner.assignCategory(category, proposalID: item.id, plan: &current)
            plan = current; selected.formIntersection(Set(executable.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }
    func toggle(_ item: Proposal) {
        guard !busy, item.decision.executable else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func selectRecommended() { guard !busy else { return }; selected = Set(executable.prefix(500).map(\.id)) }
    func cancel() { cancellation.cancel(); progress.message = "현재 항목을 마친 뒤 중단합니다…" }
    private func start(_ text: String) -> CancellationFlag {
        busy = true; error = nil; message = nil; wordmarkResult = nil; cancellation = CancellationFlag(); progress = .init(0, 0, text); return cancellation
    }
    private func update(_ value: EngineProgress) { progress = value }
    func analyze() {
        guard !busy, engine != nil else { return }
        showFolderBatch = true; page = .organize
        let token = start("자료를 확인하고 있습니다…")
        let inputs = sources, target = destination, config = rules
        invalidate()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Planner.analyze(sources: inputs, destination: target, rules: config, cancelled: { token.cancelled }, progress: { value in Task { @MainActor in self.update(value) } }) }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success(var plan):
                    func rank(_ decision: Decision) -> Int { decision.executable ? 0 : decision == .review ? 1 : decision == .keep ? 2 : 3 }
                    plan.proposals.sort { rank($0.decision) == rank($1.decision) ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : rank($0.decision) < rank($1.decision) }
                    self.plan = plan; self.message = "\(plan.proposals.count)개 항목과 \(plan.referenceFilesChecked)개 코드·문서를 확인했습니다."
                case .failure(is CancellationError): self.message = "분석을 중단했습니다."; self.wordmarkResult = .stop
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func execute() {
        guard !busy, let engine, let current = plan, !chosen.isEmpty else { return }
        confirmExecute = false
        let ids = selected, token = start("선택한 자료를 다시 확인합니다…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try engine.execute(plan: current, selectedIDs: ids, cancelled: { token.cancelled }, progress: { value in Task { @MainActor in self.update(value) } }) }
            Task { @MainActor in
                self.busy = false; self.invalidate(); self.refreshHistory(); self.page = .history
                self.wordmarkResult = .completion(for: result)
                switch result {
                case .success(let run): self.message = run.state == .completed ? "\(run.movedCount)개 항목을 정리했습니다. 이 기록에서 되돌릴 수 있습니다." : run.message
                case .failure(is CancellationError): self.message = "실행 전에 중단했습니다."
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func refreshHistory() {
        guard let engine else { return }
        do {
            let history = try engine.store.history(); records = history.records
            if let id = quickRun?.id, let current = records.first(where: { $0.id == id }) { quickRun = current }
            if !history.errors.isEmpty { error = "일부 기록을 읽지 못했습니다. " + history.errors.joined(separator: "\n") }
        } catch { self.error = error.localizedDescription }
    }

    func setFolderOverlayEnabled(_ enabled: Bool) {
        if !enabled { folderDockEditing = false }
        folderOverlayEnabled = enabled; persist()
    }
    func setFolderDockEditing(_ editing: Bool) {
        guard !busy else { return }
        folderDockEditing = editing
        if editing && !folderOverlayEnabled { setFolderOverlayEnabled(true) }
    }
    func setFolderDockLayout(_ layout: FolderDockLayout) {
        folderDockLayout = layout.sanitized; persist(invalidateFolders: false)
    }
    var overlayDestinationConnected: Bool { isDemo || connectedPaths.contains(destination.path) }
    var overlayAuthorizedSources: [URL] {
        var roots = sources.filter { isDemo || connectedPaths.contains($0.path) }
        if overlayDestinationConnected { roots.append(destination) }
        return roots
    }
    func releaseFolderAccess() {
        releaseReviewAccess?()
        quickScopedFile?.stopAccessingSecurityScopedResource(); quickScopedFile = nil
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }; scopedURLs.removeAll()
    }

    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "정리할 파일 선택"; panel.prompt = "파일 선택"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        if receiveReviewFiles != nil { acceptFilesForReview(panel.urls) }
        else if let url = panel.urls.first, panel.urls.count == 1 { acceptFile(url) }
        else { error = "정리 화면을 연 뒤 파일을 다시 선택해 주세요." }
    }

    func acceptFilesForReview(_ urls: [URL], presentPanel: Bool = false, releaseAccess: (() -> Void)? = nil) {
        guard !busy, let receiveReviewFiles else {
            releaseAccess?(); error = "진행 중인 작업을 마친 뒤 정리 화면에서 다시 선택해 주세요."; return
        }
        guard !urls.isEmpty, urls.count <= 500, urls.allSatisfy({ $0.isFileURL }) else {
            releaseAccess?(); error = "이 Mac의 파일을 한 번에 1~500개 선택해 주세요."; return
        }
        projectReviewActive = true; showFolderBatch = false; page = .organize
        receiveReviewFiles(urls, releaseAccess)
        if presentPanel { openProjectReviewPanel?() }
    }

    func beginReviewPreparation(_ text: String) -> CancellationFlag? {
        guard !busy, engine != nil else { return nil }
        return start(text)
    }

    func finishReviewPreparation(_ failure: Error? = nil) {
        busy = false
        if let failure {
            error = failure is CancellationError ? nil : failure.localizedDescription
            if failure is CancellationError { message = "작업을 중단했습니다. 파일은 원래 위치에 있습니다."; wordmarkResult = .stop }
        }
    }

    func executeReviewPlan(_ plan: ScanPlan, completion: @escaping (Result<RunRecord, Error>) -> Void) {
        guard !busy, let engine else { completion(.failure(OrganizerError("진행 중인 작업을 마친 뒤 실행해 주세요."))); return }
        let token = start("파일과 만들 폴더를 다시 확인합니다…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.filter { $0.decision.executable }.map(\.id)),
                                   cancelled: { token.cancelled }, progress: { value in Task { @MainActor in self.update(value) } })
            }
            Task { @MainActor in
                self.busy = false; self.refreshHistory(); self.wordmarkResult = .completion(for: result)
                completion(result)
            }
        }
    }

    func performOverlayBatchDrop(sources: [URL], candidate: FolderRecommendation, configurationRevision: Int,
                                 completion: @escaping (Result<RunRecord, Error>) -> Void) {
        guard !busy, let engine, folderOverlayEnabled, configurationRevision == folderConfigurationRevision,
              overlayDestinationConnected, !sources.isEmpty, sources.count <= 500 else {
            completion(.failure(OrganizerError("설정이 바뀌었거나 다른 정리가 진행 중입니다. 파일을 다시 옮겨 주세요."))); return
        }
        let inputs = overlayAuthorizedSources, root = destination, config = rules
        let scoped = sources.filter { $0.startAccessingSecurityScopedResource() }
        let token = start("\(sources.count)개 파일과 선택한 폴더를 확인합니다…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> RunRecord in
                let folder = URL(fileURLWithPath: candidate.id)
                guard try SafeFileSystem.identity(at: folder) == candidate.destination.identity else {
                    throw OrganizerError("선택한 폴더가 바뀌었습니다. 다시 선택해 주세요.")
                }
                let plan = try SelectedFilesPlanner.plan(assignments: sources.map { SelectedFileDestination(source: $0, folder: folder) },
                    destinationRoot: folder, registeredRoot: root, authorizedSources: inputs, rules: config,
                    cancelled: { token.cancelled }, progress: { value in Task { @MainActor in self.update(value) } })
                guard plan.destinationAnchorIdentity == candidate.destination.identity else {
                    throw OrganizerError("선택한 폴더가 바뀌었습니다. 다시 선택해 주세요.")
                }
                return try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.map(\.id)), cancelled: { token.cancelled },
                                          progress: { value in Task { @MainActor in self.update(value) } })
            }
            Task { @MainActor in
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                self.busy = false; self.invalidate(); self.refreshHistory(); self.wordmarkResult = .completion(for: result)
                completion(result)
            }
        }
    }

    func acceptFile(_ url: URL) {
        guard !busy else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        let token = start("파일을 확인하고 있습니다…")
        let config = rules, saved = folderSuggestionRules, history = records
        let root = overlayDestinationConnected ? destination : nil
        let common = [FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                      FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first].compactMap { $0 }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (FileIdentity, [FolderRecommendation]) in
                let identity = try ExistingFileDrop.inspect(url)
                if token.cancelled { throw CancellationError() }
                var catalogue = root.flatMap { try? FolderRecommendations.catalogue(root: $0, rules: config, records: history) } ?? []
                for run in history.prefix(24) where run.state == .completed {
                    for entry in run.entries where entry.state == .moved {
                        let folderURL = URL(fileURLWithPath: entry.destination).deletingLastPathComponent()
                        if var folder = QuickFolderSuggestions.destination(folderURL, rules: config) {
                            folder.lastUsed = run.updatedAt; catalogue.append(folder)
                        }
                    }
                }
                let folders = try QuickFolderSuggestions.recommendations(source: url, catalogue: catalogue, rules: config, remembered: saved, commonFolders: common)
                if token.cancelled { throw CancellationError() }
                return (identity, folders)
            }
            Task { @MainActor in
                self.busy = false
                switch result {
                case .success(let value):
                    self.quickScopedFile?.stopAccessingSecurityScopedResource()
                    self.quickScopedFile = accessing ? url : nil
                    self.quickFile = url; self.quickSourceIdentity = value.0; self.quickFolders = value.1
                    self.quickDestination = nil; self.quickRun = nil; self.rememberQuickChoice = false
                    self.quickRulePrefix = config.matchingProject(url.lastPathComponent)?.1 ?? url.deletingPathExtension().lastPathComponent
                    self.showFolderBatch = false; self.page = .organize
                case .failure(let error):
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    self.error = error is CancellationError ? nil : error.localizedDescription
                }
            }
        }
    }

    func selectQuickFolder(_ item: FolderRecommendation) {
        guard !busy else { return }
        quickDestination = item; error = nil; message = nil
    }

    func chooseQuickFolder() {
        guard !busy, quickFile != nil else { return }
        let panel = NSOpenPanel(); panel.title = "파일을 옮길 폴더 선택"; panel.prompt = "이 폴더 선택"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = quickDestination.map { URL(fileURLWithPath: $0.id) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useQuickFolder(url)
    }

    func useQuickFolder(_ url: URL) {
        guard !busy else { return }
        guard let folder = QuickFolderSuggestions.destination(url, rules: rules) else {
            error = "이 폴더에 접근할 수 없습니다. 쓰기 가능한 다른 폴더를 선택해 주세요."; return
        }
        if let file = quickFile, (try? SafeFileSystem.identity(at: file.deletingLastPathComponent())) == folder.identity {
            error = "파일이 이미 이 폴더에 있습니다. 다른 폴더를 선택해 주세요."; return
        }
        remember(url)
        selectQuickFolder(.init(destination: folder, reason: "직접 선택"))
    }

    func createQuickFolder(name: String, parent: URL) -> Bool {
        guard !busy else { return false }
        do {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try PathSafety.validateComponent(name)
            let parent = try PathSafety.canonicalRoot(parent)
            try SafeFileSystem.validateDirectory(parent); try Planner.validateDestination(parent, rules: rules)
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try Planner.validateDestination(url, rules: rules)
            _ = try SafeFileSystem.createDirectory(url)
            useQuickFolder(url)
            return quickDestination?.id == url.path
        } catch { self.error = error.localizedDescription; return false }
    }

    func resetQuickMove() {
        guard !busy else { return }
        quickScopedFile?.stopAccessingSecurityScopedResource(); quickScopedFile = nil
        quickFile = nil; quickSourceIdentity = nil; quickDestination = nil; quickFolders = []; quickRun = nil
        rememberQuickChoice = false; quickRulePrefix = ""; error = nil; message = nil; wordmarkResult = nil
        showFolderBatch = false; page = .organize
    }

    func removeSuggestionRule(_ id: UUID) {
        guard !busy else { return }
        folderSuggestionRules.removeAll { $0.id == id }; persist()
    }

    func executeQuickMove() {
        guard !busy, let engine, let file = quickFile, let folder = quickDestination, let identity = quickSourceIdentity else { return }
        let prefix = quickRulePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberQuickChoice {
            do {
                try PathSafety.validateComponent(prefix)
                guard OrganizerRules.hasPrefix(file.lastPathComponent, prefix) else { throw OrganizerError("이 파일 이름의 시작 부분을 입력해 주세요.") }
            } catch { self.error = error.localizedDescription; return }
        }
        let newRule = rememberQuickChoice ? FolderSuggestionRule(prefix: prefix, folderPath: folder.id) : nil
        let token = start("파일과 폴더를 확인합니다…"), config = rules, inputs = overlayAuthorizedSources
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let plan = try Planner.singleFilePlan(source: file, folder: folder.destination, registeredRoot: URL(fileURLWithPath: folder.id),
                                                      authorizedSources: inputs, rules: config, expectedSourceIdentity: identity)
                return try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.map(\.id)), cancelled: { token.cancelled },
                                          progress: { value in Task { @MainActor in self.update(value) } })
            }
            Task { @MainActor in
                self.busy = false; self.refreshHistory(); self.wordmarkResult = .completion(for: result)
                switch result {
                case .success(let run):
                    self.quickRun = run
                    if run.state == .completed, let rule = newRule {
                        self.folderSuggestionRules.removeAll { $0.prefix.localizedCaseInsensitiveCompare(rule.prefix) == .orderedSame }
                        self.folderSuggestionRules.append(rule)
                    }
                    self.persist()
                case .failure(let error): self.error = error is CancellationError ? "이동을 중단했습니다." : error.localizedDescription
                }
            }
        }
    }

    func undoQuickMove() {
        guard let run = quickRun else { return }
        undoOverlayDrop(run) { result in
            switch result {
            case .success(let record): self.quickRun = record
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func performOverlayDrop(source: URL, candidate: FolderRecommendation, configurationRevision: Int,
                            completion: @escaping (Result<RunRecord, Error>) -> Void) {
        guard !busy, let engine, folderOverlayEnabled, configurationRevision == folderConfigurationRevision,
              overlayDestinationConnected else {
            completion(.failure(OrganizerError("설정이 바뀌었거나 다른 정리가 진행 중입니다. 파일을 다시 옮겨 주세요."))); return
        }
        let inputs = overlayAuthorizedSources, root = destination, config = rules
        // The planner derives the original parent and checks actual access after the drop.
        let accessing = source.startAccessingSecurityScopedResource()
        let token = start("파일과 선택한 폴더를 확인합니다…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let plan = try Planner.singleFilePlan(source: source, folder: candidate.destination, registeredRoot: root,
                                                      authorizedSources: inputs, rules: config)
                return try engine.execute(plan: plan, selectedIDs: Set(plan.proposals.map(\.id)), cancelled: { token.cancelled },
                                          progress: { value in Task { @MainActor in self.update(value) } })
            }
            Task { @MainActor in
                if accessing { source.stopAccessingSecurityScopedResource() }
                self.busy = false; self.invalidate(); self.refreshHistory()
                self.wordmarkResult = .completion(for: result)
                completion(result)
            }
        }
    }

    func undoOverlayDrop(_ record: RunRecord, completion: @escaping (Result<RunRecord, Error>) -> Void) {
        guard !busy, let engine else { completion(.failure(OrganizerError("다른 작업을 마친 뒤 되돌려 주세요."))); return }
        _ = start("원래 위치와 자료를 확인합니다…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try engine.undo(record.id, progress: { value in Task { @MainActor in self.update(value) } }) }
            Task { @MainActor in
                self.busy = false; self.invalidate(); self.refreshHistory()
                self.wordmarkResult = .completion(for: result)
                completion(result)
            }
        }
    }
    func handleRecord(_ record: RunRecord, undo: Bool) {
        guard !busy, let engine else { return }; confirmUndo = nil
        _ = start(undo ? "원래 위치와 자료를 확인합니다…" : "현재 파일 상태를 확인합니다…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { undo ? try engine.undo(record.id, progress: { value in Task { @MainActor in self.update(value) } }) : try engine.inspect(record.id) }
            Task { @MainActor in
                self.busy = false; self.refreshHistory()
                self.wordmarkResult = .completion(for: result)
                switch result {
                case .success(let value): self.message = value.message ?? (value.state == .undone ? "자료를 원래 위치로 되돌렸습니다." : "실제 파일과 기록의 상태를 확인했습니다.")
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
}
