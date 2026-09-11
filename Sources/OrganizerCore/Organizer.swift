import Foundation

public final class Organizer: Sendable {
    public let store: JournalStore
    public init(store: JournalStore) { self.store = store }

    @discardableResult
    public func execute(plan: ScanPlan, selectedIDs: Set<UUID>, cancelled: () -> Bool = { false },
                        progress: (EngineProgress) -> Void = { _ in }) throws -> RunRecord {
        try store.withExclusiveLock {
            let selected = plan.proposals.filter { selectedIDs.contains($0.id) }
            let explicitFolders = plan.directoryCreationPlan?.explicitDirectories ?? []
            guard (!selected.isEmpty || !explicitFolders.isEmpty), selected.count == selectedIDs.count, selected.count <= 500,
                  selected.allSatisfy({ $0.decision.executable && $0.destination != nil && $0.snapshot != nil }) else {
                throw OrganizerError("실행할 수 있는 항목을 선택해 주세요. 한 번에 최대 500개까지 정리할 수 있습니다.")
            }
            var record = RunRecord(id: UUID(), createdAt: Date(), updatedAt: Date(), state: .running,
                                   sourceRoots: plan.sourceRoots, sourceRootIdentities: plan.sourceRootIdentities,
                                   destinationRoot: plan.destinationRoot, destinationAnchor: plan.destinationAnchor,
                                   destinationAnchorIdentity: plan.destinationAnchorIdentity, rules: plan.rules,
                                   entries: selected.map { .init(id: $0.id, source: $0.source, destination: $0.destination!, snapshot: $0.snapshot!, state: .pending) },
                                   createdDirectories: [])
            record.destinationParentIdentities = plan.destinationParentIdentities
            if let parents = plan.sourceParentIdentities {
                let selectedParents = Set(selected.map { URL(fileURLWithPath: $0.source).deletingLastPathComponent().path })
                record.sourceParentIdentities = parents.filter { selectedParents.contains($0.key) }
            }
            if var directories = plan.directoryCreationPlan {
                let requested = selected.map { URL(fileURLWithPath: $0.destination!).deletingLastPathComponent() }
                    + explicitFolders.map { URL(fileURLWithPath: $0) }
                directories.paths = directories.paths.filter { path in
                    path == plan.destinationRoot || requested.contains { PathSafety.contains(URL(fileURLWithPath: path), $0) }
                }
                directories.existingIdentities = directories.existingIdentities.filter { directories.paths.contains($0.key) }
                record.directoryCreationPlan = directories
            }
            try validateRecord(record)
            try validateContext(record)
            try validatePlannedDirectories(record)
            // All selected operations are checked before any directory creation or file move.
            for (index, entry) in record.entries.enumerated() {
                if cancelled() { throw CancellationError() }
                progress(.init(index, record.entries.count, "원본과 새 위치 확인 · \(URL(fileURLWithPath: entry.source).lastPathComponent)"))
                try validateForward(entry, record: record, cancelled: cancelled)
            }
            try Planner.verifyReferences(selected, roots: record.sourceRoots.map { URL(fileURLWithPath: $0) }, rules: record.rules)
            try store.save(record)
            do {
                if let directories = record.directoryCreationPlan {
                    for path in directories.paths where directories.existingIdentities[path] == nil {
                        if cancelled() { throw CancellationError() }
                        progress(.init(record.createdDirectories.count, directories.paths.count, "폴더 만드는 중 · \(URL(fileURLWithPath: path).lastPathComponent)"))
                        try validateContext(record)
                        try validatePlannedDirectories(record)
                        let url = URL(fileURLWithPath: path)
                        guard let parentIdentity = destinationParentIdentity(url.deletingLastPathComponent(), record: record) else {
                            throw OrganizerError("새 폴더의 상위 위치를 확인할 수 없습니다.")
                        }
                        let created = try SafeFileSystem.createDirectory(url, expectedParent: parentIdentity)
                        record.createdDirectories.append(created)
                        record.updatedAt = Date(); try store.save(record)
                        try SafeFileSystem.withDirectoryFD(url.deletingLastPathComponent()) { try SafeFileSystem.syncFD($0) }
                    }
                    // Folder creation may take time. Recheck the entire batch before its first move.
                    try validateContext(record)
                    for entry in record.entries {
                        if cancelled() { throw CancellationError() }
                        try validateForward(entry, record: record, cancelled: cancelled)
                    }
                    try Planner.verifyReferences(selected, roots: record.sourceRoots.map { URL(fileURLWithPath: $0) }, rules: record.rules)
                }
                for index in record.entries.indices {
                    if cancelled() {
                        record.state = .interrupted; record.message = "사용자가 중단했습니다. 완료한 항목은 기록에 남았습니다."; break
                    }
                    let entry = record.entries[index]
                    try validateContext(record)
                    try validateForward(entry, record: record, cancelled: cancelled)
                    try ensureDestinationParents(URL(fileURLWithPath: entry.destination).deletingLastPathComponent(), record: &record)
                    record.entries[index].state = .moving; record.updatedAt = Date(); try store.save(record)
                    progress(.init(index, record.entries.count, "정리 중 · \(URL(fileURLWithPath: entry.source).lastPathComponent)"))
                    try SafeFileSystem.moveExclusively(from: URL(fileURLWithPath: entry.source), to: URL(fileURLWithPath: entry.destination), expectedIdentity: entry.snapshot.rootIdentity,
                                                      expectedDestinationParent: destinationParentIdentity(URL(fileURLWithPath: entry.destination).deletingLastPathComponent(), record: record),
                                                      expectedSourceParent: record.sourceParentIdentities?[URL(fileURLWithPath: entry.source).deletingLastPathComponent().path])
                    let after = try SafeFileSystem.snapshot(URL(fileURLWithPath: entry.destination), rules: record.rules)
                    guard after == entry.snapshot else { throw OrganizerError("이동 뒤 자료의 변경이 감지되었습니다. 기록의 두 위치를 확인해 주세요.") }
                    record.entries[index].state = .moved; record.updatedAt = Date(); try store.save(record)
                    progress(.init(index + 1, record.entries.count, "\(index + 1)개 정리 완료"))
                }
                if record.entries.allSatisfy({ $0.state == .moved }) { record.state = .completed; record.message = nil }
                record.updatedAt = Date(); try store.save(record)
                return record
            } catch {
                record.state = .interrupted; record.message = error.localizedDescription; record.updatedAt = Date()
                try? store.save(record)
                return record
            }
        }
    }

