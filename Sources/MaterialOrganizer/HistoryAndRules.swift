import AppKit
import SwiftUI
import OrganizerCore

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.records.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("정리 기록이 없습니다").font(Theme.body(18)).fontWeight(.medium)
                    Text("파일 이동과 폴더 만들기 기록을 여기에서 확인하고 되돌릴 수 있습니다.").font(Theme.body(13)).foregroundStyle(Theme.gray)
                    Button("파일 선택…", action: model.chooseFile).buttonStyle(PillStyle())
                }.padding(.top, 22)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.records) { run in HistoryCard(model: model, run: run) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
private struct HistoryCard: View {
    @ObservedObject var model: AppModel
    var run: RunRecord
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.createdAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.body(15))
                    Text(summary).font(Theme.body(12)).foregroundStyle(Theme.gray)
                }
                Spacer()
                Button("상태 확인") { model.handleRecord(run, undo: false) }.buttonStyle(PillStyle(filled: false)).disabled(model.busy)
                Button("되돌리기") { model.confirmUndo = run }.buttonStyle(PillStyle()).disabled(model.busy || !run.canUndo)
            }
            if let note = run.message { Text(note).font(Theme.body(12)).foregroundStyle(Theme.gray) }
            DisclosureGroup(run.entries.isEmpty ? "만든 폴더 위치" : "이전 위치와 새 위치", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(run.createdDirectories, id: \.path) { directory in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: run.state == .undone ? "arrow.uturn.backward" : "folder.badge.plus").frame(width: 16)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(URL(fileURLWithPath: directory.path).lastPathComponent).font(Theme.body(13))
                                PathText(path: directory.path)
                                Text(run.state == .undone ? "되돌린 폴더 생성 기록" : "이 작업에서 만든 폴더")
                                    .font(Theme.body(11)).foregroundStyle(Theme.gray)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Finder") { model.showInFinder(directory.path) }
                                .buttonStyle(.plain).font(Theme.body(11)).disabled(run.state == .undone)
                        }
                    }
                    ForEach(run.entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: entry.state == .undone ? "arrow.uturn.backward" : entry.state == .moved ? "checkmark" : "ellipsis").frame(width: 16)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(URL(fileURLWithPath: entry.source).lastPathComponent).font(Theme.body(13))
                                PathText(path: entry.source)
                                PathText(path: entry.destination)
                                if let note = entry.note { Text(note).font(Theme.body(11)) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Finder") { model.showInFinder(entry.state == .undone || entry.state == .pending ? entry.source : entry.destination) }.buttonStyle(.plain).font(Theme.body(11))
                        }
                    }
                }.padding(.top, 12)
            }.font(Theme.body(12))
        }.padding(20).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
    }
    private var summary: String {
        let folders = run.createdDirectories.count
        if run.entries.isEmpty { return (folders > 0 ? "폴더 \(folders)개 생성" : "폴더 만들기") + " · \(run.state.label)" }
        return "파일 \(run.entries.count)개" + (folders > 0 ? " · 폴더 \(folders)개 생성" : "") + " · \(run.state.label)"
    }
}

