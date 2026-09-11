import Foundation

struct ReferenceDocument {
    var path: URL
    var text: String
}

struct ReferenceIndex {
    var documents: [ReferenceDocument] = []
    var complete = true
    var warnings: [String] = []

    func reference(to source: URL) -> URL? {
        let path = source.path.precomposedStringWithCanonicalMapping.lowercased()
        let encoded = source.absoluteString.lowercased()
        let name = source.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        for document in documents {
            if PathSafety.contains(source, document.path) {
                if document.text.contains(path) || document.text.contains(encoded) { return document.path }
            } else if document.text.contains(path) || document.text.contains(encoded) || document.text.contains(name) {
                return document.path
            }
        }
        return nil
    }
}

public enum Planner {
    public static func analyze(sources: [URL], destination: URL, rules: OrganizerRules,
                               cancelled: () -> Bool = { false }, progress: (EngineProgress) -> Void = { _ in }) throws -> ScanPlan {
        try rules.validate()
        let roots = try PathSafety.nonOverlappingRoots(sources)
        guard !roots.isEmpty else { throw OrganizerError("먼저 확인할 폴더를 추가해 주세요.") }
        let target = try PathSafety.canonicalRoot(destination)
        try validateDestination(target, rules: rules)
        let anchor = try SafeFileSystem.nearestExistingDirectory(target)
        var identities: [String: FileIdentity] = [:]
        for root in roots {
            try SafeFileSystem.validateDirectory(root)
            identities[root.path] = try SafeFileSystem.identity(at: root)
        }
        var proposals: [Proposal] = []
        var warnings: [String] = []
        var items: [URL] = []
        for root in roots {
            if PathSafety.contains(target, root) {
                proposals.append(.init(source: root.path, decision: .excluded, reason: "이미 정리 위치 안에 있는 폴더입니다.", isDirectory: true))
                continue
            }
            if let reason = try SafeFileSystem.protectionReason(root, rules: rules, includeDescendantPaths: false) {
                proposals.append(.init(source: root.path, decision: .keep, reason: reason, isDirectory: true))
                continue
            }
            items += try SafeFileSystem.children(root)
        }
        for (index, item) in items.enumerated() {
            if cancelled() { throw CancellationError() }
            progress(.init(index, items.count, "폴더 구조 확인 · \(item.lastPathComponent)"))
            let directory: Bool
            do { directory = try SafeFileSystem.isDirectory(item) }
            catch {
                proposals.append(.init(source: item.path, decision: .review, reason: error.localizedDescription, isDirectory: false))
                warnings.append("일부 항목에 접근하지 못했습니다."); continue
            }
            if PathSafety.contains(target, item) || PathSafety.contains(item, target) {
                proposals.append(.init(source: item.path, decision: .excluded, reason: "정리 위치 또는 정리 위치를 포함한 폴더입니다.", isDirectory: directory)); continue
            }
            do {
                if let reason = try SafeFileSystem.protectionReason(item, rules: rules) {
                    let decision: Decision = item.lastPathComponent.hasPrefix(".") ? .excluded : .keep
                    proposals.append(.init(source: item.path, decision: decision, reason: reason, isDirectory: directory)); continue
                }
                try PathSafety.validateComponent(item.lastPathComponent)
                let snapshot = try SafeFileSystem.snapshot(item, rules: rules, cancelled: cancelled)
                if directory && snapshot.fileCount == 0 {
                    proposals.append(.init(source: item.path, decision: .keep, reason: "빈 폴더는 현재 위치를 유지합니다.", isDirectory: true)); continue
                }
                let category = categoryFor(item.lastPathComponent, rules: rules)
                let destination = try category.map { try destinationFor(item, isDirectory: directory, category: $0, root: target, rules: rules) }
                proposals.append(.init(source: item.path, destination: destination?.path,
                                       decision: destination == nil ? .review : destination?.deletingLastPathComponent() == item.deletingLastPathComponent() ? .rename : .move,
                                       reason: category == nil ? "이름만으로 용도를 정하기 어렵습니다. 분류를 직접 선택할 수 있습니다." : "이름 규칙 일치 · \(category!)",
                                       isDirectory: directory, category: category, snapshot: snapshot, canAssignCategory: true))
            } catch is CancellationError { throw CancellationError() }
            catch {
                proposals.append(.init(source: item.path, decision: .review, reason: error.localizedDescription, isDirectory: directory))
            }
        }
        progress(.init(items.count, items.count, "선택한 폴더 안의 코드·문서 참조 확인"))
        let references = collectReferences(roots: roots, rules: rules, cancelled: cancelled)
        if cancelled() { throw CancellationError() }
        warnings += references.warnings
        for index in proposals.indices where proposals[index].snapshot != nil {
            if !references.complete {
                proposals[index].decision = .review; proposals[index].destination = nil
                proposals[index].canAssignCategory = false
                proposals[index].reason = "참조 확인이 끝나지 않아 실행에서 제외했습니다. 확인할 폴더 범위를 줄여 주세요."
            } else if let reference = references.reference(to: URL(fileURLWithPath: proposals[index].source)) {
                proposals[index].decision = .keep; proposals[index].destination = nil
                proposals[index].canAssignCategory = false
                proposals[index].reason = "\(reference.lastPathComponent)에서 참조합니다. 기존 경로를 유지합니다."
            }
        }
        var plan = ScanPlan(sourceRoots: roots.map(\.path), sourceRootIdentities: identities,
                            destinationRoot: target.path, destinationAnchor: anchor.path,
                            destinationAnchorIdentity: try SafeFileSystem.identity(at: anchor), proposals: proposals,
                            warnings: Array(Set(warnings)).sorted(), referenceFilesChecked: references.documents.count, rules: rules)
        refreshCollisions(&plan)
        return plan
    }

