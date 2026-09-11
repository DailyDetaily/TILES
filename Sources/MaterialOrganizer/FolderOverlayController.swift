import AppKit
import QuartzCore
import OrganizerCore

/// Finder can offer .generic rather than .move. Generic lets this destination perform its own handoff.
/// Review never advertises a move; a copy-only source can enter review but cannot directly move a file.
enum FolderOverlayDragOperations {
    static func supportsInput(_ mask: NSDragOperation) -> Bool {
        !mask.intersection([.generic, .copy, .move]).isEmpty
    }
    static func operation(for target: FolderDropTarget, mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.generic) { return .generic }
        switch target {
        case .recommendation: return mask.contains(.copy) ? .copy : []
        case .folder: return mask.contains(.move) ? .move : []
        }
    }
}

/// The clear receiver matches the saved Dock frame. Only the shelf contents animate.
@MainActor final class FolderOverlayController {
    private let model: FolderOverlayContext
    private let state = FolderOverlayState()
    private var panel: FolderOverlayPanel?
    private var receiver: FileDragReceiver?
    private var content: FolderOverlayView?
    private var resizeHandles: FolderDockResizeHandles?
    private var controlsPanel: FolderOverlayPanel?
    private var controls: FolderDockControls?
    private var displayedDockFrame = CGRect.zero
    private var layout = FolderDockLayout()
    private var presented = false
    private var hiding = false
    private var presentationGeneration = UUID()
    private var settlingUntil = Date.distantPast
    private var editGesture: (point: CGPoint, frame: CGRect, corner: FolderDockGeometry.Corner?)?
    private var cachedRevision = -1
    private var snappedAxes: FolderDockGeometry.CenterAxes = []
    private var centerGuides: [FolderOverlayPanel] = []
    private var pointerTimer: Timer?
    private var dragReceiverActivity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var feedbackTimer: Timer?
    private var activeScreen: NSScreen?
    private var session = FolderDropSession()
    private var catalogue: [FolderDestination] = []
    private var catalogueMessage: String?
    private var catalogueLoading = false
    private var cachePending = false
    private var lastCacheDate = Date.distantPast
    private var dragConfigurationRevision = 0
    private var pendingDrop: (sources: [URL], target: FolderDropTarget, revision: Int)?
    private var lastRecord: RunRecord?
    private var lastDestination: URL?
    private var receivedDrag = false
    private var lastDragUpdate = Date.distantPast
    private var traceURL: URL?
    private var traceBuffer = Data()

    init(model: FolderOverlayContext) {
        self.model = model
        let arguments = ProcessInfo.processInfo.arguments
        if model.isDemo, let index = arguments.firstIndex(of: "--overlay-trace"), arguments.indices.contains(index + 1) {
            traceURL = URL(fileURLWithPath: arguments[index + 1])
        }
        state.close = { [weak self] in self?.collapse() }
        state.connect = { [weak self] in self?.showConnections() }
        state.openFolder = { [weak self] in if let url = self?.lastDestination { NSWorkspace.shared.open(url) } }
        state.undo = { [weak self] in self?.undo() }
        state.finishEditing = { [weak self] in self?.model.finishEditing() }
        state.resetLayout = { [weak self] in self?.resetLayout() }
        state.beginEdit = { [weak self] in self?.beginEdit($0, corner: $1) }
        state.changeEdit = { [weak self] in self?.changeEdit($0) }
        state.endEdit = { [weak self] in self?.endEdit() }
        layout = model.snapshot.layout.sanitized
        model.changed = { [weak self] in self?.snapshotChanged() }
        enable()
    }

    func shutdown() { disable(); model.changed = nil }