    @discardableResult
    public func inspect(_ id: UUID) throws -> RunRecord {
        try store.withExclusiveLock {
            var record = try store.load(id)
            try validateRecord(record); try validateContext(record)
            reconcile(&record)
            try store.save(record)
            return record
        }
    }

    @discardableResult
    public func undo(_ id: UUID, progress: (EngineProgress) -> Void = { _ in }) throws -> RunRecord {
        try store.withExclusiveLock {
            var record = try store.load(id)
            try validateRecord(record); try validateContext(record)
            reconcile(&record)
            try store.save(record)
            guard !record.entries.contains(where: { $0.state == .attention }), record.canUndo else {
                throw OrganizerError(record.state == .undone ? "이미 되돌린 작업입니다." : "변경되거나 찾을 수 없는 항목이 있습니다. 기록의 위치를 먼저 확인해 주세요.")
            }
            let indices = record.entries.indices.filter { record.entries[$0].state == .moved }.reversed()
            // Undo is preflighted as a batch too; a new file at an original path stops the whole undo.
            for index in indices { try validateUndo(record.entries[index], record: record) }
            record.state = .undoing; record.updatedAt = Date(); try store.save(record)
            do {
                for (count, index) in indices.enumerated() {
                    let entry = record.entries[index]
                    try validateContext(record); try validateUndo(entry, record: record)
                    record.entries[index].state = .undoing; record.updatedAt = Date(); try store.save(record)
                    progress(.init(count, indices.count, "되돌리는 중 · \(URL(fileURLWithPath: entry.source).lastPathComponent)"))
                    try SafeFileSystem.moveExclusively(from: URL(fileURLWithPath: entry.destination), to: URL(fileURLWithPath: entry.source), expectedIdentity: entry.snapshot.rootIdentity,
                                                      expectedDestinationParent: record.sourceParentIdentities?[URL(fileURLWithPath: entry.source).deletingLastPathComponent().path],
                                                      expectedSourceParent: destinationParentIdentity(URL(fileURLWithPath: entry.destination).deletingLastPathComponent(), record: record))
                    guard try SafeFileSystem.snapshot(URL(fileURLWithPath: entry.source), rules: record.rules) == entry.snapshot else {
                        throw OrganizerError("되돌린 자료의 변경이 감지되었습니다. 원래 위치를 확인해 주세요.")
                    }
                    record.entries[index].state = .undone; record.updatedAt = Date(); try store.save(record)
                    progress(.init(count + 1, indices.count, "\(count + 1)개 되돌림 완료"))
                }
                // Only empty directories created by this run and still having the same inode are eligible.
                for directory in record.createdDirectories.reversed() { try SafeFileSystem.removeCreatedDirectoryIfEmpty(directory) }
                record.state = .undone; record.message = nil; record.updatedAt = Date(); try store.save(record)
                return record
            } catch {
                record.state = .attention; record.message = error.localizedDescription; record.updatedAt = Date()
                try? store.save(record)
                return record
            }
        }
    }