    public static func assignCategory(_ category: String, proposalID: UUID, plan: inout ScanPlan) throws {
        guard plan.rules.categories.contains(category), let index = plan.proposals.firstIndex(where: { $0.id == proposalID }),
              plan.proposals[index].canAssignCategory, plan.proposals[index].snapshot != nil else {
            throw OrganizerError("보호 대상은 분류를 바꿔 실행할 수 없습니다.")
        }
        let item = plan.proposals[index]
        let target = try destinationFor(URL(fileURLWithPath: item.source), isDirectory: item.isDirectory, category: category,
                                        root: URL(fileURLWithPath: plan.destinationRoot), rules: plan.rules)
        plan.proposals[index].category = category; plan.proposals[index].destination = target.path
        plan.proposals[index].reason = "직접 지정한 분류 · \(category)"
        refreshCollisions(&plan)
    }

    public static func categoryFor(_ name: String, rules: OrganizerRules) -> String? {
        if let match = rules.matchingProject(name) { return match.0.name }
        if rules.personalPrefixes.contains(where: { OrganizerRules.hasPrefix(name, $0) }) { return "개인" }
        if rules.referencePrefixes.contains(where: { OrganizerRules.hasPrefix(name, $0) }) { return "참고" }
        return nil
    }

    static func destinationFor(_ source: URL, isDirectory: Bool, category: String, root: URL, rules: OrganizerRules) throws -> URL {
        try PathSafety.validateComponent(category)
        let categoryRoot = root.appendingPathComponent(category, isDirectory: true)
        var name = source.lastPathComponent
        if isDirectory {
            let match = rules.matchingProject(name)
            if let match, match.0.name == category,
               name.compare(match.1, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return categoryRoot }
            name = try rules.normalFolderName(name, removing: match?.0.name == category ? match?.1 : nil)
        }
        try PathSafety.validateComponent(name)
        return categoryRoot.appendingPathComponent(name, isDirectory: isDirectory)
    }

    static func refreshCollisions(_ plan: inout ScanPlan) {
        let keyed = Dictionary(grouping: plan.proposals.filter { $0.destination != nil && $0.snapshot != nil }, by: {
            $0.destination!.precomposedStringWithCanonicalMapping.lowercased()
        })
        for i in plan.proposals.indices {
            guard let destination = plan.proposals[i].destination, plan.proposals[i].snapshot != nil else { continue }
            let item = plan.proposals[i]
            let target = URL(fileURLWithPath: destination)
            if destination == item.source {
                plan.proposals[i].decision = .keep; plan.proposals[i].reason = "이미 규칙에 맞는 위치입니다."; continue
            }
            if SafeFileSystem.exists(target) {
                plan.proposals[i].decision = .review; plan.proposals[i].reason = "같은 이름의 항목이 이미 있습니다. 덮어쓰지 않습니다."; continue
            }
            let key = destination.precomposedStringWithCanonicalMapping.lowercased()
            if keyed[key, default: []].count > 1 {
                plan.proposals[i].decision = .review; plan.proposals[i].reason = "여러 항목의 새 위치가 같습니다. 분류를 다르게 지정해 주세요."; continue
            }
            let others = plan.proposals.filter { $0.id != item.id }.compactMap(\.destination).map { URL(fileURLWithPath: $0) }
            if others.contains(where: { PathSafety.contains($0, target) || PathSafety.contains(target, $0) }) {
                plan.proposals[i].decision = .review; plan.proposals[i].reason = "이동할 폴더가 다른 목적지와 겹칩니다. 한 묶음씩 확인해 주세요."; continue
            }
            do { try validateDestination(target.deletingLastPathComponent(), rules: plan.rules) }
            catch { plan.proposals[i].decision = .review; plan.proposals[i].reason = error.localizedDescription; plan.proposals[i].canAssignCategory = false; continue }
            plan.proposals[i].decision = target.deletingLastPathComponent().path == URL(fileURLWithPath: item.source).deletingLastPathComponent().path ? .rename : .move
        }
    }

