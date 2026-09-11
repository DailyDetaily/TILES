import AppKit
import Combine
import Foundation
import Darwin
import OrganizerCore
import UserNotifications

/// Opt-in polling while this application is running. This service only queues review inputs.
@MainActor final class FolderWatchService: ObservableObject {
    @Published private(set) var configuration = FolderWatchConfiguration()
    @Published private(set) var pendingCount = 0
    @Published private(set) var status = "폴더 감시 꺼짐"
    @Published private(set) var isLoaded = false
    @Published private(set) var isScanning = false
    @Published private(set) var isSaving = false
    @Published private(set) var notificationsAuthorized = false
    var onReady: (([URL], String) -> Bool)? { didSet { if isLoaded, configuration.enabled { scanNow() } } }
    var onOpenReview: (() -> Void)?

    private let isDemo: Bool
    private let pollInterval: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "MaterialOrganizer.folder-watch", qos: .utility)
    private let store: FolderWatchStateStore
    private let gate = FolderWatchGeneration()
    private var generation = UUID()
    private var state = FolderWatchState()
    private var timer: Timer?
    private var folderURL: URL?
    private var scopeURL: URL?
    private var retiringScopes: [URL] = []
    private var scanCancellation: FolderWatchCancellation?
    private var scanRequested = false
    private var saveCount = 0
    private var storageBlocked = false
    private var stopped = false
    private let notificationDelegate = FolderWatchNotificationDelegate()

    init(stateDirectory: URL, isDemo: Bool = false, pollInterval: TimeInterval = 45, now: @escaping () -> Date = { Date() }) {
        self.isDemo = isDemo; self.pollInterval = pollInterval; self.now = now
        store = FolderWatchStateStore(url: stateDirectory.appendingPathComponent("WatchState.json"))
        gate.update(generation)
        notificationDelegate.openReview = { [weak self] in self?.openReview() }
        if let center = notificationCenter() {
            if center.delegate == nil { center.delegate = notificationDelegate }
            refreshNotificationAuthorization(center)
        }
        let store = self.store
        queue.async { [weak self] in
            let result = Result { try store.load() }
            Task { @MainActor in self?.loaded(result) }
        }
    }

    private func loaded(_ result: Result<FolderWatchState, Error>) {
        guard !stopped else { return }
        switch result {
        case .failure(let error):
            storageBlocked = true; isLoaded = true; status = "감시 기록을 보존하기 위해 중지했습니다. \(error.localizedDescription)"
        case .success(let value):
            state = value; configuration = value.configuration; pendingCount = value.pending.count
            guard value.configuration.folderPath != nil else { isLoaded = true; status = "감시할 폴더를 선택해 주세요."; return }
            let isDemo = self.isDemo, captured = generation
            queue.async { [weak self] in
                let result = Result { try Self.restore(value, isDemo: isDemo) }
                Task { @MainActor in
                    guard let self else {
                        if case .success(let restored) = result { restored.scopeURL?.stopAccessingSecurityScopedResource() }; return
                    }
                    guard !self.stopped, self.generation == captured else {
                        if case .success(let restored) = result { restored.scopeURL?.stopAccessingSecurityScopedResource() }; return
                    }
                    self.isLoaded = true
                    switch result {
                    case .success(let restored):
                        self.state = restored.state; self.configuration = restored.state.configuration
                        self.folderURL = restored.url; self.scopeURL = restored.scopeURL
                        self.pendingCount = self.state.pending.count; self.updateTimer()
                        if restored.state != value { self.persist { [weak self] success in if success { self?.scanNow() } } }
                        else if self.configuration.enabled { self.scanNow() }
                        else { self.status = "폴더 감시 일시 정지" }
                    case .failure(let error):
                        self.status = "감시 폴더를 다시 선택해 주세요. \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func chooseFolder() {
        guard isLoaded, !storageBlocked, !stopped else { return }
        let panel = NSOpenPanel()
        panel.title = "감시할 폴더 선택"; panel.prompt = "선택"
        panel.message = "이 폴더 바로 안의 파일만 정리 추천 대기열에 추가합니다. 파일은 자동으로 이동하지 않습니다."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if let path = configuration.folderPath { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await setFolder(url) }
    }

    /// Explicit folder selection. Never fills in Desktop or another user folder automatically.
    @discardableResult func setFolder(_ url: URL) async -> Bool {
        guard isLoaded, !storageBlocked, !stopped else { return false }
        advanceGeneration(); let captured = generation, isDemo = self.isDemo
        let result: Result<FolderWatchSelection, Error> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Result { try Self.select(url, isDemo: isDemo) }) }
        }
        guard !stopped, generation == captured else {
            if case .success(let selection) = result { selection.scopeURL?.stopAccessingSecurityScopedResource() }; return false
        }
        switch result {
        case .failure(let error): status = error.localizedDescription; return false
        case .success(let selection):
            retireCurrentScope(); folderURL = selection.url; scopeURL = selection.scopeURL
            state.configuration.folderPath = selection.url.path
            state.bookmark = selection.bookmark; state.rootIdentity = selection.identity
            state.observations.removeAll(); state.pending.removeAll()
            configuration = state.configuration; pendingCount = 0
            status = configuration.enabled ? "파일이 안정될 때까지 기다립니다." : "폴더를 선택했습니다. 감시를 켜면 확인을 시작합니다."
            updateTimer()
            return await withCheckedContinuation { continuation in
                persist { [weak self] success in
                    if success, self?.generation == captured, self?.configuration.enabled == true { self?.scanNow() }
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isLoaded, !storageBlocked, !stopped else { return }
        guard !enabled || folderURL != nil else { status = "감시할 폴더를 먼저 선택해 주세요."; return }
        guard state.configuration.enabled != enabled else { if enabled { scanNow() }; return }
        advanceGeneration(); state.configuration.enabled = enabled; configuration = state.configuration
        status = enabled ? "파일이 안정될 때까지 기다립니다." : "폴더 감시 일시 정지"
        updateTimer()
        persist { [weak self] success in if success, enabled { self?.scanNow() } }
    }

    func setDelay(_ seconds: TimeInterval) {
        guard isLoaded, !storageBlocked, !stopped else { return }
        guard seconds.isFinite, (0...31_536_000).contains(seconds) else { status = "올바른 대기 시간을 선택해 주세요."; return }
        guard state.configuration.waitInterval != seconds else { return }
        advanceGeneration(); state.configuration.waitInterval = seconds; configuration = state.configuration
        // A new delay is applied to the same observed versions; delivered versions remain delivered.
        persist { [weak self] success in if success { self?.scanNow() } }
    }

    /// Manual refresh still observes the configured age and stability rules.
    func scanNow() {
        guard isLoaded, !stopped, !storageBlocked, configuration.enabled, let folderURL else { return }
        guard !isScanning, !isSaving else { scanRequested = true; return }
        scanRequested = false; isScanning = true
        let cancellation = FolderWatchCancellation(); scanCancellation = cancellation
        let captured = generation, baseline = state, identity = state.rootIdentity, timestamp = now()
        queue.async { [weak self] in
            let result = Result {
                let files = try FolderWatchPolicy.scan(folder: folderURL, expectedIdentity: identity, cancelled: { cancellation.cancelled })
                var updated = baseline
                FolderWatchPolicy.observe(files, state: &updated, now: timestamp)
                if cancellation.cancelled { throw CancellationError() }
                return updated
            }
            Task { @MainActor in self?.scanned(result, generation: captured) }
        }
    }

    private func scanned(_ result: Result<FolderWatchState, Error>, generation captured: UUID) {
        isScanning = false; scanCancellation = nil
        retiringScopes.forEach { $0.stopAccessingSecurityScopedResource() }; retiringScopes.removeAll()
        guard !stopped, generation == captured, configuration.enabled, !storageBlocked else { drainRequestedScan(); return }
        switch result {
        case .failure(let error):
            if !(error is CancellationError) { status = "감시 폴더를 확인하지 못했습니다. \(error.localizedDescription)" }
            drainRequestedScan()
        case .success(let observedState):
            state = observedState
            pendingCount = state.pending.count
            status = pendingCount > 0 ? "\(pendingCount)개 파일이 검토 대기 중입니다." : "파일이 안정될 때까지 기다립니다."
            persist { [weak self] success in
                guard let self, success, self.generation == captured else { return }
                self.deliverPending()
            }
        }
    }

    private func deliverPending() {
        guard !stopped, !storageBlocked, configuration.enabled, !state.pending.isEmpty, let onReady else { return }
        let captured = generation
        let origin = folderURL?.lastPathComponent ?? "감시 폴더"
        var accepted: [FolderWatchFileVersion] = []
        // Work in the same 500-file bound as manual review intake.
        let ready = state.pending
        for start in stride(from: 0, to: ready.count, by: FolderWatchPolicy.deliveryBatchLimit) {
            let batch = Array(ready[start..<min(ready.count, start + FolderWatchPolicy.deliveryBatchLimit)])
            guard onReady(batch.map(\.url), origin) else { break }
            accepted.append(contentsOf: batch)
        }
        guard !accepted.isEmpty else { return }
        FolderWatchPolicy.markDelivered(accepted, state: &state); pendingCount = state.pending.count
        let count = accepted.count
        persist { [weak self] success in
            guard let self, success, !self.stopped, self.generation == captured else { return }
            self.status = "\(count)개 파일을 정리 추천 대기열에 추가했습니다."
            self.notifyReady(count: count, origin: origin)
        }
    }

    private func persist(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !storageBlocked, !stopped else { completion(false); return }
        let value = state, captured = generation, store = self.store, gate = self.gate
        saveCount += 1; isSaving = true
        queue.async { [weak self] in
            let result = Result { try gate.perform(ifCurrent: captured) { try store.save(value) } }
            Task { @MainActor in
                guard let self else { completion(false); return }
                self.saveCount = max(0, self.saveCount - 1); self.isSaving = self.saveCount > 0
                guard !self.stopped, self.generation == captured else { completion(false); self.drainRequestedScan(); return }
                switch result {
                case .success:
                    completion(true)
                case .failure(let error):
                    if !(error is CancellationError) {
                        self.storageBlocked = true; self.timer?.invalidate(); self.timer = nil
                        self.status = "감시 기록을 보존하기 위해 중지했습니다. \(error.localizedDescription)"
                    }
                    completion(false)
                }
                self.drainRequestedScan()
            }
        }
    }

    private func advanceGeneration() {
        generation = UUID(); gate.update(generation); scanCancellation?.cancel()
    }
    private func drainRequestedScan() {
        guard scanRequested, !isScanning, !isSaving else { return }; scanNow()
    }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard !stopped, !storageBlocked, configuration.enabled, folderURL != nil, pollInterval > 0 else { return }
        let timer = Timer(timeInterval: max(1, pollInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanNow() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func retireCurrentScope() {
        guard let scopeURL else { return }; self.scopeURL = nil
        if isScanning { retiringScopes.append(scopeURL) }
        else { scopeURL.stopAccessingSecurityScopedResource() }
    }
    func openReview() { onOpenReview?() }

    func shutdown() {
        guard !stopped else { return }
        stopped = true; timer?.invalidate(); timer = nil; scanRequested = false; scanCancellation?.cancel()
        // Persist jobs already queued by explicit settings changes finish before the app exits.
        queue.sync {}
        retireCurrentScope()
        if !isScanning { retiringScopes.forEach { $0.stopAccessingSecurityScopedResource() }; retiringScopes.removeAll() }
        onReady = nil; onOpenReview = nil
        if let center = notificationCenter(), center.delegate === notificationDelegate { center.delegate = nil }
    }

    func requestNotificationAuthorization() {
        guard let center = notificationCenter() else { return }
        // Called only by an explicit UI action. Background scans only read existing permission.
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsAuthorized = granted }
        }
    }
    private func notificationCenter() -> UNUserNotificationCenter? {
        guard !isDemo, Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
    private func refreshNotificationAuthorization(_ center: UNUserNotificationCenter) {
        center.getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in self?.notificationsAuthorized = allowed }
        }
    }
    private func notifyReady(count: Int, origin: String) {
        guard let center = notificationCenter() else { return }
        center.getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.notificationsAuthorized = allowed
                guard allowed, self.configuration.enabled, let center = self.notificationCenter() else { return }
                let content = UNMutableNotificationContent()
                content.title = "정리 추천을 확인해 주세요"
                content.body = "\(origin)의 파일 \(count)개가 준비됐습니다."
                content.userInfo = ["tileFolderWatch": true]
                try? await center.add(UNNotificationRequest(identifier: "tile.folder-watch." + UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    nonisolated private static func select(_ original: URL, isDemo: Bool) throws -> FolderWatchSelection {
        let accessing = original.startAccessingSecurityScopedResource()
        do {
            guard original.isFileURL else { throw OrganizerError("이 Mac의 폴더를 선택해 주세요.") }
            let originalValues = try original.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
            guard originalValues.isSymbolicLink != true, originalValues.isAliasFile != true else {
                throw OrganizerError("바로가기 대신 실제 폴더를 선택해 주세요.")
            }
            let url = try PathSafety.canonicalRoot(original)
            try SafeFileSystem.validateDirectory(url)
            let values = try url.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey, .volumeIsLocalKey])
            guard values.isAliasFile != true, values.isPackage != true, values.volumeIsLocal == true else {
                throw OrganizerError("이 Mac의 일반 폴더를 선택해 주세요.")
            }
            let bookmark = isDemo ? nil : try original.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            return .init(url: url, scopeURL: accessing ? original : nil, bookmark: bookmark, identity: try SafeFileSystem.identity(at: url))
        } catch { if accessing { original.stopAccessingSecurityScopedResource() }; throw error }
    }

    nonisolated private static func restore(_ original: FolderWatchState, isDemo: Bool) throws -> FolderWatchRestoration {
        guard let path = original.configuration.folderPath else { throw OrganizerError("감시 폴더가 없습니다.") }
        var stale = false
        let restoredURL: URL
        if let bookmark = original.bookmark {
            restoredURL = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
        } else if isDemo { restoredURL = URL(fileURLWithPath: path) }
        else { throw OrganizerError("저장된 폴더 접근 권한이 없습니다.") }
        let selection = try select(restoredURL, isDemo: isDemo)
        guard original.rootIdentity == nil || original.rootIdentity == selection.identity else {
            selection.scopeURL?.stopAccessingSecurityScopedResource()
            throw OrganizerError("저장한 감시 폴더가 다른 폴더로 바뀌었습니다.")
        }
        var state = original
        state.rootIdentity = selection.identity
        if selection.url.path != path {
            state.configuration.folderPath = selection.url.path
            state.observations = Dictionary(uniqueKeysWithValues: state.observations.map { key, value in
                (selection.url.appendingPathComponent(URL(fileURLWithPath: key).lastPathComponent).path, value)
            })
            state.pending = state.pending.map { .init(path: selection.url.appendingPathComponent($0.url.lastPathComponent).path, fingerprint: $0.fingerprint) }
        }
        if stale || state.bookmark == nil { state.bookmark = selection.bookmark }
        return .init(state: state, url: selection.url, scopeURL: selection.scopeURL)
    }
}

private struct FolderWatchSelection: Sendable {
    var url: URL
    var scopeURL: URL?
    var bookmark: Data?
    var identity: FileIdentity
}
private struct FolderWatchRestoration: Sendable {
    var state: FolderWatchState
    var url: URL
    var scopeURL: URL?
}
private final class FolderWatchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
private final class FolderWatchGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    func update(_ value: UUID) { lock.lock(); generation = value; lock.unlock() }
    func perform<T>(ifCurrent value: UUID, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard generation == value else { throw CancellationError() }
        return try body()
    }
}

/// Used only on the serial I/O queue. Unknown, corrupt or externally changed bytes are never overwritten.
private final class FolderWatchStateStore: @unchecked Sendable {
    private let url: URL
    private var expectedBytes: Data?
    private var loaded = false
    private var blocked = false
    private let maximumBytes = 16 * 1_048_576
    init(url: URL) { self.url = url }
    func load() throws -> FolderWatchState {
        do {
            let bytes = try existingBytes()
            let value = try bytes.map { try JSONDecoder().decode(FolderWatchState.self, from: $0) } ?? FolderWatchState()
            try value.validate(); expectedBytes = bytes; loaded = true
            return value
        } catch { blocked = true; throw OrganizerError("WatchState.json을 읽을 수 없습니다. \(error.localizedDescription)") }
    }
    func save(_ state: FolderWatchState) throws {
        guard loaded, !blocked else { throw OrganizerError("기존 WatchState.json은 변경하지 않았습니다.") }
        do {
            try state.validate()
            guard try existingBytes() == expectedBytes else {
                throw OrganizerError("WatchState.json이 외부에서 변경됐습니다. 기존 파일을 유지합니다.")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(state)
            guard bytes.count <= maximumBytes else { throw OrganizerError("감시 기록이 너무 커서 저장하지 않았습니다.") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: [.atomic]); expectedBytes = bytes
        } catch { blocked = true; throw error }
    }
    private func existingBytes() throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return nil
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw OrganizerError("WatchState.json이 이 Mac에 저장된 일반 파일이 아닙니다.")
        }
        guard info.st_size <= maximumBytes else { throw OrganizerError("WatchState.json이 너무 큽니다.") }
        return try Data(contentsOf: url)
    }
}

private final class FolderWatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    @MainActor var openReview: (() -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["tileFolderWatch"] as? Bool == true {
            Task { @MainActor in self.openReview?() }
        }
        completionHandler()
    }
}
