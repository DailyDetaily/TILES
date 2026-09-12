import AppKit
import Combine
import Darwin
import OrganizerCore

struct ReviewSavedFile: Codable {
    var path: String
    var projectID: UUID?
    var folder: String?
    var included: Bool = true
    var version: ProjectFileVersion?
    var explicitlyAssigned: Bool = false
    var bookmark: Data?
}

struct ReviewQueuedBatch: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var origin: String
    var files: [ReviewSavedFile]
}

struct ProjectReviewState: Codable {
    var version = 1
    var projects: [ProjectDefinition] = []
    var workspaceRootPath: String?
    var contentEnabled = true
    var batches: [ReviewQueuedBatch] = []
    /// Absent in older states. Managed locations never supply semantic project evidence.
    var automaticLocationRoots: [UUID: String]?
}

struct ProjectReviewRow: Identifiable {
    var evidence: FileEvidence
    var projectID: UUID?
    /// nil needs a choice; an empty path explicitly chooses the project root.
    var folder: String?
    var included = true
    var explicitlyAssigned = false
    var ruleReason: String?
    var ruleConflict = false
    var id: UUID { evidence.id }
    var isReady: Bool { included && !ruleConflict && evidence.sourceIdentity != nil && evidence.readStatus != .cancelled && projectID != nil && folder != nil }
}

@MainActor final class ProjectReviewModel: ObservableObject {
    @Published private(set) var projects: [ProjectDefinition] = []
    @Published private(set) var automaticLocationRoots: [UUID: String] = [:]
    @Published private(set) var workspaceRoot: URL?
    @Published private(set) var batches: [ReviewQueuedBatch] = []
    @Published private(set) var rows: [ProjectReviewRow] = []
    @Published private(set) var activeBatchID: UUID?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isPreparing = false
    @Published private(set) var preparedPlan: ScanPlan?
    @Published private(set) var lastRun: RunRecord?
    @Published var showProjectSetup = false
    @Published var editingProject: ProjectDefinition?
    @Published var contentEnabled = true
    @Published var notice: String?
    @Published var failure: String?
    @Published private(set) var storeReadable = true
    let owner: AppModel
    let assistance: ProjectReviewAssistance
    private let stateURL: URL
    private var generation = UUID()
    private var analysisTask: Task<Void, Never>?
    private var scopedFiles: [String: URL] = [:]
    private var externalAccess: [() -> Void] = []
    private var preparingProjectIDs = Set<UUID>()
    private var plannedVersions: [String: ProjectFileVersion] = [:]
    private static let maximumStoredBytes = 8 * 1_024 * 1_024
    private static let maximumBatches = 200

    init(owner: AppModel) {
        self.owner = owner
        assistance = ProjectReviewAssistance(stateDirectory: owner.stateDirectory)
        stateURL = owner.stateDirectory.appendingPathComponent("ReviewState.json")
        if owner.isDemo { workspaceRoot = owner.destination }
        load()
        owner.receiveReviewFiles = { [weak self] urls, release in
            guard let self else { release?(); return }
            self.receive(urls, releaseAccess: release)
        }
        owner.releaseReviewAccess = { [weak self] in self?.shutdown() }
    }

    var isActive: Bool { activeBatchID != nil || preparedPlan != nil || lastRun != nil }
    var readyCount: Int { rows.filter(\.isReady).count }
    var unresolvedCount: Int { rows.filter { $0.included && !$0.isReady }.count }
    var pendingCount: Int { batches.reduce(0) { $0 + $1.files.count } }
    var canPreview: Bool { !owner.busy && readyCount > 0 && storeReadable }
    var selectedProjectIDs: Set<UUID> { Set(rows.filter(\.included).compactMap(\.projectID)) }
    var singleSelectedProject: ProjectDefinition? {
        guard selectedProjectIDs.count == 1, let id = selectedProjectIDs.first else { return nil }
        return project(id)
    }
    var newDirectoryPaths: [String] {
        guard let plan = preparedPlan, let creation = plan.directoryCreationPlan else { return [] }
        return creation.paths.filter { creation.existingIdentities[$0] == nil }
    }
    func project(_ id: UUID?) -> ProjectDefinition? { projects.first { $0.id == id } }
    var savedProjects: [ProjectDefinition] { projects.filter { !isAutomaticLocation($0.id) } }
    func isAutomaticLocation(_ id: UUID?) -> Bool { id.map { automaticLocationRoots[$0] != nil } ?? false }
    func projectName(_ row: ProjectReviewRow) -> String {
        guard let project = project(row.projectID) else { return "위치 확인 필요" }
        return isAutomaticLocation(project.id) ? URL(fileURLWithPath: project.rootPath).lastPathComponent : project.name
    }
    func destinationFolder(_ row: ProjectReviewRow) -> String? {
        guard let project = project(row.projectID), let folder = row.folder else { return nil }
        let root = URL(fileURLWithPath: project.rootPath)
        return (folder.isEmpty ? root : root.appendingPathComponent(folder)).path
    }
    func destination(_ row: ProjectReviewRow) -> String? {
        destinationFolder(row).map { URL(fileURLWithPath: $0).appendingPathComponent(row.evidence.name).path }
    }
    func recommendationReason(_ row: ProjectReviewRow) -> String {
        if row.explicitlyAssigned, row.folder != nil { return "직접 지정한 정리 위치" }
        if let reason = row.ruleReason { return reason }
        if isAutomaticLocation(row.projectID) {
            return "프로젝트 단서가 없어 원래 위치 안에서 확장자 기준으로 \(row.evidence.kind.label) 폴더를 추천했습니다."
        }
        if let id = row.projectID, let candidate = row.evidence.projectCandidates.first(where: { $0.projectID == id }) {
            return candidate.reasons.joined(separator: " · ")
        }
        if row.evidence.projectMatch == .ambiguous { return "여러 프로젝트 단서가 겹칩니다. 정리할 위치를 선택해 주세요." }
        return row.evidence.reasons.last ?? "정리할 위치를 확인해 주세요."
    }

