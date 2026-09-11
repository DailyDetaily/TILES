import AppKit
import Foundation
import OrganizerCore

/// Ephemeral display state only. Settings, bookmarks, journal and the mover remain in AppModel.
struct FolderOverlaySnapshot: Codable {
    var revision: Int
    var root: String
    var sources: [String]
    var destinationConnected: Bool
    var rules: OrganizerRules
    var catalogue: [FolderDestination]
    var catalogueMessage: String?
    var catalogueLoading: Bool
    var busy: Bool
    var isDemo: Bool
    var layout: FolderDockLayout = .init()
    var editing: Bool = false
    var folderPreviews: [String: [FolderContentPreview]]? = nil
}

struct FolderOverlayPacket: Codable {
    enum Kind: String, Codable { case ready, snapshot, dragging, drop, recommendation, releaseReview, undo, connections, result, shutdown, layout, finishEditing }
    var nonce: String
    var kind: Kind
    var id: UUID?
    var snapshot: FolderOverlaySnapshot?
    var dragging: Bool?
    var source: String?
    var sources: [String]?
    var candidate: FolderRecommendation?
    var revision: Int?
    var record: RunRecord?
    var recordID: UUID?
    var error: String?
    var layout: FolderDockLayout?

    /// Paths cross a private pipe, but still require strict validation before creating file URLs.
    func validatedSources() throws -> [URL] {
        let paths = sources ?? source.map { [$0] } ?? []
        guard !paths.isEmpty, paths.count <= ExistingFileDrop.maximumBatchCount else {
            throw OrganizerError("로컬 일반 파일을 1개부터 500개까지 선택해 주세요.")
        }
        let urls = try paths.map { path -> URL in
            guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.utf8.contains(0),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(".") else {
                throw OrganizerError("드래그한 파일 경로가 올바르지 않습니다. 다시 선택해 주세요.")
            }
            let url = URL(fileURLWithPath: path)
            guard url.path == path, path != "/" else { throw OrganizerError("드래그한 파일 경로가 올바르지 않습니다.") }
            return url
        }
        return try ExistingFileDrop.validateInputs(urls: urls, itemCount: paths.count, hasFilePromise: false, allowsMove: true)
    }
}

/// Private inherited pipes, not a listener, socket or network service. JSON escaping preserves file names.
final class FolderOverlayPipe: @unchecked Sendable {
    static let maximumPacketBytes = 1_048_576
    private let input: FileHandle
    private let output: FileHandle
    private let writer = DispatchQueue(label: "MaterialOrganizer.overlay.pipe")
    private let lock = NSLock()
    private var buffer = Data()
    private var scannedBytes = 0
    private var closed = false
    var receive: ((FolderOverlayPacket) -> Void)?
    var disconnected: (() -> Void)?

    init(input: FileHandle, output: FileHandle) {
        self.input = input; self.output = output
        // A disappearing child must not deliver SIGPIPE to the main application.
        _ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    static func encode(_ packet: FolderOverlayPacket) throws -> Data {
        var data = try JSONEncoder().encode(packet)
        guard data.count <= maximumPacketBytes else { throw OrganizerError("상단 정리 표시 데이터가 너무 큽니다.") }
        data.append(10); return data
    }
    func start() {
        input.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            do {
                self.lock.lock()
                if self.closed { self.lock.unlock(); return }
                // read(upToCount:) may wait for the entire size on a pipe. This callback already
                // signals available bytes; consume those bytes without waiting for another packet.
                let data = handle.availableData
                if data.isEmpty { self.lock.unlock(); self.close(notify: true); return }
                self.buffer.append(data)
                var frames: [Data] = []
                // A long partial frame must not rescan all previously received bytes on every read.
                while let end = self.buffer[self.buffer.index(self.buffer.startIndex, offsetBy: self.scannedBytes)...].firstIndex(of: 10) {
                    frames.append(Data(self.buffer[..<end])); self.buffer.removeSubrange(...end)
                    self.scannedBytes = 0
                }
                self.scannedBytes = self.buffer.count
                let oversized = self.buffer.count > Self.maximumPacketBytes || frames.contains { $0.count > Self.maximumPacketBytes }
                self.lock.unlock()
                guard !oversized else { self.close(notify: true); return }
                for frame in frames { self.receive?(try JSONDecoder().decode(FolderOverlayPacket.self, from: frame)) }
            } catch { self.close(notify: true) }
        }
    }
    func send(_ packet: FolderOverlayPacket) {
        writer.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let closed = self.closed; self.lock.unlock()
            guard !closed else { return }
            do { try self.output.write(contentsOf: Self.encode(packet)) }
            catch { self.close(notify: true) }
        }
    }
    func close(notify: Bool = false) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true; buffer.removeAll(); scannedBytes = 0; lock.unlock()
        input.readabilityHandler = nil
        // Closing the writer is ordered after any in-flight write; the peer receives EOF.
        writer.async { [input, output] in try? input.close(); try? output.close() }
        if notify { disconnected?() }
    }
}

/// The display process can request a move, but has no file mover, journal or saved-folder authority.
@MainActor final class FolderOverlayContext {
    private(set) var snapshot: FolderOverlaySnapshot
    private let channel: FolderOverlayPipe
    private let nonce: String
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    private var requests: [UUID: (Result<RunRecord, Error>) -> Void] = [:]
    private var reviewRequests: [UUID: (Result<Void, Error>) -> Void] = [:]
    private var reviewIDs = Set<UUID>()
    private var scopedURLs: [UUID: [URL]] = [:]
    var changed: (() -> Void)?
    var folderOverlayEnabled = true
    var isDemo: Bool { snapshot.isDemo }
    var folderConfigurationRevision: Int { snapshot.revision }
    var overlayDestinationConnected: Bool { snapshot.destinationConnected }
    var overlayAuthorizedSources: [URL] { snapshot.sources.map { URL(fileURLWithPath: $0) } }
    var rules: OrganizerRules { snapshot.rules }
    var busy: Bool { snapshot.busy || !requests.isEmpty || !reviewRequests.isEmpty }