    private func validateRecord(_ record: RunRecord) throws {
        let folderOnly = record.entries.isEmpty && !(record.directoryCreationPlan?.explicitDirectories.isEmpty ?? true)
        guard record.version == 1, (folderOnly || (!record.sourceRoots.isEmpty && !record.entries.isEmpty)),
              record.entries.count <= 500, record.entries.reduce(0, { $0 + $1.snapshot.entries.count }) <= 50_000 else {
            throw OrganizerError("지원하지 않거나 너무 큰 실행 기록입니다.")
        }
        try record.rules.validate()
        let target = try PathSafety.canonicalRoot(URL(fileURLWithPath: record.destinationRoot))
        guard target.path == record.destinationRoot else { throw OrganizerError("정리 위치가 다른 경로로 연결되어 있습니다.") }
        let roots = try record.sourceRoots.map { try PathSafety.canonicalRoot(URL(fileURLWithPath: $0)) }
        guard roots.map(\.path) == record.sourceRoots, roots.allSatisfy({ record.sourceRootIdentities[$0.path] != nil }) else {
            throw OrganizerError("원래 폴더 경로가 바뀌었습니다.")
        }
        var destinations = Set<String>(); var sources = Set<String>(); var ids = Set<UUID>()
        for entry in record.entries {
            let source = PathSafety.lexicalURL(URL(fileURLWithPath: entry.source))
            let destination = PathSafety.lexicalURL(URL(fileURLWithPath: entry.destination))
            guard source.path == entry.source, destination.path == entry.destination,
                  roots.contains(where: { PathSafety.contains($0, source) && $0.path != source.path }),
                  PathSafety.contains(target, destination), target.path != destination.path,
                  !PathSafety.contains(source, destination), !PathSafety.contains(destination, source),
                  !record.rules.isProtectedPath(source),
                  ids.insert(entry.id).inserted,
                  sources.insert(source.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  destinations.insert(destination.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  let first = entry.snapshot.entries.first, first.relativePath.isEmpty,
                  ["file", "directory"].contains(first.identity.kind),
                  entry.snapshot.entries.count <= record.rules.maximumSnapshotEntries,
                  entry.snapshot.totalBytes >= 0, entry.snapshot.totalBytes <= record.rules.maximumSnapshotBytes else {
                throw OrganizerError("실행 항목이 허용된 폴더 범위를 벗어나거나 서로 겹칩니다.")
            }
            try PathSafety.validateComponent(source.lastPathComponent); try PathSafety.validateComponent(destination.lastPathComponent)
            for other in record.entries where other.id != entry.id {
                let otherSource = URL(fileURLWithPath: other.source), otherDestination = URL(fileURLWithPath: other.destination)
                guard !PathSafety.contains(source, otherSource), !PathSafety.contains(destination, otherDestination),
                      !PathSafety.contains(source, otherDestination), !PathSafety.contains(destination, otherSource) else {
                    throw OrganizerError("상위 폴더와 하위 폴더를 한 번에 이동할 수 없습니다.")
                }
            }
        }
        for directory in record.createdDirectories {
            guard PathSafety.contains(target, URL(fileURLWithPath: directory.path)), directory.identity.kind == "directory" else {
                throw OrganizerError("새로 만든 폴더 기록이 정리 위치 밖을 가리킵니다.")
            }
        }
        if let parents = record.sourceParentIdentities {
            guard Set(parents.keys) == Set(record.entries.map { URL(fileURLWithPath: $0.source).deletingLastPathComponent().path }),
                  parents.values.allSatisfy({ $0.kind == "directory" }) else {
                throw OrganizerError("원본 파일의 상위 폴더 기록이 올바르지 않습니다.")
            }
        }
        if let parents = record.destinationParentIdentities {
            guard record.directoryCreationPlan == nil, record.createdDirectories.isEmpty,
                  Set(parents.keys) == Set(record.entries.map { URL(fileURLWithPath: $0.destination).deletingLastPathComponent().path }),
                  parents.values.allSatisfy({ $0.kind == "directory" }) else {
                throw OrganizerError("기존 폴더에만 이동할 수 있는 기록의 목적지가 올바르지 않습니다.")
            }
        }
        if let directories = record.directoryCreationPlan {
            let paths = Set(directories.paths)
            guard paths.count == directories.paths.count, paths.count <= 2_001,
                  paths.contains(target.path), directories.existingIdentities[target.path] == record.destinationAnchorIdentity,
                  record.destinationAnchor == target.path,
                  Set(directories.existingIdentities.keys).isSubset(of: paths),
                  Set(directories.explicitDirectories).isSubset(of: paths),
                  record.entries.allSatisfy({ paths.contains(URL(fileURLWithPath: $0.destination).deletingLastPathComponent().path) }),
                  record.createdDirectories.allSatisfy({ paths.contains($0.path) && directories.existingIdentities[$0.path] == nil }),
                  directories.existingIdentities.values.allSatisfy({ $0.kind == "directory" && $0.device == record.destinationAnchorIdentity.device }) else {
                throw OrganizerError("확인한 폴더 생성 계획이 올바르지 않습니다.")
            }
            var canonicalKeys = Set<String>()
            for path in directories.paths {
                let url = URL(fileURLWithPath: path)
                guard PathSafety.lexicalURL(url).path == path, PathSafety.contains(target, url),
                      canonicalKeys.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                      url.pathComponents.count - target.pathComponents.count <= 32,
                      path == target.path || paths.contains(url.deletingLastPathComponent().path),
                      !record.entries.contains(where: { PathSafety.contains(URL(fileURLWithPath: $0.source), url) || $0.destination == path }) else {
                    throw OrganizerError("만들 폴더가 허용 범위를 벗어나거나 파일 경로와 겹칩니다.")
                }
                if path != target.path {
                    try PathSafety.validateComponent(url.lastPathComponent)
                    guard !OrganizerRules.managedNames.contains(url.lastPathComponent),
                          !url.lastPathComponent.hasPrefix("DerivedData"), !OrganizerRules.projectMarkers.contains(url.lastPathComponent),
                          !OrganizerRules.packageExtensions.contains(url.pathExtension.lowercased()),
                          !record.rules.isProtectedPath(url) else { throw OrganizerError("보호 경로에 폴더를 만들 수 없습니다.") }
                }
            }
        }
        let anchor = URL(fileURLWithPath: record.destinationAnchor)
        guard PathSafety.contains(anchor, target), anchor.pathComponents.count >= 3 else { throw OrganizerError("정리 위치의 기준 경로가 올바르지 않습니다.") }
    }

    private func validateContext(_ record: RunRecord) throws {
        if let parents = record.sourceParentIdentities {
            for (path, identity) in parents {
                let url = URL(fileURLWithPath: path)
                try SafeFileSystem.validateDirectory(url)
                guard try SafeFileSystem.identity(at: url) == identity else { throw OrganizerError("원본 파일이 있던 상위 폴더가 바뀌었습니다.") }
            }
        }
        for root in record.sourceRoots {
            let url = URL(fileURLWithPath: root)
            try SafeFileSystem.validateDirectory(url)
            guard try SafeFileSystem.identity(at: url) == record.sourceRootIdentities[root] else { throw OrganizerError("선택했던 원래 폴더가 바뀌었습니다.") }
            if let reason = try SafeFileSystem.protectionReason(url, rules: record.rules, includeDescendantPaths: false) {
                throw OrganizerError("확인할 폴더의 상태가 바뀌었습니다. \(reason)")
            }
        }
        let anchor = URL(fileURLWithPath: record.destinationAnchor)
        try SafeFileSystem.validateDirectory(anchor)
        guard try SafeFileSystem.identity(at: anchor) == record.destinationAnchorIdentity else { throw OrganizerError("정리 위치의 상위 폴더가 바뀌었습니다.") }
        try Planner.validateDestination(URL(fileURLWithPath: record.destinationRoot), rules: record.rules)
        if let parents = record.destinationParentIdentities {
            for (path, identity) in parents {
                let url = URL(fileURLWithPath: path)
                try SafeFileSystem.validateDirectory(url)
                guard try SafeFileSystem.identity(at: url) == identity else {
                    throw OrganizerError("선택했던 목적지 폴더가 사라졌거나 바뀌었습니다.")
                }
            }
        }
        if let directories = record.directoryCreationPlan {
            for (path, identity) in directories.existingIdentities {
                let url = URL(fileURLWithPath: path)
                try SafeFileSystem.validateDirectory(url)
                guard try SafeFileSystem.identity(at: url) == identity else { throw OrganizerError("미리보기에서 확인한 기존 폴더가 바뀌었습니다.") }
                try Planner.validateDestination(url, rules: record.rules)
            }
        }
    }

    private func validateForward(_ entry: RunEntry, record: RunRecord, cancelled: () -> Bool) throws {
        let source = URL(fileURLWithPath: entry.source), destination = URL(fileURLWithPath: entry.destination)
        guard !SafeFileSystem.exists(destination) else { throw OrganizerError("새 위치에 같은 이름의 항목이 생겼습니다. 다시 분석해 주세요.") }
        try SafeFileSystem.validateDirectory(source.deletingLastPathComponent())
        if record.directoryCreationPlan != nil {
            _ = try ExistingFileDrop.inspect(source)
            try SafeFileSystem.validateMovePermissions(source: source, destinationParent: destination.deletingLastPathComponent())
            try SelectedFilesPlanner.validateSourceAncestors(source.deletingLastPathComponent(), rules: record.rules)
            try validatePlannedDirectories(record)
        }
        try Planner.validateDestination(destination.deletingLastPathComponent(), rules: record.rules)
        let anchor = try SafeFileSystem.nearestExistingDirectory(destination.deletingLastPathComponent())
        guard try SafeFileSystem.identity(at: anchor).device == entry.snapshot.rootIdentity.device else { throw OrganizerError("첫 버전은 같은 디스크 안의 이동만 지원합니다.") }
        guard try SafeFileSystem.snapshot(source, rules: record.rules, cancelled: cancelled) == entry.snapshot else {
            throw OrganizerError("\(source.lastPathComponent)이 미리보기 이후 수정되었습니다. 다시 분석해 주세요.")
        }
    }

    private func validateUndo(_ entry: RunEntry, record: RunRecord) throws {
        let source = URL(fileURLWithPath: entry.source), destination = URL(fileURLWithPath: entry.destination)
        guard !SafeFileSystem.exists(source) else { throw OrganizerError("원래 위치에 새 항목이 있습니다. 덮어쓰지 않고 되돌리기를 멈췄습니다: \(source.lastPathComponent)") }
        try SafeFileSystem.validateDirectory(source.deletingLastPathComponent())
        var ancestor = source.deletingLastPathComponent()
        while ancestor.pathComponents.count >= 3 {
            if let reason = try SafeFileSystem.protectionReason(ancestor, rules: record.rules, includeDescendantPaths: false) { throw OrganizerError("원래 위치의 상태가 바뀌었습니다. \(reason)") }
            if record.sourceRoots.contains(ancestor.path) { break }
            ancestor.deleteLastPathComponent()
        }
        guard try SafeFileSystem.snapshot(destination, rules: record.rules) == entry.snapshot else {
            throw OrganizerError("정리 이후 수정된 자료가 있습니다. 현재 자료를 보존하기 위해 되돌리기를 멈췄습니다.")
        }
    }

    private func ensureDestinationParents(_ parent: URL, record: inout RunRecord) throws {
        let target = URL(fileURLWithPath: record.destinationRoot)
        guard PathSafety.contains(target, parent) else { throw OrganizerError("목적지 폴더가 정리 위치 밖에 있습니다.") }
        if record.directoryCreationPlan != nil {
            try SafeFileSystem.validateDirectory(parent)
            guard let expected = destinationParentIdentity(parent, record: record),
                  try SafeFileSystem.identity(at: parent) == expected else { throw OrganizerError("확인한 목적지 폴더가 바뀌었습니다.") }
            return
        }
        if let parents = record.destinationParentIdentities {
            try SafeFileSystem.validateDirectory(parent)
            guard try SafeFileSystem.identity(at: parent) == parents[parent.path] else {
                throw OrganizerError("선택했던 목적지 폴더가 바뀌었습니다. 새 폴더를 만들지 않습니다.")
            }
            return
        }
        let nearest = try SafeFileSystem.nearestExistingDirectory(parent)
        var cursor = nearest
        for component in parent.pathComponents.dropFirst(nearest.pathComponents.count) {
            cursor.appendPathComponent(component, isDirectory: true)
            guard PathSafety.contains(target, cursor) else { throw OrganizerError("정리 위치 밖에 폴더를 만들 수 없습니다.") }
            record.createdDirectories.append(try SafeFileSystem.createDirectory(cursor))
            record.updatedAt = Date(); try store.save(record)
        }
    }

    private func destinationParentIdentity(_ parent: URL, record: RunRecord) -> FileIdentity? {
        record.directoryCreationPlan?.existingIdentities[parent.path]
            ?? record.createdDirectories.first { $0.path == parent.path }?.identity
            ?? record.destinationParentIdentities?[parent.path]
    }

    /// A path absent during preview cannot silently become somebody else's directory.
    private func validatePlannedDirectories(_ record: RunRecord) throws {
        guard let directories = record.directoryCreationPlan else { return }
        for path in directories.paths where directories.existingIdentities[path] == nil {
            let url = URL(fileURLWithPath: path)
            if let created = record.createdDirectories.first(where: { $0.path == path }) {
                try SafeFileSystem.validateDirectory(url)
                guard try SafeFileSystem.identity(at: url) == created.identity else { throw OrganizerError("이번 작업에서 만든 폴더가 바뀌었습니다.") }
            } else if SafeFileSystem.exists(url) {
                throw OrganizerError("새로 만들 위치에 다른 항목이 생겼습니다. 다시 미리보기를 확인해 주세요.")
            }
        }
    }

    private func reconcile(_ record: inout RunRecord) {
        if record.state == .undone { return }
        if record.entries.isEmpty {
            // Folder-only runs have no move states to reconcile. Ownership stays in createdDirectories.
            if record.state == .running { record.state = .interrupted }
            record.updatedAt = Date()
            return
        }
        for index in record.entries.indices {
            let entry = record.entries[index]
            if entry.state == .pending || entry.state == .undone { continue }
            let source = URL(fileURLWithPath: entry.source), destination = URL(fileURLWithPath: entry.destination)
            do {
                if !SafeFileSystem.exists(source), SafeFileSystem.exists(destination),
                   try SafeFileSystem.snapshot(destination, rules: record.rules) == entry.snapshot {
                    record.entries[index].state = .moved; record.entries[index].note = nil
                } else if SafeFileSystem.exists(source), !SafeFileSystem.exists(destination),
                          try SafeFileSystem.snapshot(source, rules: record.rules) == entry.snapshot {
                    record.entries[index].state = entry.state == .moving ? .pending : .undone
                    record.entries[index].note = nil
                } else {
                    record.entries[index].state = .attention
                    record.entries[index].note = "원래 위치와 새 위치의 상태가 기록과 다릅니다. 자동으로 덮어쓰지 않습니다."
                }
            } catch {
                record.entries[index].state = .attention; record.entries[index].note = error.localizedDescription
            }
        }
        if record.entries.contains(where: { $0.state == .attention }) {
            record.state = .attention; record.message = "일부 자료가 변경되었거나 위치를 확인할 수 없습니다."
        } else if record.entries.allSatisfy({ $0.state == .moved }) {
            record.state = .completed; record.message = nil
        } else if record.entries.contains(where: { $0.state == .undone }) && !record.entries.contains(where: { $0.state == .moved }) {
            let ownedDirectoriesRemain = record.createdDirectories.contains { directory in
                (try? SafeFileSystem.identity(at: URL(fileURLWithPath: directory.path))) == directory.identity
            }
            record.state = ownedDirectoriesRemain ? .undoing : .undone
            record.message = ownedDirectoriesRemain ? "파일은 원래 위치에 있습니다. 이번 작업에서 만든 빈 폴더를 되돌릴 수 있습니다." : nil
        } else {
            record.state = .interrupted; record.message = "완료한 이동과 아직 실행하지 않은 항목을 확인했습니다."
        }
        record.updatedAt = Date()
    }
}