    func setContentEnabled(_ enabled: Bool) {
        guard !owner.busy else { return }
        contentEnabled = enabled; persist()
        if activeBatchID != nil { analyzeActive() }
    }

    func chooseWorkspace() {
        guard !owner.busy else { return }
        let panel = NSOpenPanel(); panel.title = "프로젝트를 보관할 기준 폴더"; panel.prompt = "이 위치 사용"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = workspaceRoot ?? owner.destination
        if panel.runModal() == .OK, let url = panel.url { useWorkspace(url) }
    }

    @discardableResult func useWorkspace(_ url: URL) -> Bool {
        do {
            let root = try PathSafety.canonicalRoot(url)
            try SafeFileSystem.validateDirectory(root); try Planner.validateDestination(root, rules: owner.rules)
            owner.remember(url); owner.destination = root; owner.persist()
            workspaceRoot = root; invalidatePlan(); persist(); return true
        } catch { failure = error.localizedDescription; return false }
    }

    func receive(_ urls: [URL], releaseAccess: (() -> Void)? = nil) {
        guard storeReadable, !urls.isEmpty else { releaseAccess?(); failure = "대기 목록을 읽을 수 없어 새 파일을 저장하지 않았습니다."; return }
        guard !owner.busy else { releaseAccess?(); failure = "진행 중인 작업을 마친 뒤 파일을 다시 선택해 주세요."; return }
        guard urls.allSatisfy(Self.isLocalFileURL) else {
            releaseAccess?(); failure = "이 Mac에 있는 파일 경로만 정리할 수 있습니다."; return
        }
        let previous = mutationSnapshot()
        saveActiveChoices()
        let unique = Array(Dictionary(urls.map { (Self.queueKey($0.path), $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let currentFiles = lastRun == nil ? batches.first(where: { $0.id == activeBatchID })?.files ?? [] : []
        let existing = Set(batches.flatMap { $0.files.map { Self.queueKey($0.path) } })
        let additions = unique.filter { !existing.contains(Self.queueKey($0.path)) }
        let incoming = Set(unique.map { Self.queueKey($0.path) })
        let currentIndex = currentFiles.isEmpty ? nil : batches.firstIndex { $0.id == activeBatchID }
        let relatedIndex = batches.firstIndex { batch in batch.files.contains { incoming.contains(Self.queueKey($0.path)) } }
        let targetIndex: Int?
        if additions.isEmpty {
            targetIndex = currentIndex.flatMap { index in
                batches[index].files.contains { incoming.contains(Self.queueKey($0.path)) } ? index : nil
            } ?? relatedIndex
        } else {
            targetIndex = currentIndex
        }
        let targetFiles = targetIndex.map { batches[$0].files } ?? []
        guard targetFiles.count + additions.count <= 500 else {
            restore(previous)
            releaseAccess?(); failure = "현재 묶음에는 최대 500개까지 담을 수 있습니다. 먼저 정리하거나 보류해 주세요."; return
        }
        let switchesBatch = targetIndex.map { batches[$0].id != activeBatchID } ?? true
        guard targetIndex != nil || batches.count < Self.maximumBatches else {
            restore(previous)
            releaseAccess?(); failure = "확인 대기 묶음이 많습니다. 기존 묶음을 정리한 뒤 다시 선택해 주세요."; return
        }
        let previousScopeKeys = Set(scopedFiles.keys)
        for url in unique { acquireScope(url) }
        lastRun = nil; invalidatePlan(); failure = nil
        if let index = targetIndex {
            batches[index].files += additions.map { savedFile($0) }
            activeBatchID = batches[index].id
        } else {
            let batch = ReviewQueuedBatch(origin: "직접 선택", files: additions.map { savedFile($0) })
            batches.append(batch); activeBatchID = batch.id
        }
        rows = []
        guard persist() else {
            restore(previous)
            releaseScopes(except: previousScopeKeys)
            releaseAccess?()
            return
        }
        let activePaths = batches.first { $0.id == activeBatchID }?.files.map(\.path) ?? []
        releaseScopes(except: Set(activePaths))
        if switchesBatch {
            let previousReleases = externalAccess; externalAccess = []; previousReleases.forEach { $0() }
        }
        if let releaseAccess { externalAccess.append(releaseAccess) }
        analyzeActive()
    }

    /// The scope screen replaces the active selection exactly; Dock intake remains additive.
    func receiveScope(_ urls: [URL], releaseAccess: (() -> Void)? = nil) {
        guard storeReadable else {
            releaseAccess?(); failure = "대기 목록을 읽을 수 없어 선택한 범위를 저장하지 않았습니다."; return
        }
        guard !owner.busy else {
            releaseAccess?(); failure = "진행 중인 작업을 마친 뒤 정리할 범위를 다시 선택해 주세요."; return
        }
        guard !urls.isEmpty, urls.count <= 500, urls.allSatisfy(Self.isLocalFileURL) else {
            releaseAccess?(); failure = "이 Mac의 파일을 한 번에 1~500개 선택해 주세요."; return
        }
        let previous = mutationSnapshot()
        saveActiveChoices()
        let unique = Array(Dictionary(urls.map { (Self.queueKey($0.path), $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let selectedKeys = Set(unique.map { Self.queueKey($0.path) })
        let previousActiveFiles = batches.first(where: { $0.id == activeBatchID })?.files ?? []
        let previousActiveKeys = Set(previousActiveFiles.map { Self.queueKey($0.path) })
        let saved = Dictionary((previousActiveFiles + batches.filter { $0.id != activeBatchID }.flatMap(\.files))
            .map { (Self.queueKey($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        let exactFiles = unique.map { url in
            let incoming = savedFile(url)
            guard var previous = saved[Self.queueKey(url.path)] else { return incoming }
            if let bookmark = incoming.bookmark { previous.bookmark = bookmark }
            return previous
        }
        for index in batches.indices {
            batches[index].files.removeAll { selectedKeys.contains(Self.queueKey($0.path)) }
        }
        batches.removeAll { $0.files.isEmpty }
        guard batches.count < Self.maximumBatches else {
            restore(previous)
            releaseAccess?(); failure = "확인 대기 묶음이 많습니다. 기존 묶음을 정리한 뒤 다시 선택해 주세요."; return
        }
        let previousScopeKeys = Set(scopedFiles.keys)
        for url in unique { acquireScope(url) }
        let batch = ReviewQueuedBatch(origin: "선택한 범위", files: exactFiles)
        batches.append(batch); activeBatchID = batch.id
        rows = []; lastRun = nil; invalidatePlan(); failure = nil
        guard persist() else {
            restore(previous)
            releaseScopes(except: previousScopeKeys)
            releaseAccess?()
            return
        }
        // A borrowed folder grant can cover retained files even when their URL has no grant of its own.
        // Keep it until the retained selection closes, or until a completely disjoint scope replaces it.
        if selectedKeys.isDisjoint(with: previousActiveKeys) {
            let previousReleases = externalAccess; externalAccess = []; previousReleases.forEach { $0() }
        }
        if let releaseAccess { externalAccess.append(releaseAccess) }
        releaseScopes(except: Set(exactFiles.map(\.path)).union(unique.map { PathSafety.lexicalURL($0).path }))
        owner.projectReviewActive = true; owner.showFolderBatch = false; owner.page = .organize
        analyzeActive()
    }

    private static func queueKey(_ path: String) -> String {
        PathSafety.lexicalURL(URL(fileURLWithPath: path)).path.precomposedStringWithCanonicalMapping
    }

    private func savedFile(_ url: URL) -> ReviewSavedFile {
        .init(path: PathSafety.lexicalURL(url).path, bookmark: try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Watch ingestion queues paths only; content is read when the user opens the review.
    @discardableResult func enqueueWatchedFiles(_ urls: [URL], origin: String) -> Bool {
        guard storeReadable, urls.allSatisfy(Self.isLocalFileURL) else { return false }
        var queued = Set(batches.flatMap { $0.files.map { Self.queueKey($0.path) } })
        let additions = urls.filter { queued.insert(Self.queueKey($0.path)).inserted }
        guard !additions.isEmpty else { return persist() }
        guard batches.count + (additions.count + 499) / 500 <= Self.maximumBatches else {
            failure = "확인 대기 묶음이 많습니다. 기존 항목을 정리하거나 보류한 뒤 다시 확인해 주세요."; return false
        }
        let previous = batches
        for start in stride(from: 0, to: additions.count, by: 500) {
            let end = min(start + 500, additions.count)
            batches.append(.init(origin: origin, files: additions[start..<end].map { savedFile($0) }))
        }
        if persist() { return true }
        batches = previous; return false
    }

    func openBatch(_ batch: ReviewQueuedBatch, presentPanel: Bool = false) {
        guard !owner.busy else { return }
        if activeBatchID != batch.id { releaseAccess() }
        saveActiveChoices(); activeBatchID = batch.id; lastRun = nil; rows = []; invalidatePlan()
        owner.projectReviewActive = true; owner.showFolderBatch = false; owner.page = .organize
        analyzeActive()
        if presentPanel { owner.openProjectReviewPanel?() }
    }

    func openPending(presentPanel: Bool = false) {
        if let active = batches.first(where: { $0.id == activeBatchID }) { openBatch(active, presentPanel: presentPanel) }
        else if let first = batches.first { openBatch(first, presentPanel: presentPanel) }
        else { owner.projectReviewActive = true; owner.page = .organize; if presentPanel { owner.openProjectReviewPanel?() } }
    }

    func analyzeActive() {
        guard !owner.busy, let batch = batches.first(where: { $0.id == activeBatchID }),
              let cancellation = owner.beginReviewPreparation("파일 이름과 내용을 확인합니다…") else { return }
        saveActiveChoices()
        let savedFiles = batches.first(where: { $0.id == batch.id })?.files ?? batch.files
        for file in savedFiles {
            guard let bookmark = file.bookmark else { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               !stale, PathSafety.lexicalURL(url).path == file.path { acquireScope(url) }
        }
        let generation = UUID(); self.generation = generation
        let projects = savedProjects, content = contentEnabled
        isAnalyzing = true; isPreparing = false; preparedPlan = nil; failure = nil; notice = nil
        analysisTask = Task { [weak self] in
            let evidence = await ProjectFileAnalyzer.analyze(urls: savedFiles.map { URL(fileURLWithPath: $0.path) }, projects: projects,
                contentEnabled: content, cancelled: { cancellation.cancelled }, progress: { done, total in
                    Task { @MainActor [weak self] in self?.owner.progress = .init(done, total, "파일 \(done)/\(total)개 확인") }
                })
            guard let self, self.generation == generation else { return }
            self.isAnalyzing = false; self.owner.finishReviewPreparation(cancellation.cancelled ? CancellationError() : nil)
            self.rows = evidence.map { original in
                var value = original
                let saved = savedFiles.first { $0.path == value.sourcePath }
                let changed = saved?.version != nil && saved?.version != value.sourceVersion
                let savedProject = changed ? nil : self.project(saved?.projectID)
                let candidate = value.projectMatch == .unique ? self.project(value.projectCandidates.first?.projectID) : nil
                // Only explicit choices survive reanalysis. Recommendations must reflect current rules.
                let preserved = (saved?.explicitlyAssigned ?? false) ? savedProject : nil
                let resolution = ProjectReviewRuleResolver.resolve(evidence: value, projects: self.projects, rules: self.assistance.rules)
                let ruleConflict = preserved == nil && resolution.conflict
                let ruleTarget = !ruleConflict ? self.project(resolution.projectID) : nil
                var selectedProject = preserved ?? (ruleConflict ? nil : ruleTarget ?? candidate)
                var folder = preserved != nil ? saved?.folder : nil
                if preserved == nil, ruleTarget != nil { folder = resolution.folder }
                let ruleReason = preserved == nil ? resolution.reason : nil
                if let ruleReason { value.reasons.append(ruleReason) }
                if selectedProject == nil, !ruleConflict, value.projectMatch == .unknown,
                   value.sourceIdentity != nil, value.readStatus != .cancelled, value.readStatus != .invalidFile {
                    do {
                        selectedProject = try self.managedLocation(at: URL(fileURLWithPath: value.sourcePath).deletingLastPathComponent())
                        value.reasons.append("프로젝트 단서가 없어 원래 위치 안에서 파일 종류별 폴더를 추천했습니다.")
                    } catch { value.reasons.append("자동 정리 위치를 준비할 수 없습니다. \(error.localizedDescription)") }
                }
                if let existing = folder, !existing.isEmpty, let project = selectedProject,
                   !project.folders.contains(existing), project.template != .byMonth { folder = nil }
                if folder == nil, let project = selectedProject { folder = value.suggestedFolder(for: project) }
                return .init(evidence: value, projectID: selectedProject?.id, folder: folder,
                             included: (saved?.included ?? true) && value.sourceIdentity != nil && !changed,
                             explicitlyAssigned: !changed && (saved?.explicitlyAssigned ?? false),
                             ruleReason: ruleReason, ruleConflict: ruleConflict)
            }
            if cancellation.cancelled { self.notice = "분석을 중단했습니다. 다시 분석하거나 파일을 보류할 수 있습니다." }
            self.saveActiveChoices(); self.persist()
        }
    }

    func setIncluded(_ id: UUID, _ included: Bool) {
        guard !owner.busy, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].included = included; choicesChanged()
    }
    func includeAll(_ included: Bool) {
        guard !owner.busy else { return }
        for index in rows.indices { rows[index].included = included && rows[index].evidence.sourceIdentity != nil }
        choicesChanged()
    }
    func assignProject(_ projectID: UUID, to rowID: UUID? = nil) {
        guard !owner.busy, let project = project(projectID) else { return }
        for index in rows.indices where rowID == rows[index].id || (rowID == nil && rows[index].included) {
            rows[index].projectID = projectID; rows[index].folder = rows[index].evidence.suggestedFolder(for: project)
            rows[index].explicitlyAssigned = true
            rows[index].ruleReason = nil; rows[index].ruleConflict = false
        }
        choicesChanged()
    }
    func assignFolder(_ folder: String, to rowID: UUID? = nil) {
        guard !owner.busy else { return }
        if !folder.isEmpty, (try? ProjectFolderTree.validatePath(folder)) == nil { failure = "올바른 하위 폴더를 선택해 주세요."; return }
        for index in rows.indices where rowID == rows[index].id || (rowID == nil && rows[index].included) {
            guard let project = project(rows[index].projectID), folder.isEmpty || project.folders.contains(folder) || project.template == .byMonth else { continue }
            rows[index].folder = folder
            rows[index].explicitlyAssigned = true
            rows[index].ruleReason = nil; rows[index].ruleConflict = false
        }
        choicesChanged()
    }

    func selectGroup(_ id: String) {
        guard !owner.busy, let group = clarificationGroups.first(where: { $0.id == id }) else { return }
        let previous = mutationSnapshot()
        for index in rows.indices { rows[index].included = group.rowIDs.contains(rows[index].id) }
        invalidatePlan(); saveActiveChoices()
        if !persist() { restore(previous) }
    }

    func deferGroup(_ id: String) {
        mutateGroup(id) { $0.included = false }
    }

    func assignProject(_ projectID: UUID, toGroup groupID: String) {
        guard let project = project(projectID) else { return }
        mutateGroup(groupID) { row in
            row.projectID = projectID; row.folder = row.evidence.suggestedFolder(for: project)
            row.explicitlyAssigned = true; row.ruleReason = nil; row.ruleConflict = false
        }
    }

    func assignFolder(_ folder: String, toGroup groupID: String) {
        guard let project = projectForGroup(groupID) else { return }
        guard folder.isEmpty || ((try? ProjectFolderTree.validatePath(folder)) != nil &&
            (project.folders.contains(folder) || project.template == .byMonth)) else {
            failure = "현재 프로젝트에 있는 하위 폴더를 선택해 주세요."; return
        }
        mutateGroup(groupID) { row in
            row.folder = folder; row.explicitlyAssigned = true; row.ruleReason = nil; row.ruleConflict = false
        }
    }

    private func mutateGroup(_ id: String, _ change: (inout ProjectReviewRow) -> Void) {
        guard !owner.busy, storeReadable, let group = clarificationGroups.first(where: { $0.id == id }) else { return }
        let previous = mutationSnapshot()
        for index in rows.indices where group.rowIDs.contains(rows[index].id) { change(&rows[index]) }
        invalidatePlan(); saveActiveChoices()
        if !persist() { restore(previous) }
    }

    func chooseDestinationFolder(for rowID: UUID? = nil) {
        guard !owner.busy, storeReadable else { return }
        let panel = NSOpenPanel(); panel.title = "정리할 위치 선택"; panel.prompt = "이 위치로 정리"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if let row = rows.first(where: { $0.id == rowID }), let path = destinationFolder(row) {
            panel.directoryURL = try? SafeFileSystem.nearestExistingDirectory(URL(fileURLWithPath: path))
        }
        if panel.runModal() == .OK, let url = panel.url { _ = assignExistingDestination(url, to: rowID) }
    }

    @discardableResult func assignExistingDestination(_ url: URL, to rowID: UUID? = nil) -> Bool {
        guard !owner.busy, storeReadable else { return false }
        let affected = rows.indices.filter { rowID == rows[$0].id || (rowID == nil && rows[$0].included) }
        guard !affected.isEmpty else { return false }
        let previous = mutationSnapshot()
        do {
            let location = try managedLocation(at: url)
            guard !affected.contains(where: { URL(fileURLWithPath: rows[$0].evidence.sourcePath).deletingLastPathComponent().path == location.rootPath }) else {
                throw OrganizerError("선택한 파일이 이미 이 폴더에 있습니다. 다른 위치를 선택해 주세요.")
            }
            for index in affected {
                rows[index].projectID = location.id; rows[index].folder = ""; rows[index].explicitlyAssigned = true
                rows[index].ruleReason = nil; rows[index].ruleConflict = false
            }
            invalidatePlan(); saveActiveChoices()
            guard persist() else { restore(previous); return false }
            owner.remember(url); owner.persist(invalidateFolders: false); failure = nil
            return true
        } catch { restore(previous); failure = error.localizedDescription; return false }
    }

    /// An internal routing record, not a discovered project or a change to the filesystem.
    private func managedLocation(at url: URL) throws -> ProjectDefinition {
        guard Self.isLocalFileURL(url), let destination = QuickFolderSuggestions.destination(url, rules: owner.rules),
              try URL(fileURLWithPath: destination.path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw OrganizerError("이 Mac에서 읽고 쓸 수 있는 정리 위치를 선택해 주세요.")
        }
        if let existing = projects.first(where: { automaticLocationRoots[$0.id] == destination.path }) { return existing }
        guard projects.count < 100 else { throw OrganizerError("저장된 정리 위치가 100개여서 새 위치를 추천할 수 없습니다.") }
        let project = ProjectDefinition(name: "자동 정리 위치", rootPath: destination.path, template: .byKind)
        try project.validate()
        projects.append(project); automaticLocationRoots[project.id] = destination.path
        return project
    }
    private func choicesChanged() { invalidatePlan(); saveActiveChoices(); persist() }
    private func invalidatePlan() { preparedPlan = nil; plannedVersions = [:]; preparingProjectIDs = [] }

    @discardableResult func saveProject(_ definition: ProjectDefinition, applyToIncluded: Bool = true) -> Bool {
        guard !owner.busy, storeReadable else { return false }
        let previous = mutationSnapshot()
        do {
            var project = definition; project.folders = try ProjectFolderTree.normalized(project.folders); try project.validate()
            guard projects.count < 100 || projects.contains(where: { $0.id == project.id }) else { throw OrganizerError("프로젝트는 100개까지 저장할 수 있습니다.") }
            guard !savedProjects.contains(where: { $0.id != project.id && $0.rootPath.precomposedStringWithCanonicalMapping.lowercased() == project.rootPath.precomposedStringWithCanonicalMapping.lowercased() }) else {
                throw OrganizerError("같은 위치의 프로젝트가 이미 있습니다. 기존 프로젝트를 선택해 주세요.")
            }
            let root = URL(fileURLWithPath: project.rootPath)
            try Planner.validateDestination(root, rules: owner.rules)
            automaticLocationRoots.removeValue(forKey: project.id)
            if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
            else { projects.append(project) }
            if applyToIncluded {
                for index in rows.indices where rows[index].included {
                    rows[index].projectID = project.id
                    rows[index].folder = rows[index].evidence.suggestedFolder(for: project)
                    rows[index].explicitlyAssigned = true
                    rows[index].ruleReason = nil; rows[index].ruleConflict = false
                }
            }
            else {
                for index in rows.indices where rows[index].projectID == project.id {
                    if let folder = rows[index].folder, !folder.isEmpty, !project.folders.contains(folder), project.template != .byMonth {
                        rows[index].folder = nil
                    }
                }
            }
            revalidateRuleDestinations()
            invalidatePlan(); saveActiveChoices()
            guard persist() else { restore(previous); return false }
            showProjectSetup = false; editingProject = nil; failure = nil
            return true
        } catch { restore(previous); failure = error.localizedDescription; return false }
    }

    func newProject() { editingProject = nil; showProjectSetup = true }
    func editProject(_ project: ProjectDefinition) { editingProject = project; showProjectSetup = true }

    func prepare(folderOnly projectID: UUID? = nil) {
        guard !owner.busy, storeReadable else { return }
        revalidateRuleDestinations()
        let chosenRows = projectID == nil ? rows.filter(\.isReady) : []
        let ids = projectID.map { Set([$0]) } ?? Set(chosenRows.compactMap(\.projectID))
        let targets = projects.filter { ids.contains($0.id) }
        guard !targets.isEmpty, !chosenRows.isEmpty || projectID != nil else { failure = "정리할 위치를 먼저 확인해 주세요."; return }
        guard let cancellation = owner.beginReviewPreparation("이동안과 만들 폴더를 확인합니다…") else { return }
        isPreparing = true; failure = nil; lastRun = nil; saveActiveChoices(); persist()
        owner.projectReviewActive = true; owner.showFolderBatch = false; owner.page = .organize
        let config = owner.rules, authorized = owner.overlayAuthorizedSources
        let automaticIDs = Set(automaticLocationRoots.keys)
        let reasons = Dictionary(uniqueKeysWithValues: chosenRows.map { ($0.evidence.sourcePath, recommendationReason($0)) })
        let generation = UUID(); self.generation = generation
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ScanPlan, Error> in
                Result {
                    let targetMap = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
                    let root = try Self.executionRoot(for: targets)
                    var required: [URL] = []
                    for project in targets {
                        try project.validate()
                        let url = URL(fileURLWithPath: project.rootPath)
                        required.append(url)
                        if !automaticIDs.contains(project.id) {
                            required += project.folders.map { url.appendingPathComponent($0, isDirectory: true) }
                        }
                    }
                    var assignments: [SelectedFileDestination] = []
                    for row in chosenRows {
                        guard try row.evidence.matchesCurrentSource(), let id = row.projectID, let project = targetMap[id], let folder = row.folder else {
                            throw OrganizerError("파일이 분석 후 바뀌었습니다. 다시 분석해 주세요: \(row.evidence.name)")
                        }
                        let projectRoot = URL(fileURLWithPath: project.rootPath)
                        if !folder.isEmpty { try ProjectFolderTree.validatePath(folder) }
                        let target = folder.isEmpty ? projectRoot : projectRoot.appendingPathComponent(folder, isDirectory: true)
                        guard PathSafety.contains(projectRoot, target) else { throw OrganizerError("목적지가 프로젝트 밖에 있습니다.") }
                        assignments.append(.init(source: URL(fileURLWithPath: row.evidence.sourcePath), folder: target, expectedSourceIdentity: row.evidence.sourceIdentity))
                    }
                    var plan = try SelectedFilesPlanner.plan(assignments: assignments, destinationRoot: root, authorizedSources: authorized,
                        rules: config, requiredDirectories: required, cancelled: { cancellation.cancelled }, progress: { value in
                            Task { @MainActor [weak self] in self?.owner.progress = value }
                        })
                    for index in plan.proposals.indices {
                        plan.proposals[index].reason = reasons[plan.proposals[index].source] ?? plan.proposals[index].reason
                    }
                    for row in chosenRows where try !row.evidence.matchesCurrentSource() {
                        throw OrganizerError("미리보기를 만드는 중 원본이 바뀌었습니다: \(row.evidence.name)")
                    }
                    return plan
                }
            }.value
            guard let self, self.generation == generation else { return }
            self.isPreparing = false; self.owner.finishReviewPreparation()
            switch result {
            case .success(let plan):
                self.preparedPlan = plan; self.preparingProjectIDs = ids
                self.plannedVersions = Dictionary(uniqueKeysWithValues: chosenRows.compactMap { row in row.evidence.sourceVersion.map { (row.evidence.sourcePath, $0) } })
            case .failure(let error): self.failure = error is CancellationError ? "미리보기를 중단했습니다. 변경한 파일은 없습니다." : error.localizedDescription
            }
        }
    }

    func backToReview() { guard !owner.busy else { return }; invalidatePlan() }

    func executePrepared() {
        guard !owner.busy, let plan = preparedPlan else { return }
        failure = nil
        do {
            for (path, version) in plannedVersions {
                guard try ProjectFileVersion.capture(URL(fileURLWithPath: path)) == version else {
                    throw OrganizerError("미리보기 후 파일이 바뀌었습니다. 다시 분석해 주세요: \(URL(fileURLWithPath: path).lastPathComponent)")
                }
            }
        } catch { failure = error.localizedDescription; invalidatePlan(); return }
        owner.executeReviewPlan(plan) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let run):
                self.lastRun = run; self.preparedPlan = nil
                let moved = Set(run.entries.filter { $0.state == .moved }.map(\.source))
                if let index = self.batches.firstIndex(where: { $0.id == self.activeBatchID }) {
                    self.batches[index].files.removeAll { moved.contains($0.path) }
                    if self.batches[index].files.isEmpty { self.batches.remove(at: index) }
                }
                self.notice = run.state == .completed ? "\(run.movedCount)개 파일 이동 · \(run.createdDirectories.count)개 폴더 생성" : (run.message ?? "일부 항목만 처리했습니다. 기록을 확인해 주세요.")
                self.pruneUnusedAutomaticLocations()
                self.persist(); self.owner.persist()
            case .failure(let error): self.failure = error is CancellationError ? "실행을 중단했습니다." : error.localizedDescription
            }
        }
    }

    func undo() {
        guard let run = lastRun, !owner.busy else { return }
        owner.undoOverlayDrop(run) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let record): self.lastRun = record; self.notice = record.state == .undone ? "원래 위치로 되돌렸습니다." : record.message
            case .failure(let error): self.failure = error.localizedDescription
            }
        }
    }

    func returnToInbox() {
        guard !owner.busy else { return }
        saveActiveChoices(); activeBatchID = nil; rows = []; lastRun = nil; invalidatePlan(); notice = nil; failure = nil
        owner.projectReviewActive = false; persist(); releaseAccess()
    }

    func dismissBatch(_ id: UUID) {
        guard !owner.busy else { return }
        batches.removeAll { $0.id == id }
        if activeBatchID == id { activeBatchID = nil; rows = []; invalidatePlan(); owner.projectReviewActive = false; releaseAccess() }
        pruneUnusedAutomaticLocations()
        persist()
    }

    func preserveOnClose() { saveActiveChoices(); persist() }
    func shutdown() {
        analysisTask?.cancel(); saveActiveChoices(); persist(); releaseAccess()
    }
    private func releaseAccess() {
        releaseScopes(except: [])
        let releases = externalAccess; externalAccess = []; releases.forEach { $0() }
    }

    private func acquireScope(_ url: URL) {
        let key = PathSafety.lexicalURL(url).path
        guard scopedFiles[key] == nil, url.startAccessingSecurityScopedResource() else { return }
        scopedFiles[key] = url
    }

    private func releaseScopes(except paths: Set<String>) {
        for key in Array(scopedFiles.keys) where !paths.contains(key) {
            scopedFiles.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
        }
    }

    private struct MutationSnapshot {
        var projects: [ProjectDefinition]
        var automaticLocationRoots: [UUID: String]
        var batches: [ReviewQueuedBatch]
        var rows: [ProjectReviewRow]
        var activeBatchID: UUID?
        var lastRun: RunRecord?
        var plan: ScanPlan?
        var projectIDs: Set<UUID>
        var versions: [String: ProjectFileVersion]
        var notice: String?
    }

    private func mutationSnapshot() -> MutationSnapshot {
        .init(projects: projects, automaticLocationRoots: automaticLocationRoots, batches: batches, rows: rows, activeBatchID: activeBatchID, lastRun: lastRun,
              plan: preparedPlan, projectIDs: preparingProjectIDs, versions: plannedVersions, notice: notice)
    }

    /// Keep the new persistence error visible while restoring the last usable in-memory state.
    private func restore(_ snapshot: MutationSnapshot) {
        projects = snapshot.projects; automaticLocationRoots = snapshot.automaticLocationRoots; batches = snapshot.batches; rows = snapshot.rows
        activeBatchID = snapshot.activeBatchID; lastRun = snapshot.lastRun; preparedPlan = snapshot.plan
        preparingProjectIDs = snapshot.projectIDs; plannedVersions = snapshot.versions; notice = snapshot.notice
    }

    private func saveActiveChoices() {
        guard !rows.isEmpty, lastRun == nil, let index = batches.firstIndex(where: { $0.id == activeBatchID }) else { return }
        let bookmarks = Dictionary(batches[index].files.compactMap { file in file.bookmark.map { (file.path, $0) } }, uniquingKeysWith: { first, _ in first })
        batches[index].files = rows.map { .init(path: $0.evidence.sourcePath, projectID: $0.projectID, folder: $0.folder,
            included: $0.included, version: $0.evidence.sourceVersion, explicitlyAssigned: $0.explicitlyAssigned, bookmark: bookmarks[$0.evidence.sourcePath]) }
        pruneUnusedAutomaticLocations()
    }

    private func pruneUnusedAutomaticLocations() {
        let retained = Set(batches.flatMap { $0.files.compactMap(\.projectID) })
            .union(lastRun == nil ? rows.compactMap(\.projectID) : [])
            .union(assistance.rules.map(\.projectID))
        let obsolete = Set(automaticLocationRoots.keys).subtracting(retained)
        projects.removeAll { obsolete.contains($0.id) }
        for id in obsolete { automaticLocationRoots.removeValue(forKey: id) }
    }

    /// A project edit may invalidate a saved destination without rereading the source. Never let
    /// an already displayed rule silently follow a renamed/relocated project into a new plan.
    private func revalidateRuleDestinations() {
        for index in rows.indices where !rows[index].explicitlyAssigned && rows[index].ruleReason != nil {
            let resolution = ProjectReviewRuleResolver.resolve(evidence: rows[index].evidence, projects: projects, rules: assistance.rules)
            guard resolution.conflict else { continue }
            rows[index].projectID = nil; rows[index].folder = nil
            rows[index].ruleConflict = true; rows[index].ruleReason = resolution.reason
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            if let size = try stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maximumStoredBytes {
                throw OrganizerError("대기 목록이 저장 한도를 넘었습니다.")
            }
            let data = try Data(contentsOf: stateURL)
            guard data.count <= Self.maximumStoredBytes else { throw OrganizerError("대기 목록이 저장 한도를 넘었습니다.") }
            let state = try JSONDecoder().decode(ProjectReviewState.self, from: data)
            try validateState(state)
            projects = state.projects; automaticLocationRoots = state.automaticLocationRoots ?? [:]
            batches = state.batches; contentEnabled = state.contentEnabled
            workspaceRoot = state.workspaceRootPath.map { URL(fileURLWithPath: $0) } ?? workspaceRoot
        } catch { storeReadable = false; failure = "프로젝트 설정을 읽지 못해 원본 설정을 보존했습니다. \(error.localizedDescription)" }
    }
    @discardableResult func persist() -> Bool {
        guard storeReadable else { return false }
        do {
            let state = ProjectReviewState(projects: projects, workspaceRootPath: workspaceRoot?.path, contentEnabled: contentEnabled, batches: batches,
                                           automaticLocationRoots: automaticLocationRoots.isEmpty ? nil : automaticLocationRoots)
            try validateState(state)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            guard data.count <= Self.maximumStoredBytes else { throw OrganizerError("프로젝트와 대기 목록은 8MB까지 저장할 수 있습니다. 기존 묶음을 정리한 뒤 다시 시도해 주세요.") }
            try writeState(data)
            return true
        } catch { failure = "프로젝트와 대기 목록을 저장하지 못했습니다. \(error.localizedDescription)"; return false }
    }

    private func validateState(_ state: ProjectReviewState) throws {
        guard state.version == 1, state.projects.count <= 100, state.batches.count <= Self.maximumBatches,
              Set(state.projects.map(\.id)).count == state.projects.count,
              Set(state.batches.map(\.id)).count == state.batches.count else {
            throw OrganizerError("프로젝트는 100개, 대기 묶음은 200개까지 저장할 수 있으며 항목 ID가 겹치면 안 됩니다.")
        }
        for project in state.projects { try project.validate() }
        for (id, root) in state.automaticLocationRoots ?? [:] {
            guard let project = state.projects.first(where: { $0.id == id }), project.rootPath == root,
                  project.template == .byKind, project.aliases.isEmpty else {
                throw OrganizerError("자동 정리 위치의 저장 정보가 일치하지 않습니다.")
            }
        }
        for batch in state.batches {
            guard batch.files.count <= 500, Set(batch.files.map(\.path)).count == batch.files.count,
                  batch.files.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\u{0}") }) else {
                throw OrganizerError("한 묶음은 중복되지 않는 로컬 파일 500개까지 저장할 수 있습니다.")
            }
        }
    }

    private func writeState(_ data: Data) throws {
        // Finish permissions before replacing the previous file, so a metadata failure cannot
        // commit new bytes and then incorrectly report that the transaction was rolled back.
        let temporary = stateURL.deletingLastPathComponent().appendingPathComponent(".ReviewState-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OrganizerError("임시 설정을 만들지 못했습니다: \(String(cString: strerror(errno)))") }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        guard rename(temporary.path, stateURL.path) == 0 else {
            throw OrganizerError("이전 설정을 교체하지 못했습니다: \(String(cString: strerror(errno)))")
        }
    }

    nonisolated private static func executionRoot(for projects: [ProjectDefinition]) throws -> URL {
        let anchors = try projects.map { try SafeFileSystem.nearestExistingDirectory(PathSafety.canonicalRoot(URL(fileURLWithPath: $0.rootPath))) }
        guard let first = anchors.first else { throw OrganizerError("프로젝트 위치를 선택해 주세요.") }
        var components = first.pathComponents
        for anchor in anchors.dropFirst() {
            components = Array(zip(components, anchor.pathComponents).prefix { $0 == $1 }.map(\.0))
        }
        guard components.count >= 3 else { throw OrganizerError("같은 사용자 위치와 로컬 디스크 안의 프로젝트를 선택해 주세요.") }
        let root = URL(fileURLWithPath: NSString.path(withComponents: components))
        try SafeFileSystem.validateDirectory(root)
        return root
    }
    nonisolated private static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") && url.query == nil && url.fragment == nil
    }
}
