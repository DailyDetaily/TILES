import AppKit
import Combine
import OrganizerCore

/// Owns one optional panel process. All authorized filesystem work stays in this existing app.
@MainActor final class FolderOverlayHost {
    private let model: AppModel
    private var process: Process?
    private var channel: FolderOverlayPipe?
    private var nonce = ""
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var startupTimer: Timer?
    private var catalogue: [FolderDestination] = []
    private var folderPreviews: [String: [FolderContentPreview]] = [:]
    private var catalogueMessage: String?
    private var catalogueLoading = false
    private var catalogueGeneration = UUID()
    private var dragging = false
    private var refreshPending = false
    private var requests = Set<UUID>()
    private var ownRecords = Set<UUID>()

    init(model: AppModel) {
        self.model = model
        model.$folderOverlayEnabled.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.syncEnabled() }
        }.store(in: &subscriptions)
        model.$folderConfigurationRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }.store(in: &subscriptions)
        model.$records.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refreshCatalogue() }
        }.store(in: &subscriptions)
        model.$folderDockLayout.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
        model.$folderDockEditing.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
        model.$busy.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
    }
    func shutdown() { stop(); subscriptions.removeAll() }

    private func syncEnabled() {
        if model.folderOverlayEnabled { if process == nil { start() } }
        else { stop() }
    }
    private func start() {
        guard process == nil, let executable = Bundle.main.executableURL else { return }
        nonce = UUID().uuidString; let generation = nonce
        let input = Pipe(), output = Pipe(), process = Process()
        // The child must inherit only stdin/stdout duplicates. An extra writer would hide parent EOF.
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            _ = fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC)
        }
        process.executableURL = executable
        process.arguments = ["--folder-overlay-agent", nonce]
        let args = ProcessInfo.processInfo.arguments
        if model.isDemo, let index = args.firstIndex(of: "--overlay-trace"), args.indices.contains(index + 1) {
            process.arguments! += ["--overlay-trace", args[index + 1]]
        }
        process.standardInput = input; process.standardOutput = output
        let channel = FolderOverlayPipe(input: output.fileHandleForReading, output: input.fileHandleForWriting)
        channel.receive = { [weak self] packet in DispatchQueue.main.async { self?.receive(packet, generation: generation) } }
        channel.disconnected = { [weak self] in DispatchQueue.main.async { self?.failed(generation) } }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.failed(generation) } }
        do { try process.run() }
        catch { model.error = "상단 정리 표시를 시작하지 못했습니다. \(error.localizedDescription)"; model.setFolderOverlayEnabled(false); return }
        // Only the child owns these ends after launch; EOF must close the helper when the host exits.
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        self.process = process; self.channel = channel; channel.start()
        refreshCatalogue()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.failed(generation) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCatalogue() }
        }
    }
    private func stop() {
        startupTimer?.invalidate(); startupTimer = nil; refreshTimer?.invalidate(); refreshTimer = nil
        let child = process
        channel?.send(.init(nonce: nonce, kind: .shutdown)); channel?.close(); channel = nil
        nonce = ""; process = nil; catalogueGeneration = UUID()
        catalogue = []; folderPreviews = [:]; catalogueLoading = false; dragging = false; refreshPending = false
        requests.removeAll(); ownRecords.removeAll()
        if let child {
            child.terminationHandler = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if child.isRunning { child.terminate() } }
        }
    }
    private func failed(_ generation: String) {
        guard generation == nonce, process != nil else { return }
        stop(); model.setFolderOverlayEnabled(false)
        model.error = "상단 정리 표시가 종료됐습니다. 진행된 이동은 기존 기록에서 확인할 수 있습니다. 기능을 다시 켜 주세요."
    }
    private func configurationChanged() {
        guard process != nil else { return }
        catalogue = []; folderPreviews = [:]; catalogueGeneration = UUID(); catalogueLoading = false
        refreshCatalogue()
    }
    private func refreshCatalogue() {
        guard process != nil else { return }
        guard !dragging else { refreshPending = true; publish(); return }
        refreshPending = false
        guard !catalogueLoading else { return }
        guard model.overlayDestinationConnected else {
            catalogue = []; folderPreviews = [:]; catalogueMessage = "정리 위치를 먼저 연결해 주세요."; publish(); return
        }
        catalogueLoading = true; catalogueMessage = nil; publish()
        let generation = UUID(); catalogueGeneration = generation
        let root = model.destination, rules = model.rules, records = model.records
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                let catalogue = try FolderRecommendations.catalogue(root: root, rules: rules, records: records)
                return (catalogue, FolderContentPreviews.load(catalogue: catalogue, root: root, rules: rules))
            }
            Task { @MainActor in
                guard self.catalogueGeneration == generation, self.process != nil else { return }
                self.catalogueLoading = false
                switch result {
                case .success(let value): self.catalogue = value.0; self.folderPreviews = value.1
                case .failure(let error): self.catalogue = []; self.folderPreviews = [:]; self.catalogueMessage = error.localizedDescription
                }
                self.publish()
            }
        }
    }
    private func publish() {
        guard let channel else { return }
        let snapshot = FolderOverlaySnapshot(revision: model.folderConfigurationRevision, root: model.destination.path,
            sources: model.overlayAuthorizedSources.map(\.path), destinationConnected: model.overlayDestinationConnected,
            rules: model.rules, catalogue: catalogue, catalogueMessage: catalogueMessage,
            catalogueLoading: catalogueLoading, busy: model.busy, isDemo: model.isDemo,
            layout: model.folderDockLayout, editing: model.folderDockEditing, folderPreviews: folderPreviews)
        channel.send(.init(nonce: nonce, kind: .snapshot, snapshot: snapshot))
    }
    private func receive(_ packet: FolderOverlayPacket, generation: String) {
        guard generation == nonce, packet.nonce == nonce, process != nil else { return }
        switch packet.kind {
        case .ready: startupTimer?.invalidate(); startupTimer = nil
        case .dragging:
            dragging = packet.dragging == true
            if !dragging && refreshPending { refreshCatalogue() }
        case .layout:
            guard model.folderDockEditing, !dragging, !model.busy, let layout = packet.layout else { return }
            model.setFolderDockLayout(layout)
        case .finishEditing:
            guard !dragging else { return }; model.setFolderDockEditing(false)
        case .connections:
            guard !dragging else { return }
            model.page = .rules; model.openMainWindow?(); NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        case .recommendation:
            guard let id = packet.id, requests.insert(id).inserted else { return }
            guard !dragging, !model.busy else {
                respond(id, .failure(OrganizerError("드래그와 진행 중인 작업을 마친 뒤 다시 놓아 주세요.")), generation: generation); return
            }
            do {
                let sources = try packet.validatedSources()
                // The child keeps its original URL grants until the persistent review releases them.
                // Intake/presentation starts only after the ordered dragging(false) packet arrives.
                model.acceptFilesForReview(sources, presentPanel: true, releaseAccess: { [weak self] in
                    guard let self, self.nonce == generation else { return }
                    self.channel?.send(.init(nonce: generation, kind: .releaseReview, id: id))
                })
                channel?.send(.init(nonce: nonce, kind: .result, id: id))
            } catch { respond(id, .failure(error), generation: generation) }
        case .drop:
            guard let id = packet.id, requests.insert(id).inserted else { return }
            guard !dragging, let candidate = packet.candidate, let revision = packet.revision,
                  catalogue.contains(where: { $0.path == candidate.id && $0.identity == candidate.destination.identity }) else {
                respond(id, .failure(OrganizerError("선택한 폴더가 바뀌었습니다. 파일을 다시 끌어오세요.")), generation: generation); return
            }
            do {
                let sources = try packet.validatedSources()
                model.performOverlayBatchDrop(sources: sources, candidate: candidate, configurationRevision: revision) { [weak self] result in
                    self?.respond(id, result, generation: generation)
                }
            } catch { respond(id, .failure(error), generation: generation) }
        case .undo:
            guard let id = packet.id, requests.insert(id).inserted else { return }
            guard !dragging, let runID = packet.recordID, ownRecords.contains(runID), let record = model.records.first(where: { $0.id == runID }) else {
                respond(id, .failure(OrganizerError("기존 정리 기록에서 되돌릴 항목을 확인해 주세요.")), generation: generation); return
            }
            model.undoOverlayDrop(record) { [weak self] result in self?.respond(id, result, generation: generation) }
        default: break
        }
    }
    private func respond(_ id: UUID, _ result: Result<RunRecord, Error>, generation: String) {
        guard generation == nonce else { return }
        switch result {
        case .success(let record):
            ownRecords.insert(record.id); channel?.send(.init(nonce: nonce, kind: .result, id: id, record: record))
        case .failure(let error): channel?.send(.init(nonce: nonce, kind: .result, id: id, error: error.localizedDescription))
        }
    }
}
