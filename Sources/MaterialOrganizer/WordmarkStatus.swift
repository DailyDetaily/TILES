import OrganizerCore

enum TileWordmarkCue: String, CaseIterable {
    case tile = "TILES", hello = "HELLO", wait = "WAIT", ready = "READY"
    case done = "DONE!", check = "CHECK", stop = "STOP"

    var returnDelay: Double? {
        switch self {
        case .hello: return 1.8
        case .done, .stop: return 3
        default: return nil
        }
    }

    var explanation: String {
        switch self {
        case .tile, .hello: return "반가워요. 자료에 맞는 자리를 찾아볼까요?"
        case .wait: return "작업 중이에요. 잠시 기다려 주세요."
        case .ready: return "미리보기가 준비됐어요. 항목을 확인해 주세요."
        case .done: return "작업을 마쳤어요."
        case .check: return "확인이 필요해요. 아래 안내를 살펴봐 주세요."
        case .stop: return "작업을 중단했어요."
        }
    }

    static func completion(for state: RunState) -> Self {
        // Partial, interrupted, or unresolved runs must never celebrate DONE.
        state == .completed || state == .undone ? .done : .check
    }

    static func completion(for result: Result<RunRecord, Error>) -> Self {
        switch result {
        case .success(let record): return completion(for: record.state)
        case .failure(is CancellationError): return .stop
        case .failure: return .check
        }
    }
}
