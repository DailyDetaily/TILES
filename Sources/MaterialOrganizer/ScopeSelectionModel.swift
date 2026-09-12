import AppKit
import Combine
import OrganizerCore

struct ScopeLocation: Identifiable, Equatable {
    var path: String
    var name: String
    var selected = false
    var isDefault = false
    var isConnected = false
    var connectionError: String?
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// Stages source scope without reading document content or starting a review.
@MainActor final class ScopeSelectionModel: ObservableObject {
    @Published var mode: OrganizationScopeMode = .files {
        didSet {
            guard mode != oldValue else { return }
            if mode == .all {
                for index in locations.indices { locations[index].selected = locations[index].isConnected }
            }
            refresh()
        }
    }
    @Published var includeSubfolders = false { didSet { if includeSubfolders != oldValue { refresh() } } }
    @Published private(set) var selectedFiles: [URL] = []
    @Published private(set) var locations: [ScopeLocation] = []
    @Published private(set) var candidateURLs: [URL] = []
    @Published private(set) var isScanning = false
    @Published private(set) var notice: String?
    @Published private(set) var error: String?
    @Published private(set) var storeReadable = true
    @Published private(set) var discovery = OrganizationScopeResult()

    let owner: AppModel
    private let store: OrganizationScopeStateStore
    private var state = OrganizationScopeState()
    private let queue = DispatchQueue(label: "MaterialOrganizer.scope-discovery", qos: .userInitiated)
    private var cancellation = CancellationFlag()
    private var generation = UUID()
    private var scopedURLs: [String: URL] = [:]
    private var stagedFileScopes: [String: URL] = [:]
    private var fileSelectionNotice: String?

