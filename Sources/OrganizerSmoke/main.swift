import Foundation
import OrganizerCore

let args = CommandLine.arguments
let demoOnly = args.contains("--fixture")
let root = try PathSafety.resolveExistingPrefix(FileManager.default.temporaryDirectory).appendingPathComponent("MaterialOrganizer-Demo-" + UUID().uuidString)
let source = root.appendingPathComponent("받은 자료")
let target = root.appendingPathComponent("자료")
let fm = FileManager.default
try fm.createDirectory(at: source, withIntermediateDirectories: true)
func make(_ name: String, _ value: String) throws {
    let url = source.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
}
try make("TasteBuddy-리서치-2026-09-08/인터뷰.md", "임시 검증용 인터뷰 자료입니다.")
try make("Setly-모션-2026-09-09/메모.txt", "임시 검증용 모션 메모입니다.")
try make("Withings-참고.png", "Temporary test fixture; not a real image")
try make("이름없는 노트.txt", "분류를 직접 골라 주세요.")
try make("Setly-개발 프로젝트/Package.swift", "// Protected project fixture")
try make("원본 녹음.wav", "Protected recording fixture")
try make(".숨김 자료", "Protected hidden fixture")
if demoOnly {
    print(root.path)
} else {
    let rules = OrganizerRules.standard(home: root)
    let plan = try Planner.analyze(sources: [source], destination: target, rules: rules)
    let ids = Set(plan.proposals.filter { $0.decision.executable }.map(\.id))
    guard ids.count == 3 else { throw OrganizerError("Unexpected fixture proposals: \(ids.count)") }
    let organizer = Organizer(store: try JournalStore(directory: root.appendingPathComponent("History")))
    let run = try organizer.execute(plan: plan, selectedIDs: ids)
    guard run.state == .completed else { throw OrganizerError(run.message ?? "Execution failed") }
    let reopened = Organizer(store: try JournalStore(directory: root.appendingPathComponent("History")))
    let undone = try reopened.undo(run.id)
    guard undone.state == .undone else { throw OrganizerError(undone.message ?? "Undo failed") }
    for entry in run.entries {
        guard try SafeFileSystem.snapshot(URL(fileURLWithPath: entry.source), rules: rules) == entry.snapshot else { throw OrganizerError("Restored content differs") }
    }
    let result: [String: Any] = ["result": "PASS", "proposals": plan.proposals.count, "moved": run.movedCount, "restored": run.entries.count, "fixture": root.path, "realUserFilesTouched": false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}