    private func enable() {
        guard panel == nil, model.folderOverlayEnabled else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        // The clear receiver remains an active user-enabled drop destination while its shelf is hidden.
        // Keep App Nap from delaying its button-state timer; allow normal display and system idle sleep.
        dragReceiverActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the user-enabled folder Dock responsive to Finder drags")
        let initialFrame = FolderDockGeometry.trigger(layout: layout, usable: usable(screen))
        let panel = FolderOverlayPanel(contentRect: initialFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isMovable = false; panel.isExcludedFromWindowsMenu = true
        let receiver = FileDragReceiver(frame: .init(origin: .zero, size: initialFrame.size))
        let hosting = FolderOverlayView(state: state)
        receiver.wantsLayer = true; receiver.layer?.masksToBounds = true
        hosting.frame = receiver.bounds; hosting.isHidden = true
        receiver.addSubview(hosting); panel.contentView = receiver
        let resizeHandles = FolderDockResizeHandles(state: state)
        resizeHandles.frame = receiver.bounds; resizeHandles.isHidden = true
        receiver.addSubview(resizeHandles)
        receiver.entered = { [weak self] in self?.entered($0) ?? [] }
        receiver.updated = { [weak self] in self?.updated($0) ?? [] }
        receiver.exited = { [weak self] in self?.exited($0) }
        receiver.prepare = { [weak self] in self?.prepare($0) ?? false }
        receiver.perform = { [weak self] in self?.perform($0) ?? false }
        receiver.ended = { [weak self] in self?.ended($0) }
        self.panel = panel; self.receiver = receiver; self.content = hosting; self.resizeHandles = resizeHandles
        let controlsPanel = FolderOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controlsPanel.level = .floating; controlsPanel.hidesOnDeactivate = false; controlsPanel.isReleasedWhenClosed = false
        controlsPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        controlsPanel.isOpaque = false; controlsPanel.backgroundColor = .clear; controlsPanel.hasShadow = false
        controlsPanel.isMovable = false; controlsPanel.isExcludedFromWindowsMenu = true
        let controls = FolderDockControls(state: state)
        controlsPanel.contentView = controls
        self.controlsPanel = controlsPanel; self.controls = controls
        panel.ignoresMouseEvents = true
        position(); refreshCatalogue(); snapshotChanged()
        panel.orderFrontRegardless()
        pointerTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let pointerTimer { RunLoop.main.add(pointerTimer, forMode: .common) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // A disconnected display invalidates the gesture; never move live cards beneath a pointer.
                if self?.receivedDrag == true { self?.collapse() }
                self?.editGesture = nil; self?.snappedAxes = []; self?.hideCenterGuides(); self?.activeScreen = nil; self?.position()
            }
        }
    }

    private func disable() {
        pointerTimer?.invalidate(); pointerTimer = nil
        if let dragReceiverActivity { ProcessInfo.processInfo.endActivity(dragReceiverActivity) }
        dragReceiverActivity = nil
        feedbackTimer?.invalidate(); feedbackTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        hideCenterGuides(); snappedAxes = []
        controlsPanel?.orderOut(nil); controlsPanel?.close(); controlsPanel = nil; controls = nil
        panel?.orderOut(nil); panel?.close(); panel = nil; receiver = nil; content = nil; resizeHandles = nil; activeScreen = nil
        presentationGeneration = UUID(); presented = false; hiding = false; editGesture = nil
        catalogueLoading = false; catalogue = []; session.reset()
        pendingDrop = nil
        receivedDrag = false; model.setDragging(false); state.dragging = false; state.mode = .hidden
    }