    public static func validateDestination(_ destination: URL, rules: OrganizerRules) throws {
        _ = try PathSafety.canonicalRoot(destination)
        var parent = destination
        while parent.pathComponents.count >= 3 {
            if SafeFileSystem.exists(parent) {
                try SafeFileSystem.validateDirectory(parent)
                if let reason = try SafeFileSystem.protectionReason(parent, rules: rules, includeDescendantPaths: false) {
                    throw OrganizerError("정리 위치로 쓸 수 없습니다. \(reason)")
                }
            }
            let next = parent.deletingLastPathComponent()
            if next.path == parent.path { break }
            parent = next
        }
    }

    static func collectReferences(roots: [URL], rules: OrganizerRules, cancelled: () -> Bool) -> ReferenceIndex {
        var result = ReferenceIndex(); var bytes: Int64 = 0; var visited = 0
        func visit(_ url: URL, projectContext: Bool) {
            if cancelled() || !result.complete { return }
            visited += 1
            if visited > 100_000 { result.complete = false; result.warnings.append("참조 조사 항목 수가 한도를 넘었습니다."); return }
            let name = url.lastPathComponent
            if name.hasPrefix(".") || OrganizerRules.managedNames.contains(name) || name.hasPrefix("DerivedData") { return }
            if OrganizerRules.packageExtensions.contains(url.pathExtension.lowercased()) { return }
            do {
                let identity = try SafeFileSystem.identity(at: url)
                if try identity.kind == "other" || SafeFileSystem.isAlias(url) { return }
                if identity.kind == "directory" {
                    let children = try SafeFileSystem.children(url)
                    let isProject = children.contains { OrganizerRules.projectMarkers.contains($0.lastPathComponent) || $0.pathExtension == "xcodeproj" }
                    if rules.isProtectedPath(url) && !projectContext && !isProject { return }
                    for child in children { visit(child, projectContext: projectContext || isProject) }
                } else if OrganizerRules.referenceExtensions.contains(url.pathExtension.lowercased()), !name.hasPrefix("~$") {
                    let info = try SafeFileSystem.info(url)
                    if info.st_size > 2 * 1_024 * 1_024 {
                        result.complete = false; result.warnings.append("큰 텍스트 파일이 있어 참조 확인을 완료하지 못했습니다."); return
                    }
                    if result.documents.count >= rules.maximumReferenceFiles || bytes + info.st_size > rules.maximumReferenceBytes {
                        result.complete = false; result.warnings.append("코드·문서 참조 조사 한도를 넘었습니다."); return
                    }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    bytes += info.st_size
                    result.documents.append(.init(path: url, text: text.precomposedStringWithCanonicalMapping.lowercased()))
                }
            } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
                // A binary plist or non-UTF8 text is not a completed reference check.
                result.complete = false; result.warnings.append("읽을 수 없는 문자 형식의 문서가 있습니다.")
            } catch {
                result.complete = false; result.warnings.append("일부 참조 문서에 접근하지 못했습니다: \(name)")
            }
        }
        for root in roots { visit(root, projectContext: false) }
        return result
    }

    static func verifyReferences(_ proposals: [Proposal], roots: [URL], rules: OrganizerRules) throws {
        let index = collectReferences(roots: roots, rules: rules, cancelled: { false })
        guard index.complete else { throw OrganizerError("코드·문서 참조를 다시 확인하지 못했습니다. 폴더 범위를 줄여 분석해 주세요.") }
        for item in proposals {
            if let reference = index.reference(to: URL(fileURLWithPath: item.source)) {
                throw OrganizerError("\(item.name)을 참조하는 \(reference.lastPathComponent)이 있습니다. 다시 분석해 주세요.")
            }
        }
    }
}
