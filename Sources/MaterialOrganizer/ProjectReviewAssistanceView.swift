import SwiftUI
import OrganizerCore

@MainActor
struct ProjectReviewAssistanceView: View {
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var owner: AppModel
    @ObservedObject private var assistance: ProjectReviewAssistance
    @State private var groupsExpanded = false
    @State private var rulesExpanded = false
    @State private var rulePresentation: RulePresentation?

    init(review: ProjectReviewModel, owner: AppModel, expandSavedRules: Bool = false) {
        self.review = review
        self.owner = owner
        _assistance = ObservedObject(wrappedValue: review.assistance)
        _groupsExpanded = State(initialValue: review.unresolvedCount > 0)
        _rulesExpanded = State(initialValue: expandSavedRules)
    }

    private var reviewActionsDisabled: Bool { owner.busy || !review.storeReadable }
    private var ruleActionsDisabled: Bool { reviewActionsDisabled || !assistance.storeReadable }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !review.clarificationGroups.isEmpty { clarificationSection }
            rulesSection
            Button {
                guard let draft = review.ruleDraft() else { return }
                rulePresentation = RulePresentation(draft: draft)
            } label: {
                Label("포함한 파일로 규칙 만들기", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .font(Theme.body(11))
            .disabled(ruleActionsDisabled || review.ruleDraft() == nil)
            .help("같은 원본 폴더·확장자·정리 위치의 파일을 포함한 뒤 규칙을 만들 수 있습니다.")
            .accessibilityIdentifier("review-rule-create")

            if let failure = assistance.failure {
                Text(failure)
                    .font(Theme.body(11))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("규칙 설정 오류: \(failure)")
            }
        }
        .font(Theme.body(12))
        .foregroundStyle(Color.black)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $rulePresentation) { presentation in
            ProjectReviewRuleSheet(review: review, owner: owner, draft: presentation.draft)
        }
    }

    private var clarificationSection: some View {
        DisclosureGroup("같이 확인하기 · \(review.clarificationGroups.count)묶음", isExpanded: $groupsExpanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(review.clarificationGroups) { group in clarificationRow(group) }
                }
                .padding(.top, 8)
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 230)
        }
        .font(Theme.body(12))
        .accessibilityIdentifier("review-clarification-groups")
    }

    private func clarificationRow(_ group: ReviewClarificationGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.question)
                    .font(Theme.body(12))
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(group.rowIDs.count)개")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.gray)
                    .fixedSize()
            }
            Text(group.detail)
                .font(Theme.body(11))
                .foregroundStyle(Theme.gray)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(group.names.prefix(3).enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(Theme.body(11))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(name)
                }
                if group.names.count > 3 {
                    Text("외 \(group.names.count - 3)개")
                        .font(Theme.body(10))
                        .foregroundStyle(Theme.gray)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("원본 폴더").font(Theme.body(10)).foregroundStyle(Theme.gray)
                PathText(path: group.sourceDirectory)
            }
            if let project = review.projectForGroup(group.id) {
                Text("지정한 프로젝트 · \(project.name)")
                    .font(Theme.body(11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    selectButton(group)
                    assignmentMenus(group)
                    deferButton(group)
                }
                VStack(alignment: .leading, spacing: 8) {
                    selectButton(group)
                    assignmentMenus(group)
                    deferButton(group)
                }
            }
            .disabled(reviewActionsDisabled)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func selectButton(_ group: ReviewClarificationGroup) -> some View {
        Button("이 파일만 선택") { review.selectGroup(group.id) }
            .buttonStyle(.plain)
            .font(Theme.body(11))
            .fixedSize()
            .help("이 묶음의 파일만 이동안에 포함합니다. 파일은 아직 이동하지 않습니다.")
            .accessibilityLabel("\(group.question) \(group.rowIDs.count)개 파일만 선택")
            .accessibilityIdentifier("group-select-\(group.id)")
    }

    private func assignmentMenus(_ group: ReviewClarificationGroup) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(review.savedProjects) { project in
                    Button(project.name) { review.assignProject(project.id, toGroup: group.id) }
                }
            } label: {
                Label("프로젝트", systemImage: "folder")
            }
            .font(Theme.body(11))
            .fixedSize()
            .disabled(review.savedProjects.isEmpty)
            .accessibilityLabel("\(group.rowIDs.count)개 파일의 프로젝트 지정")
            .accessibilityIdentifier("group-project-\(group.id)")

            if let project = review.projectForGroup(group.id) {
                Menu {
                    Button("프로젝트 폴더에 두기") { review.assignFolder("", toGroup: group.id) }
                    if !project.folders.isEmpty {
                        Divider()
                        ForEach(project.folders, id: \.self) { path in
                            Button(path) { review.assignFolder(path, toGroup: group.id) }
                        }
                    }
                } label: {
                    Label("하위 폴더", systemImage: "folder.badge.gearshape")
                }
                .font(Theme.body(11))
                .fixedSize()
                .accessibilityLabel("\(group.rowIDs.count)개 파일의 하위 폴더 지정")
                .accessibilityIdentifier("group-folder-\(group.id)")
            }
        }
    }

    private func deferButton(_ group: ReviewClarificationGroup) -> some View {
        Button("보류") { review.deferGroup(group.id) }
            .buttonStyle(.plain)
            .font(Theme.body(11))
            .foregroundStyle(Theme.gray)
            .fixedSize()
            .help("이 묶음을 이번 이동안에서 빼고 원래 위치에 둡니다.")
            .accessibilityLabel("\(group.rowIDs.count)개 파일 보류")
            .accessibilityIdentifier("group-defer-\(group.id)")
    }

    private var rulesSection: some View {
        DisclosureGroup("저장한 규칙 · \(assistance.rules.count)개", isExpanded: $rulesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("규칙은 정리 위치를 추천합니다. 이동안을 확인하고 실행하면 파일을 옮깁니다.")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.gray)
                    .fixedSize(horizontal: false, vertical: true)
                if assistance.rules.isEmpty {
                    Text("파일의 정리 위치를 지정한 뒤, 반복할 기준을 저장하세요.")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.gray)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(assistance.rules) { rule in ruleRow(rule) }
                        }
                        .padding(.trailing, 2)
                    }
                    .frame(maxHeight: 210)
                }
            }
            .padding(.top, 8)
        }
        .font(Theme.body(12))
        .accessibilityIdentifier("review-saved-rules")
    }

    private func ruleRow(_ rule: ProjectReviewRule) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(rule.filenamePrefix)로 시작 · \(extensionLabel(rule.fileExtension))")
                .font(Theme.body(12))
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("이 원본 폴더의 직속 파일만").font(Theme.body(10)).foregroundStyle(Theme.gray)
                PathText(path: rule.sourceDirectory)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("추천 위치 · \(review.project(rule.projectID)?.name ?? "연결되지 않은 프로젝트")")
                    .font(Theme.body(11))
                    .fixedSize(horizontal: false, vertical: true)
                PathText(path: destinationPath(root: rule.projectRootPath, folder: rule.folder))
            }
            HStack(spacing: 14) {
                Toggle("사용", isOn: Binding(
                    get: { rule.enabled },
                    set: { review.setRuleEnabled(rule.id, $0) }
                ))
                .toggleStyle(.checkbox)
                .font(Theme.body(11))
                .accessibilityLabel("\(rule.filenamePrefix) 규칙 사용")
                .accessibilityIdentifier("review-rule-toggle-\(rule.id)")
                Spacer(minLength: 0)
                Button("규칙 삭제") { review.removeRule(rule.id) }
                    .buttonStyle(.plain)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.gray)
                    .help("저장한 규칙만 삭제합니다. 파일은 그대로 둡니다.")
                    .accessibilityLabel("\(rule.filenamePrefix) 규칙 삭제")
                    .accessibilityIdentifier("review-rule-remove-\(rule.id)")
            }
            .disabled(ruleActionsDisabled)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private struct RulePresentation: Identifiable {
        let id = UUID()
        let draft: ReviewRuleDraft
    }
}