struct RulesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: ProjectReviewModel
    @ObservedObject var watch: FolderWatchService
    @State private var presentsProjectSetup = false
    @State private var setupProject: ProjectDefinition?
    @State private var draft = OrganizerRules.standard()
    @State private var newName = ""
    @State private var newPrefixes = ""
    @State private var prefixText: [UUID: String] = [:]
    @State private var referenceText = ""
    @State private var personalText = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                WatchSettingsView(watch: watch, review: review)
                Hairline().opacity(0.45)
                projectSettings
                Hairline().opacity(0.45)
                VStack(alignment: .leading, spacing: 13) {
                    Text("추천 규칙").font(Theme.body(15)).fontWeight(.medium)
                    if model.folderSuggestionRules.isEmpty {
                        Text("파일을 옮길 때 ‘다음에도 이 폴더 추천’을 선택하면 추가됩니다.")
                            .font(Theme.body(12)).foregroundStyle(Theme.gray)
                    }
                    ForEach(model.folderSuggestionRules) { rule in
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("이름이 ‘\(rule.prefix)’로 시작").font(Theme.body(13))
                                PathText(path: rule.folderPath)
                            }
                            Spacer()
                            Button { model.removeSuggestionRule(rule.id) } label: { Image(systemName: "minus").padding(8) }
                                .buttonStyle(.plain).accessibilityLabel("\(rule.prefix) 추천 규칙 제거").disabled(model.busy)
                        }.padding(14).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Hairline().opacity(0.45)
                VStack(alignment: .leading, spacing: 13) {
                    Toggle("화면 가장자리에서 빠르게 정리", isOn: Binding(get: { model.folderOverlayEnabled }, set: model.setFolderOverlayEnabled))
                        .font(Theme.body(15)).toggleStyle(.switch).tint(Theme.blue)
                        .accessibilityLabel("화면 가장자리에서 빠르게 정리")
                    Text("파일을 끌어와 ‘정리 추천’에서 검토하거나, 기존 폴더로 바로 이동할 수 있습니다.").font(Theme.body(12)).foregroundStyle(Theme.gray)
                    if model.folderOverlayEnabled {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.overlayDestinationConnected ? model.destination.lastPathComponent : "추천할 폴더를 선택하세요").font(Theme.body(13))
                                if model.overlayDestinationConnected { PathText(path: model.destination.path) }
                            }
                            Spacer()
                            Button(model.overlayDestinationConnected ? "폴더 변경…" : "폴더 선택…", action: model.chooseDestination).buttonStyle(PillStyle(filled: false)).disabled(model.busy)
                        }.padding(14).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
                        HStack(spacing: 12) {
                            Button(model.folderDockEditing ? "편집 완료" : "위치·크기 편집…") { model.setFolderDockEditing(!model.folderDockEditing) }
                                .buttonStyle(PillStyle(filled: false)).disabled(model.busy)
                            if model.folderDockEditing {
                                Button("기본 위치·크기") { model.setFolderDockLayout(.init()) }.buttonStyle(PillStyle(filled: false))
                            }
                        }
                        if model.folderDockEditing {
                            Text("빈 곳을 끌어 이동하고, 모서리로 크기를 조절하세요.").font(Theme.body(12)).foregroundStyle(Theme.gray)
                        }
                    }
                }
                Hairline().opacity(0.45)
                DisclosureGroup("폴더 전체 정리 규칙") {
                    VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("프로젝트 이름 규칙").font(Theme.body(14)).fontWeight(.medium)
                        HStack { Text("모을 폴더").frame(width: 115, alignment: .leading); Text("파일·폴더 이름의 시작 부분 / 쉼표로 구분") }.font(Theme.body(11)).foregroundStyle(Theme.gray)
                        ForEach($draft.projects) { $project in
                            HStack {
                                field("프로젝트", text: $project.name).frame(width: 115)
                                field("이름 규칙", text: Binding(get: { prefixText[project.id, default: ""] }, set: { prefixText[project.id] = $0 }))
                                Button { draft.projects.removeAll { $0.id == project.id } } label: { Image(systemName: "minus").padding(8) }.buttonStyle(.plain).accessibilityLabel("\(project.name) 규칙 제거")
                            }
                        }
                        HStack {
                            field("새 프로젝트", text: $newName).frame(width: 115)
                            field("예: My Project, MyProject", text: $newPrefixes)
                            Button("추가") {
                                let name = newName.trimmingCharacters(in: .whitespaces)
                                let project = ProjectRule(name: name, prefixes: split(newPrefixes)); draft.projects.append(project); prefixText[project.id] = newPrefixes; newName = ""; newPrefixes = ""
                            }.buttonStyle(PillStyle(filled: false)).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || split(newPrefixes).isEmpty)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("공통 자료").font(Theme.body(14)).fontWeight(.medium)
                        HStack { Text("참고").frame(width: 115, alignment: .leading); field("참고 이름", text: $referenceText) }
                        HStack { Text("개인").frame(width: 115, alignment: .leading); field("개인 이름", text: $personalText) }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("이동하지 않을 폴더").font(Theme.body(14)).fontWeight(.medium)
                            Spacer()
                            Button("폴더 추가") { model.addProtectedFolder(); draft.protectedPaths = model.rules.protectedPaths }.buttonStyle(PillStyle(filled: false))
                        }
                        ForEach(draft.protectedPaths, id: \.self) { path in
                            HStack { PathText(path: path); Spacer(); Button { draft.protectedPaths.removeAll { $0 == path } } label: { Image(systemName: "minus").padding(6) }.buttonStyle(.plain).accessibilityLabel("\(path) 보호 경로 제거") }
                        }
                        Text("코드 프로젝트·앱 묶음·원본 영상·음성·편집 파일·인증 자료·바로가기는 자동 보호합니다. 폴더 안에 보호 자료가 있어도 이동하지 않습니다.").font(Theme.body(12)).foregroundStyle(Theme.gray).lineSpacing(4)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("폴더 이름 변경 예시").font(Theme.body(14)).fontWeight(.medium)
                        Text("TasteBuddy-2026-09-08-리서치 → Taste Buddy / 2026-09-08 리서치\n폴더 이름의 프로젝트 접두어를 덜고 날짜를 앞으로 옮깁니다. 파일 이름은 그대로 둡니다.").font(Theme.body(13)).lineSpacing(5)
                    }

                        HStack {
                            Text("폴더 전체 정리의 이름 분류에 적용됩니다.").font(Theme.body(12)).foregroundStyle(Theme.gray)
                            Spacer()
                            Button("규칙 저장") {
                                for index in draft.projects.indices { draft.projects[index].prefixes = split(prefixText[draft.projects[index].id, default: ""]) }
                                draft.referencePrefixes = split(referenceText); draft.personalPrefixes = split(personalText)
                                model.saveRules(draft)
                            }.buttonStyle(PillStyle()).disabled(model.busy)
                        }
                    }.padding(.top, 20)
                }.font(Theme.body(14))
                DisclosureGroup("원본 폴더 접근 권한") {
                    HStack {
                        Text("파일 접근에 실패했을 때 해당 파일이 들어 있는 폴더를 연결하세요.")
                            .font(Theme.body(12)).foregroundStyle(Theme.gray)
                        Spacer()
                        Button("폴더 연결…", action: model.addFolders).buttonStyle(PillStyle(filled: false)).disabled(model.busy)
                    }.padding(.top, 12)
                }.font(Theme.body(14))
            }.padding(.trailing, 4).padding(.bottom, 16)
        }
        .sheet(isPresented: $presentsProjectSetup, onDismiss: {
            review.showProjectSetup = false; review.editingProject = nil; setupProject = nil
        }) { ProjectSetupView(review: review, project: setupProject) }
        .onChange(of: review.showProjectSetup) { _, requested in routeProjectSetup(requested) }
        .onAppear {
            routeProjectSetup(review.showProjectSetup)
            draft = model.rules
            prefixText = Dictionary(uniqueKeysWithValues: draft.projects.map { ($0.id, $0.prefixes.joined(separator: ", ")) })
            referenceText = draft.referencePrefixes.joined(separator: ", "); personalText = draft.personalPrefixes.joined(separator: ", ")
        }
    }
    private var projectSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("프로젝트").font(Theme.body(15)).fontWeight(.medium)
                Spacer()
                Button("프로젝트 만들기", action: review.newProject).buttonStyle(PillStyle(filled: false))
                    .disabled(model.busy || !review.storeReadable).accessibilityIdentifier("settings-new-project")
            }
            if review.projects.isEmpty {
                Text("프로젝트와 폴더 구조를 저장하면 다음 파일 정리에도 사용할 수 있습니다.")
                    .font(Theme.body(12)).foregroundStyle(Theme.gray)
            }
            ForEach(review.projects) { project in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.name).font(Theme.body(13)).fontWeight(.medium)
                            PathText(path: project.rootPath)
                            Text("폴더 구조 \(project.folders.count)개").font(Theme.body(12)).foregroundStyle(Theme.gray)
                        }
                        Spacer(minLength: 8)
                        Button("구조 편집") { review.editProject(project) }.buttonStyle(PillStyle(filled: false))
                            .disabled(model.busy).accessibilityLabel("\(project.name) 구조 편집")
                        Button("폴더 만들기") { review.prepare(folderOnly: project.id) }.buttonStyle(PillStyle(filled: false))
                            .disabled(model.busy).accessibilityLabel("\(project.name) 폴더 만들기 미리보기")
                    }
                    if !project.aliases.isEmpty {
                        Text("함께 찾을 이름 · " + project.aliases.joined(separator: ", "))
                            .font(Theme.body(12)).foregroundStyle(Theme.gray).lineLimit(2)
                    }
                }.padding(14).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
            }
        }.accessibilityIdentifier("settings-projects")
    }
    private func routeProjectSetup(_ requested: Bool) {
        guard requested else { presentsProjectSetup = false; return }
        if NSApp.keyWindow?.title == "TILES" { setupProject = review.editingProject; presentsProjectSetup = true }
    }
    private func split(_ text: String) -> [String] { text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(Theme.body(13)).padding(10).background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
    }
}