    private func usable(_ screen: NSScreen) -> CGRect {
        FolderDockGeometry.usable(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
    }
    /// Padding belongs to edit chrome, never to saved placement or file-drop geometry.
    @discardableResult private func applyFrame(_ dockFrame: CGRect, editing: Bool) -> CGPoint {
        displayedDockFrame = dockFrame
        panel?.allowsEditMargin = editing
        let windowFrame = FolderDockGeometry.panelFrame(dockFrame: dockFrame, editing: editing)
        if panel?.frame != windowFrame { panel?.setFrame(windowFrame, display: true, animate: false) }
        let dockBounds = FolderDockGeometry.dockBounds(size: dockFrame.size, editing: editing)
        content?.setFrameSize(dockFrame.size)
        resizeHandles?.frame = receiver?.bounds ?? .zero
        resizeHandles?.update(dockBounds: dockBounds)
        resizeHandles?.isHidden = !editing
        positionControls(dockFrame: dockFrame)
        return dockBounds.origin
    }
    private func positionControls(dockFrame: CGRect) {
        guard let controlsPanel, let controls, let panel, state.expanded, !hiding else {
            controlsPanel?.orderOut(nil); return
        }
        let visible = (activeScreen ?? NSScreen.main)?.visibleFrame ?? dockFrame
        let width = state.mode == .editing ? CGFloat(116) : min(dockFrame.width, 360)
        let height = FolderDockControls.height
        let below = dockFrame.minY - height - 16
        let y = below >= visible.minY + 4 ? below : dockFrame.maxY + 16
        let frame = CGRect(x: dockFrame.midX - width / 2, y: y, width: width, height: height)
        controlsPanel.setFrame(frame, display: true, animate: false)
        controls.setFrameSize(frame.size)
        controlsPanel.order(.above, relativeTo: panel.windowNumber)
    }
    private func position() {
        guard let panel, let receiver, let content else { return }
        let screen = activeScreen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }; activeScreen = screen
        let frame = state.expanded ? FolderDockGeometry.frame(layout: layout, usable: usable(screen))
                                   : FolderDockGeometry.trigger(layout: layout, usable: usable(screen))
        let editing = state.mode == .editing
        let contentOrigin = applyFrame(frame, editing: editing)
        guard state.expanded else {
            content.isHidden = true; panel.hasShadow = false; presented = false; return
        }
        panel.ignoresMouseEvents = false; panel.hasShadow = true
        if presented && !hiding { content.setFrameOrigin(contentOrigin); return }
        presentationGeneration = UUID(); hiding = false; presented = true
        positionControls(dockFrame: frame)
        content.layer?.removeAllAnimations(); content.isHidden = false
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content.setFrameOrigin(reduce ? contentOrigin : CGPoint(x: contentOrigin.x, y: receiver.bounds.height))
        content.alphaValue = reduce ? 0 : 1
        resizeHandles?.alphaValue = 0
        settlingUntil = Date().addingTimeInterval(reduce ? 0.1 : 0.22)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.1 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.animator().setFrameOrigin(contentOrigin); content.animator().alphaValue = 1
            resizeHandles?.animator().alphaValue = 1
        }
    }
    private func snapshotChanged() {
        if !receivedDrag, editGesture == nil {
            let next = model.snapshot.layout.sanitized
            if layout != next { layout = next; position() }
            if model.snapshot.editing && session.phase != .moving {
                feedbackTimer?.invalidate(); session.reset(); state.dragging = false
                state.mode = .editing; state.targets = []; position()
            } else if state.mode == .editing { collapse() }
        }
        if cachedRevision != model.snapshot.revision || catalogue != model.snapshot.catalogue || state.folderPreviews != (model.snapshot.folderPreviews ?? [:]) || catalogueLoading != model.snapshot.catalogueLoading || catalogueMessage != model.snapshot.catalogueMessage {
            scheduleCatalogueRefresh()
        }
    }
    private func beginEdit(_ point: CGPoint, corner: FolderDockGeometry.Corner?) {
        guard state.mode == .editing, !receivedDrag, panel != nil else { return }
        snappedAxes = []; hideCenterGuides()
        editGesture = (point, displayedDockFrame, corner)
    }
    private func changeEdit(_ point: CGPoint) {
        guard let gesture = editGesture, panel != nil, state.mode == .editing, !receivedDrag else { return }
        let screen = gesture.corner == nil ? (NSScreen.screens.first { $0.frame.contains(point) } ?? activeScreen) : activeScreen
        guard let screen else { return }
        if screen != activeScreen { snappedAxes = []; hideCenterGuides() }
        activeScreen = screen
        let area = usable(screen), delta = CGSize(width: point.x - gesture.point.x, height: point.y - gesture.point.y)
        let frame: CGRect
        if let corner = gesture.corner {
            frame = FolderDockGeometry.resized(gesture.frame, corner: corner, by: delta, usable: area)
        } else {
            let moved = FolderDockGeometry.moved(gesture.frame, by: delta, usable: area)
            let snap = FolderDockGeometry.centered(moved, screen: screen.frame, usable: area, previous: snappedAxes)
            frame = snap.frame; snappedAxes = snap.axes; showCenterGuides(on: screen)
        }
        layout = FolderDockGeometry.placement(frame: frame, usable: area)
        content?.setFrameOrigin(applyFrame(frame, editing: true))
    }
    private func endEdit() {
        guard editGesture != nil else { return }; editGesture = nil; snappedAxes = []; hideCenterGuides(); model.saveLayout(layout)
    }
    private func resetLayout() {
        guard state.mode == .editing, !receivedDrag else { return }
        editGesture = nil; snappedAxes = []; hideCenterGuides(); layout = .init(); position(); model.saveLayout(layout)
    }

    private func showCenterGuides(on screen: NSScreen) {
        guard !snappedAxes.isEmpty else { hideCenterGuides(); return }
        if centerGuides.isEmpty {
            centerGuides = (0..<2).map { _ in
                let guide = FolderOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                guide.isReleasedWhenClosed = false; guide.level = .floating
                guide.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                guide.hidesOnDeactivate = false; guide.isOpaque = false; guide.hasShadow = false
                guide.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.7)
                guide.ignoresMouseEvents = true; guide.isExcludedFromWindowsMenu = true
                return guide
            }
        }
        let area = usable(screen)
        let frames = [CGRect(x: screen.frame.midX - 0.5, y: area.minY, width: 1, height: area.height),
                      CGRect(x: area.minX, y: screen.frame.midY - 0.5, width: area.width, height: 1)]
        for index in 0..<2 {
            let visible = snappedAxes.contains(index == 0 ? .x : .y)
            if visible {
                centerGuides[index].setFrame(frames[index], display: true, animate: false)
                centerGuides[index].order(.below, relativeTo: panel?.windowNumber ?? 0)
            } else { centerGuides[index].orderOut(nil) }
        }
    }
    private func hideCenterGuides() {
        centerGuides.forEach { $0.orderOut(nil); $0.close() }; centerGuides = []
    }

    private func tick() {
        guard model.folderOverlayEnabled else { return }
        if receivedDrag {
            // Destination callbacks are primary. Recover a stale exit if a source disappears without an ended callback.
            if NSEvent.pressedMouseButtons == 0, Date().timeIntervalSince(lastDragUpdate) > 1 {
                endSession()
            }
            return
        }
        if NSEvent.pressedMouseButtons == 0 { flushTrace() }
        if state.mode == .hidden {
            // This reads only button state, never pasteboard data or other applications' events.
            // Ordinary pointer movement and clicks pass through the clear saved Dock area.
            panel?.ignoresMouseEvents = NSEvent.pressedMouseButtons & 1 == 0
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            if screen != activeScreen { activeScreen = screen; position() }
            if cachePending || Date().timeIntervalSince(lastCacheDate) > 30 { refreshCatalogue() }
        }
    }

    private func scheduleCatalogueRefresh() {
        catalogue = []; catalogueMessage = nil
        catalogueLoading = false
        cachePending = true
        Task { @MainActor in if self.panel != nil && !self.receivedDrag { self.refreshCatalogue() } }
    }

    private func refreshCatalogue() {
        guard !receivedDrag, model.folderOverlayEnabled else { cachePending = true; return }
        cachePending = false; lastCacheDate = Date(); cachedRevision = model.snapshot.revision
        catalogue = model.snapshot.catalogue
        state.folderPreviews = model.snapshot.folderPreviews ?? [:]
        state.editingFolders = catalogue.sorted {
            if ($0.category != nil) != ($1.category != nil) { return $0.category != nil }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }.prefix(2).map { FolderRecommendation(destination: $0, reason: "편집 미리보기") }
        catalogueMessage = model.snapshot.catalogueMessage
        catalogueLoading = model.snapshot.catalogueLoading
    }

    private func input(_ info: NSDraggingInfo) throws -> [URL] {
        let pasteboard = info.draggingPasteboard, items = pasteboard.pasteboardItems ?? []
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let promises = Set(NSFilePromiseReceiver.readableDraggedTypes)
        let hasPromise = !types.isDisjoint(with: promises) || types.contains(where: { $0.lowercased().contains("promised-file") })
        guard items.count <= ExistingFileDrop.maximumBatchCount else { throw OrganizerError("파일을 한 번에 500개까지 선택해 주세요.") }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, items.count == 1, let raw = items[0].string(forType: .URL),
           let web = URL(string: raw), !web.isFileURL {
            throw OrganizerError("웹 주소 대신 로컬 일반 파일을 끌어오세요.")
        }
        return try ExistingFileDrop.validateInputs(urls: urls, itemCount: items.count, hasFilePromise: hasPromise,
            allowsFileHandoff: FolderOverlayDragOperations.supportsInput(info.draggingSourceOperationMask))
    }

    private func entered(_ info: NSDraggingInfo) -> NSDragOperation {
        trace("entered", info)
        guard model.folderOverlayEnabled, !model.busy, !model.snapshot.editing, session.phase != .moving else { return [] }
        feedbackTimer?.invalidate(); state.canUndo = false
        let result = Result { try input(info) }
        let sources = try? result.get()
        let previous = session.token
        guard let token = session.begin(sequence: info.draggingSequenceNumber, sources: sources?.map(\.path) ?? []),
              session.phase != .cancelled && session.phase != .finished else { return [] }
        receivedDrag = true; model.setDragging(true); lastDragUpdate = Date(); state.dragging = true
        if token == previous {
            state.mode = session.targets.isEmpty ? (session.phase == .preparing ? .preparing : .failure) : .folders
            position(); return updated(info)
        }
        dragConfigurationRevision = model.folderConfigurationRevision
        state.filename = sources.map { $0.count == 1 ? $0[0].lastPathComponent : "파일 \($0.count)개" } ?? "상단 정리"
        state.targets = []; state.hoveredID = nil; state.mode = .preparing
        state.detail = "정리 추천 또는 바로 이동할 폴더를 선택하세요."; position()
        if case .failure(let error) = result { reject(error.localizedDescription, token: token); return [] }
        guard let sources else { return [] }
        let candidates = cachedBatchCandidates(sources)
        let targets: [FolderDropTarget] = [.recommendation] + candidates.map(FolderDropTarget.folder)
        if session.freeze(targets: targets, for: token) { state.targets = session.targets; state.mode = .folders }
        return []
    }

    /// Only names and the idle cache are read while the native drag is held.
    private func cachedBatchCandidates(_ sources: [URL]) -> [FolderRecommendation] {
        guard model.overlayDestinationConnected else { return [] }
        let parents = Set(sources.map { PathSafety.lexicalURL($0.deletingLastPathComponent()).path.precomposedStringWithCanonicalMapping.lowercased() })
        let eligible = catalogue.filter { !parents.contains($0.path.precomposedStringWithCanonicalMapping.lowercased()) }
        var scores: [String: Int] = [:], values: [String: FolderRecommendation] = [:]
        for source in sources {
            for (index, candidate) in FolderRecommendations.cachedRecommendations(source: source, catalogue: eligible, rules: model.rules).enumerated() {
                scores[candidate.id, default: 0] += 3 - index; values[candidate.id] = candidate
            }
        }
        return values.values.sorted {
            let left = scores[$0.id, default: 0], right = scores[$1.id, default: 0]
            return left == right ? $0.id < $1.id : left > right
        }.prefix(2).map { $0 }
    }

    private func reject(_ message: String, token: FolderDropSession.Token) {
        guard session.freeze([], message: message, for: token) else { return }
        state.detail = message; state.mode = .failure; state.targets = []; state.hoveredID = nil
    }

    private func hovered(_ info: NSDraggingInfo) -> String? {
        guard let receiver, state.mode == .folders else { return nil }
        guard Date() >= settlingUntil else { return nil }
        let local = receiver.convert(info.draggingLocation, from: nil)
        let point = CGPoint(x: local.x, y: receiver.bounds.height - local.y)
        let frames = FolderDockGeometry.items(size: receiver.bounds.size, count: session.targets.count)
        for (index, target) in session.targets.enumerated() {
            if frames[index].contains(point) { return target.id }
        }
        return nil
    }

    private func updated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard receivedDrag, session.token?.sequence == info.draggingSequenceNumber else { return [] }
        lastDragUpdate = Date()
        let targetID = hovered(info)
        let target = session.targets.first { $0.id == targetID }
        let operation = target.map { FolderOverlayDragOperations.operation(for: $0, mask: info.draggingSourceOperationMask) } ?? []
        let currentConfiguration = target == .recommendation || dragConfigurationRevision == model.folderConfigurationRevision
        let allowed = !operation.isEmpty && !model.busy && currentConfiguration
        let previous = session.hoveredID
        session.hover(allowed ? targetID : nil); state.hoveredID = session.hoveredID
        if previous != session.hoveredID { trace("hover", info) }
        return allowed && session.hoveredID != nil ? operation : []
    }

    private func prepare(_ info: NSDraggingInfo) -> Bool {
        trace("prepare", info)
        let operation = updated(info)
        guard !operation.isEmpty, let sources = try? input(info), session.hoveredID == FolderDropTarget.recommendation.id || dragConfigurationRevision == model.folderConfigurationRevision else { return false }
        return session.canAccept(sequence: info.draggingSequenceNumber, sources: sources.map(\.path),
                                 allowsOperation: !operation.isEmpty, busy: model.busy)
    }

    private func perform(_ info: NSDraggingInfo) -> Bool {
        guard prepare(info), let sources = try? input(info),
              let hoveredTarget = session.targets.first(where: { $0.id == session.hoveredID }),
              let target = session.accept(sequence: info.draggingSequenceNumber, sources: sources.map(\.path),
                  allowsOperation: !FolderOverlayDragOperations.operation(for: hoveredTarget, mask: info.draggingSourceOperationMask).isEmpty,
                  busy: model.busy) else { return false }
        trace("accepted", info)
        state.hoveredID = nil; state.mode = .moving
        state.detail = target == .recommendation ? "파일을 놓으면 정리 추천을 엽니다…" : "파일과 폴더를 검사한 뒤 이동합니다…"
        lastRecord = nil; lastDestination = target.candidate.map { URL(fileURLWithPath: $0.id) }
        pendingDrop = (sources, target, dragConfigurationRevision)
        // AppKit's ended callback is primary. Recover if a source ends without delivering it.
        let token = session.token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.session.token == token, NSEvent.pressedMouseButtons == 0 else { return }
            self.startPendingDrop()
        }
        return true
    }

    private func startPendingDrop() {
        guard let pendingDrop, model.folderOverlayEnabled else { return }
        self.pendingDrop = nil; receivedDrag = false; model.setDragging(false); state.dragging = false
        if pendingDrop.target == .recommendation {
            model.acceptFilesForReview(pendingDrop.sources) { [weak self] result in
                guard let self else { return }; self.session.finish()
                switch result {
                case .success: self.collapse()
                case .failure(let error): self.state.mode = .failure; self.state.detail = error.localizedDescription; self.autoHide(after: 8)
                }
            }
            return
        }
        guard let candidate = pendingDrop.target.candidate else { session.finish(); collapse(); return }
        let sources = pendingDrop.sources
        model.performOverlayBatchDrop(sources: sources, candidate: candidate, configurationRevision: pendingDrop.revision) { [weak self] result in
            guard let self else { return }
            self.session.finish()
            switch result {
            case .success(let record):
                self.lastRecord = record; self.state.canUndo = record.canUndo
                if record.state == .completed && record.movedCount == sources.count {
                    self.state.mode = .success; self.state.detail = "파일 \(record.movedCount)개를 \(candidate.name)로 이동했습니다."
                } else {
                    self.state.mode = .failure; self.state.detail = record.message ?? "이동 완료를 확인하지 못했습니다. 기존 정리 내역에서 위치를 확인해 주세요."
                }
            case .failure(let error): self.state.mode = .failure; self.state.detail = error.localizedDescription
            }
            self.scheduleCatalogueRefresh(); self.autoHide(after: 8)
        }
    }

    private func exited(_ info: NSDraggingInfo?) {
        if let info { trace("exited", info) }
        guard info == nil || session.token?.sequence == info?.draggingSequenceNumber, session.phase != .moving else { return }
        session.hover(nil); state.hoveredID = nil
        // Keep the receiver and frozen card geometry until the native drag ends; no exit/re-entry resize loop.
    }

    private func ended(_ info: NSDraggingInfo) {
        trace("ended", info)
        guard session.token?.sequence == info.draggingSequenceNumber else { return }; endSession()
    }

    private func endSession() {
        guard let token = session.token else { return }
        let rejected = session.phase == .rejected
        session.ended(sequence: token.sequence); receivedDrag = false; model.setDragging(false); state.dragging = false; state.hoveredID = nil
        if session.phase == .moving { startPendingDrop(); return }
        if session.phase == .finished { return }
        if rejected {
            autoHide(after: 4)
        } else { collapse() }
    }

    private func collapse() {
        guard session.phase != .moving else { return }
        feedbackTimer?.invalidate(); feedbackTimer = nil; session.reset()
        hideCenterGuides(); snappedAxes = []
        resizeHandles?.isHidden = true
        controlsPanel?.orderOut(nil)
        receivedDrag = false; model.setDragging(false); state.dragging = false; state.hoveredID = nil
        guard let content, let receiver, presented, !hiding else { return }
        hiding = true; presentationGeneration = UUID(); let generation = presentationGeneration
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.1 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if reduce { content.animator().alphaValue = 0 }
            else { content.animator().setFrameOrigin(CGPoint(x: content.frame.minX, y: receiver.bounds.height)) }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationGeneration == generation else { return }
                self.hiding = false; self.state.mode = .hidden; self.state.targets = []; self.state.canUndo = false
                self.presented = false; self.activeScreen = nil; self.position()
                self.panel?.ignoresMouseEvents = NSEvent.pressedMouseButtons & 1 == 0
                if self.model.snapshot.editing { self.snapshotChanged() }
            }
        }
    }
    private func autoHide(after seconds: TimeInterval) {
        feedbackTimer?.invalidate()
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.receivedDrag, self.state.mode != .editing else { return }
                if self.panel?.frame.contains(NSEvent.mouseLocation) == true || self.controlsPanel?.frame.contains(NSEvent.mouseLocation) == true { self.autoHide(after: 2) }
                else { self.collapse() }
            }
        }
    }

    private func showConnections() { model.showConnections(); collapse() }

    private func undo() {
        guard let record = lastRecord, !model.busy else { return }
        feedbackTimer?.invalidate(); state.mode = .moving; state.canUndo = false; state.detail = "원래 위치와 파일을 확인합니다…"
        model.undoOverlayDrop(record) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.lastRecord = value; self.state.canUndo = value.canUndo
                self.state.mode = value.state == .undone ? .undone : .failure
                self.state.detail = value.state == .undone ? "파일 \(value.entries.filter { $0.state == .undone }.count)개를 원래 위치로 되돌렸습니다." : value.message ?? "기존 정리 내역에서 파일 상태를 확인해 주세요."
            case .failure(let error): self.state.mode = .failure; self.state.detail = error.localizedDescription; self.state.canUndo = true
            }
            self.scheduleCatalogueRefresh(); self.autoHide(after: 8)
        }
    }

    /// Opt-in fixture diagnostics; never enabled by normal launches or saved settings.
    private func trace(_ event: String, _ info: NSDraggingInfo) {
        guard traceURL != nil else { return }
        let value: [String: Any] = ["event": event, "sequence": info.draggingSequenceNumber,
            "mask": info.draggingSourceOperationMask.rawValue, "items": info.draggingPasteboard.pasteboardItems?.count ?? 0,
            "types": (info.draggingPasteboard.types ?? []).map(\.rawValue), "source": session.source ?? "",
            "targets": session.targets.map(\.id), "sourceCount": session.sources.count, "hover": session.hoveredID ?? "",
            "phase": String(describing: session.phase), "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "time": Date().timeIntervalSince1970, "panelMask": panel?.styleMask.rawValue ?? 0]
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(10)
        if traceBuffer.count + data.count <= FolderOverlayPipe.maximumPacketBytes { traceBuffer.append(data) }
    }
    private func flushTrace() {
        guard let traceURL, !traceBuffer.isEmpty, !receivedDrag, NSEvent.pressedMouseButtons == 0 else { return }
        let data = traceBuffer; traceBuffer.removeAll(keepingCapacity: true)
        if !FileManager.default.fileExists(atPath: traceURL.path) { FileManager.default.createFile(atPath: traceURL.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: traceURL) {
            defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }
}