@MainActor
struct ProjectReviewRuleSheet: View {
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var owner: AppModel
    @ObservedObject private var assistance: ProjectReviewAssistance
    let draft: ReviewRuleDraft
    @State private var prefix: String
    @Environment(\.dismiss) private var dismiss

    init(review: ProjectReviewModel, owner: AppModel, draft: ReviewRuleDraft) {
        self.review = review
        self.owner = owner
        self.draft = draft
        _assistance = ObservedObject(wrappedValue: review.assistance)
        _prefix = State(initialValue: draft.prefix)
    }

    private var scopeIsCurrent: Bool {
        guard let current = review.ruleDraft() else { return false }
        return current.sourceDirectory == draft.sourceDirectory && current.fileExtension == draft.fileExtension &&
            current.projectID == draft.projectID && current.projectRootPath == draft.projectRootPath && current.folder == draft.folder
    }
    private var matchingNames: [String] {
        scopeIsCurrent ? review.ruleMatchingNames(prefix: prefix) : []
    }
    private var actionsDisabled: Bool {
        owner.busy || !review.storeReadable || !assistance.storeReadable
    }
    private var canSave: Bool {
        !actionsDisabled && scopeIsCurrent && prefix.count >= 2 &&
            !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !matchingNames.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("다음에도 이 위치 추천")
                .font(Theme.body(18))
                .fontWeight(.medium)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    prefixField
                    fixedScope
                    matchedFiles
                    Text("저장하면 다음 분석부터 이 기준으로 위치를 추천합니다. 파일 이동은 이동안을 확인한 뒤 실행합니다.")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    if !scopeIsCurrent {
                        Text("포함한 파일이나 정리 위치가 바뀌었습니다. 닫은 뒤 규칙 만들기를 다시 열어 적용 범위를 확인하세요.")
                            .font(Theme.body(12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let failure = assistance.failure ?? review.failure {
                        Text(failure)
                            .font(Theme.body(12))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("규칙 저장 오류: \(failure)")
                    }
                }
                .padding(.trailing, 2)
            }
            HStack {
                Button("취소") { dismiss() }
                    .buttonStyle(PillStyle(filled: false))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("규칙 저장") {
                    guard canSave else { return }
                    if review.rememberRule(prefix: prefix) { dismiss() }
                }
                .buttonStyle(PillStyle())
                .disabled(!canSave)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("review-rule-save")
            }
        }
        .padding(24)
        .frame(minWidth: 380, idealWidth: 460, maxWidth: 540, minHeight: 390, idealHeight: 520, maxHeight: 620)
        .font(Theme.body(12))
        .foregroundStyle(Color.black)
        .background(Color.white)
        .accessibilityIdentifier("review-rule-sheet")
    }