    init(owner: AppModel) {
        self.owner = owner
        store = OrganizationScopeStateStore(url: owner.stateDirectory.appendingPathComponent("ScopeState.json"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        locations = [
            ScopeLocation(path: home.appendingPathComponent("Desktop").path, name: "바탕화면", isDefault: true),
            ScopeLocation(path: home.appendingPathComponent("Downloads").path, name: "다운로드", isDefault: true)
        ]
        load()
    }

    deinit {
        cancellation.cancel()
        scopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
        stagedFileScopes.values.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    var selectedLocationCount: Int { mode == .files ? 0 : locations.filter(\.selected).count }
    var connectedLocationCount: Int { locations.filter(\.isConnected).count }
    var candidateCount: Int { discovery.totalCandidates }
    var skippedCount: Int { discovery.skippedCount }
    var preservedFolderCount: Int { discovery.preservedFolderCount }
    var overflowCount: Int { discovery.overflowCount }
    var hasOverflow: Bool { overflowCount > 0 || discovery.scanLimitReached }
    var canPreview: Bool { storeReadable && !isScanning && !owner.busy && !candidateURLs.isEmpty && !hasOverflow }
    var canRefresh: Bool {
        storeReadable && !isScanning && !owner.busy &&
            (mode == .files ? !selectedFiles.isEmpty : locations.contains { $0.selected && $0.isConnected })
    }
    var summary: String {
        if isScanning { return "선택한 범위의 파일을 확인하고 있어요" }
        if mode == .files, selectedFiles.isEmpty { return "정리할 파일을 놓거나 선택해 주세요" }
        if mode != .files, selectedLocationCount == 0 {
            return mode == .all ? "전체에 포함할 정리 위치를 연결해 주세요" : "정리할 폴더를 선택해 주세요"
        }
        if discovery.scanLimitReached { return "확인 범위가 넓어요. 폴더를 나누어 선택해 주세요" }
        if hasOverflow { return "\(candidateCount)개 파일 · 한 번에 최대 500개까지 정리할 수 있어요" }
        if candidateCount == 0 { return "선택한 범위에 정리할 일반 파일이 없어요" }
        return "\(candidateCount)개 파일의 정리 위치를 추천할게요"
    }

    func setMode(_ value: OrganizationScopeMode) { guard !owner.busy else { return }; mode = value }

    func chooseFiles() {
        guard !owner.busy, storeReadable else { return }
        let panel = NSOpenPanel(); panel.title = "정리할 파일 선택"; panel.prompt = "파일 추가"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    func addFiles(_ urls: [URL]) {
        guard !owner.busy, storeReadable else { return }
        var seen = Set(selectedFiles.map { PathSafety.lexicalURL($0).path })
        var rejectedFolders = 0, rejectedFiles = 0
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil else { rejectedFiles += 1; continue }
            let key = PathSafety.lexicalURL(url).path
            guard !seen.contains(key) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            do {
                let identity = try SafeFileSystem.identity(at: url)
                if identity.kind == "directory" {
                    rejectedFolders += 1
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    continue
                }
                _ = try ExistingFileDrop.inspect(url)
                seen.insert(key)
                if accessing { stagedFileScopes[key] = url }
                selectedFiles.append(url)
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                rejectedFiles += 1
            }
        }
        var notes: [String] = []
        if rejectedFolders > 0 { notes.append("폴더 \(rejectedFolders)개는 파일 목록에 넣지 않았습니다. ‘선택 폴더’에서 연결해 주세요") }
        if rejectedFiles > 0 { notes.append("읽을 수 있는 일반 파일이 아닌 \(rejectedFiles)개 항목은 제외했습니다") }
        fileSelectionNotice = notes.isEmpty ? nil : notes.joined(separator: ". ")
        selectedFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if mode != .files { mode = .files } else { refresh() }
    }

    func addFolders() {
        guard !owner.busy, storeReadable else { return }
        let panel = NSOpenPanel(); panel.title = "정리할 폴더 선택"; panel.prompt = "폴더 연결"
        panel.message = "이 폴더의 파일을 확인합니다. 폴더 자체와 보호된 항목은 원래 위치를 유지합니다."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        connectFolders(panel.urls)
    }

    /// Explicit selection authorizes these sources; no destination is selected here.
    @discardableResult func connectFolders(_ urls: [URL]) -> Bool {
        guard !owner.busy, storeReadable else { return false }
        var newScopes: [String: URL] = [:]
        do {
            var updated = state
            var newLocations = locations
            for original in urls {
                let accessing = original.startAccessingSecurityScopedResource()
                do {
                    let url = try validateFolder(original)
                    let bookmark = owner.isDemo ? nil : try original.bookmarkData(options: .withSecurityScope,
                        includingResourceValuesForKeys: nil, relativeTo: nil)
                    let connection = OrganizationScopeConnection(path: url.path, bookmark: bookmark,
                        identity: try SafeFileSystem.identity(at: url))
                    updated.connections.removeAll { $0.path == url.path }
                    updated.connections.append(connection)
                    if let index = newLocations.firstIndex(where: { $0.path == url.path }) {
                        newLocations[index].selected = true; newLocations[index].isConnected = true
                        newLocations[index].connectionError = nil
                    } else {
                        newLocations.append(.init(path: url.path, name: url.lastPathComponent, selected: true, isConnected: true))
                    }
                    if accessing {
                        newScopes[url.path]?.stopAccessingSecurityScopedResource()
                        newScopes[url.path] = original
                    }
                } catch {
                    if accessing { original.stopAccessingSecurityScopedResource() }
                    throw error
                }
            }
            try store.save(updated)
            state = updated; locations = newLocations
            for (path, url) in newScopes {
                scopedURLs[path]?.stopAccessingSecurityScopedResource(); scopedURLs[path] = url
            }
            error = nil
            if mode == .files { mode = .folders } else { refresh() }
            return true
        } catch {
            newScopes.values.forEach { $0.stopAccessingSecurityScopedResource() }
            self.error = error.localizedDescription
            if !store.isWritable { storeReadable = false }
            return false
        }
    }

    func toggleLocation(_ id: String) {
        guard !owner.busy, storeReadable, let index = locations.firstIndex(where: { $0.id == id }) else { return }
        if locations[index].isConnected {
            locations[index].selected.toggle()
            if mode == .files { mode = .folders } else { refresh() }
            return
        }
        let location = locations[index]
        if connectFolders([location.url]) { return }
        guard storeReadable else { return }
        // The system chooser can grant access to a quick location when ordinary access was denied.
        let panel = NSOpenPanel(); panel.title = "\(location.name) 연결"; panel.prompt = "이 폴더 연결"
        panel.message = "정리할 폴더에 접근할 수 있도록 위치를 선택해 주세요."
        panel.directoryURL = location.url
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { connectFolders([url]) }
    }

    func removeFile(_ url: URL) {
        guard !owner.busy else { return }
        let path = PathSafety.lexicalURL(url).path
        selectedFiles.removeAll { PathSafety.lexicalURL($0).path == path }
        stagedFileScopes.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        refresh()
    }

    func refresh() {
        cancellation.cancel(); generation = UUID()
        candidateURLs = []; discovery = .init(); notice = mode == .files ? fileSelectionNotice : nil
        guard storeReadable else { isScanning = false; return }
        error = nil
        let files = mode == .files ? selectedFiles : []
        let folders = mode == .files ? [] : locations.filter { $0.selected && $0.isConnected }.map(\.url)
        guard !files.isEmpty || !folders.isEmpty else { isScanning = false; return }
        let recursive = mode != .files && includeSubfolders
        let excludedFolders = recursive ? locations.filter { location in
            location.isConnected && !location.selected && folders.contains {
                $0.path != location.path && PathSafety.contains($0, location.url)
            }
        }.map(\.url) : []
        let captured = generation, rules = owner.rules, inputNotice = mode == .files ? fileSelectionNotice : nil
        let token = CancellationFlag(); cancellation = token; isScanning = true
        queue.async { [weak self] in
            let result = Result { try OrganizationScopeDiscovery.scan(files: files, folders: folders,
                includeSubfolders: recursive, excludedFolders: excludedFolders, rules: rules, cancelled: { token.cancelled }) }
            Task { @MainActor in
                guard let self, self.generation == captured else { return }
                self.isScanning = false
                switch result {
                case .success(let value):
                    self.discovery = value; self.candidateURLs = value.files
                    var notes = [inputNotice].compactMap { $0 }
                    if value.preservedFolderCount > 0 { notes.append("폴더 \(value.preservedFolderCount)개는 제자리에 유지합니다") }
                    if value.skippedCount > 0 { notes.append("선택 제외·보호·숨김·접근 불가 항목 \(value.skippedCount)개는 제외했습니다") }
                    if value.overflowCount > 0 { notes.append("총 \(value.totalCandidates)개입니다. 500개 이하로 범위를 줄여 주세요") }
                    if value.scanLimitReached { notes.append("조사 한도에 도달해 전체 개수를 확인하지 못했습니다. 범위를 줄여 주세요") }
                    if value.unreadableCount > 0, let warning = value.warnings.first { notes.append(warning) }
                    self.notice = notes.isEmpty ? nil : notes.joined(separator: ". ")
                case .failure(is CancellationError): self.notice = "범위 확인을 중단했습니다. 다시 확인할 수 있습니다."
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        cancellation.cancel(); generation = UUID(); isScanning = false
        candidateURLs = []; discovery = .init(); notice = "범위 확인을 중단했습니다. 다시 확인할 수 있습니다."
    }

    func resetSelection() {
        cancel()
        selectedFiles = []; fileSelectionNotice = nil
        stagedFileScopes.values.forEach { $0.stopAccessingSecurityScopedResource() }; stagedFileScopes = [:]
        for index in locations.indices { locations[index].selected = false }
        mode = .files; includeSubfolders = false
        notice = nil
        if storeReadable { error = nil }
    }

    func preview(using review: ProjectReviewModel) {
        guard canPreview else { return }
        // Hold source access separately while review owns this intake, even if staging is later reset.
        let accessURLs = mode == .files ? Array(stagedFileScopes.values) : locations.filter(\.selected).compactMap { scopedURLs[$0.path] }
        let borrowed = accessURLs.filter { $0.startAccessingSecurityScopedResource() }
        owner.page = .organize; owner.showFolderBatch = false; owner.projectReviewActive = true
        review.receiveScope(candidateURLs, releaseAccess: { borrowed.forEach { $0.stopAccessingSecurityScopedResource() } })
    }

    private func validateFolder(_ original: URL) throws -> URL {
        guard original.isFileURL, original.host == nil || original.host == "" || original.host == "localhost" else {
            throw OrganizerError("이 Mac의 폴더를 선택해 주세요.")
        }
        let values = try original.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .volumeIsLocalKey])
        guard values.isSymbolicLink != true, values.isAliasFile != true, values.isPackage != true,
              values.volumeIsLocal == true else { throw OrganizerError("바로가기나 앱 묶음 대신 이 Mac의 일반 폴더를 선택해 주세요.") }
        // Reject linked ancestors before canonicalization can hide them.
        try SafeFileSystem.validateDirectory(original)
        let url = try PathSafety.canonicalRoot(original)
        if let reason = try SafeFileSystem.protectionReason(url, rules: owner.rules, includeDescendantPaths: false) {
            throw OrganizerError(reason)
        }
        return url
    }

    private func load() {
        do {
            state = try store.load()
            for connection in state.connections {
                var restoredScope: URL?
                do {
                    let original: URL
                    if let bookmark = connection.bookmark {
                        var stale = false
                        original = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
                        guard !stale else { throw OrganizerError("폴더 접근 권한을 다시 연결해 주세요.") }
                    } else if owner.isDemo { original = URL(fileURLWithPath: connection.path) }
                    else { throw OrganizerError("저장한 접근 권한이 없어 폴더를 다시 연결해야 합니다.") }
                    if original.startAccessingSecurityScopedResource() { restoredScope = original }
                    let url = try validateFolder(original)
                    guard url.path == connection.path, try SafeFileSystem.identity(at: url) == connection.identity else {
                        throw OrganizerError("연결한 폴더가 바뀌었습니다. 다시 선택해 주세요.")
                    }
                    if let restoredScope { scopedURLs[url.path] = restoredScope }
                    updateLocation(connection.path, connected: true, failure: nil)
                } catch {
                    restoredScope?.stopAccessingSecurityScopedResource()
                    updateLocation(connection.path, connected: false, failure: error.localizedDescription)
                    notice = "일부 위치의 접근 권한을 다시 연결해 주세요."
                }
            }
        } catch {
            storeReadable = false; self.error = error.localizedDescription
        }
    }

    private func updateLocation(_ path: String, connected: Bool, failure: String?) {
        if let index = locations.firstIndex(where: { $0.path == path }) {
            locations[index].isConnected = connected; locations[index].connectionError = failure
        } else {
            locations.append(.init(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                isConnected: connected, connectionError: failure))
        }
    }
}