    init(snapshot: FolderOverlaySnapshot, channel: FolderOverlayPipe, nonce: String,
         startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.snapshot = snapshot; self.channel = channel; self.nonce = nonce
        self.startAccess = startAccess; self.stopAccess = stopAccess
    }
    func update(_ snapshot: FolderOverlaySnapshot) { self.snapshot = snapshot; changed?() }
    func setDragging(_ dragging: Bool) { channel.send(.init(nonce: nonce, kind: .dragging, dragging: dragging)) }
    func saveLayout(_ layout: FolderDockLayout) { channel.send(.init(nonce: nonce, kind: .layout, layout: layout.sanitized)) }
    func finishEditing() { channel.send(.init(nonce: nonce, kind: .finishEditing)) }
    func showConnections() { channel.send(.init(nonce: nonce, kind: .connections)) }
    func performOverlayDrop(source: URL, candidate: FolderRecommendation, configurationRevision: Int,
                            completion: @escaping (Result<RunRecord, Error>) -> Void) {
        performOverlayBatchDrop(sources: [source], candidate: candidate, configurationRevision: configurationRevision, completion: completion)
    }
    func performOverlayBatchDrop(sources: [URL], candidate: FolderRecommendation, configurationRevision: Int,
                                 completion: @escaping (Result<RunRecord, Error>) -> Void) {
        let id = UUID(); requests[id] = completion
        scopedURLs[id] = sources.filter(startAccess)
        channel.send(.init(nonce: nonce, kind: .drop, id: id, sources: sources.map(\.path), candidate: candidate, revision: configurationRevision))
    }
    func acceptFilesForReview(_ sources: [URL], completion: @escaping (Result<Void, Error>) -> Void) {
        let id = UUID(); reviewRequests[id] = completion; reviewIDs.insert(id)
        scopedURLs[id] = sources.filter(startAccess)
        channel.send(.init(nonce: nonce, kind: .recommendation, id: id, sources: sources.map(\.path)))
    }
    func releaseReview(_ id: UUID) {
        guard reviewIDs.remove(id) != nil else { return }
        releaseScopes(id)
    }
    private func releaseScopes(_ id: UUID) {
        scopedURLs.removeValue(forKey: id)?.forEach(stopAccess)
    }
    func undoOverlayDrop(_ record: RunRecord, completion: @escaping (Result<RunRecord, Error>) -> Void) {
        let id = UUID(); requests[id] = completion
        channel.send(.init(nonce: nonce, kind: .undo, id: id, recordID: record.id))
    }
    func resolve(_ packet: FolderOverlayPacket) {
        guard let id = packet.id else { return }
        if let completion = reviewRequests.removeValue(forKey: id) {
            if let error = packet.error { releaseReview(id); completion(.failure(OrganizerError(error))) }
            else { completion(.success(())) }
            return
        }
        guard let completion = requests.removeValue(forKey: id) else { return }
        releaseScopes(id)
        if let record = packet.record { completion(.success(record)) }
        else { completion(.failure(OrganizerError(packet.error ?? "이동 결과를 확인하지 못했습니다. 정리 내역을 확인해 주세요."))) }
    }
    func shutdown() {
        folderOverlayEnabled = false; changed = nil
        let pendingMoves = requests.values, pendingReviews = reviewRequests.values
        requests.removeAll(); reviewRequests.removeAll(); reviewIDs.removeAll()
        scopedURLs.values.flatMap { $0 }.forEach(stopAccess); scopedURLs.removeAll()
        let error = OrganizerError("상단 정리 연결이 종료됐습니다. 정리 내역을 확인해 주세요.")
        pendingMoves.forEach { $0(.failure(error)) }; pendingReviews.forEach { $0(.failure(error)) }
    }
}

/// Internal mode of the same signed executable. Only its panel process is background-only.
/// The normal SwiftUI application, Dock presence and last-window-close policy are unchanged.
enum FolderOverlayAgent {
    @MainActor static func run(nonce: String) {
        guard UUID(uuidString: nonce) != nil else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Theme.registerFonts()
        let channel = FolderOverlayPipe(input: .standardInput, output: .standardOutput)
        var context: FolderOverlayContext?
        var controller: FolderOverlayController?
        func stop() {
            controller?.shutdown(); context?.shutdown(); channel.close(); app.terminate(nil)
        }
        channel.receive = { packet in
            DispatchQueue.main.async {
                guard packet.nonce == nonce else { stop(); return }
                switch packet.kind {
                case .snapshot:
                    guard let snapshot = packet.snapshot else { stop(); return }
                    if let context { context.update(snapshot) }
                    else {
                        let value = FolderOverlayContext(snapshot: snapshot, channel: channel, nonce: nonce)
                        context = value; controller = FolderOverlayController(model: value)
                        channel.send(.init(nonce: nonce, kind: .ready))
                    }
                case .result: context?.resolve(packet)
                case .releaseReview: if let id = packet.id { context?.releaseReview(id) }
                case .shutdown: stop()
                default: stop()
                }
            }
        }
        channel.disconnected = { DispatchQueue.main.async { stop() } }
        channel.start(); app.run()
        controller?.shutdown(); context?.shutdown(); channel.close()
    }
}