    private var prefixField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("파일명 시작 글자").font(Theme.body(12)).fontWeight(.medium)
            TextField("예: AAO_", text: $prefix)
                .textFieldStyle(.roundedBorder)
                .font(Theme.body(13))
                .disableAutocorrection(true)
                .disabled(actionsDisabled)
                .accessibilityLabel("규칙에 사용할 파일명 시작 글자")
                .accessibilityIdentifier("review-rule-prefix")
            Text("2글자 이상 입력하세요. AAO_처럼 구분자까지 넣으면 적용 범위가 분명해집니다.")
                .font(Theme.body(11))
                .foregroundStyle(Theme.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fixedScope: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text("원본 폴더 · 변경할 수 없음").font(Theme.body(11)).fontWeight(.medium)
                PathText(path: draft.sourceDirectory)
                Text("이 폴더의 직속 파일에만 적용하며, 하위 폴더는 포함하지 않습니다.")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("확장자 · \(extensionLabel(draft.fileExtension))")
                .font(Theme.body(11))
            VStack(alignment: .leading, spacing: 4) {
                Text("추천 위치 · \(review.project(draft.projectID)?.name ?? "프로젝트")")
                    .font(Theme.body(11))
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                PathText(path: destinationPath(root: draft.projectRootPath, folder: draft.folder))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
    }

    private var matchedFiles: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("이번 묶음에서 일치하는 파일 · \(matchingNames.count)개")
                .font(Theme.body(12))
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            if matchingNames.isEmpty {
                Text("일치하는 파일이 없습니다. 파일명 시작 글자를 확인하세요.")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.gray)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(matchingNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(Theme.body(11))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityIdentifier("review-rule-matches")
    }
}

private func extensionLabel(_ value: String) -> String {
    value.isEmpty ? "확장자 없음" : ".\(value)"
}

private func destinationPath(root: String, folder: String) -> String {
    folder.isEmpty ? root : URL(fileURLWithPath: root).appendingPathComponent(folder).path
}
