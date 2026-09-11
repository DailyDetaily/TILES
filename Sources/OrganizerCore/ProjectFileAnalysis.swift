import Foundation
import Darwin
import PDFKit
import Vision
import ImageIO
import CoreGraphics

public enum ProjectFileKind: String, Sendable, Codable, CaseIterable {
    case document, image, video, audio, archive, code, other
    public var label: String {
        switch self {
        case .document: return "문서"
        case .image: return "이미지"
        case .video: return "영상"
        case .audio: return "음원"
        case .archive: return "압축"
        case .code: return "코드"
        case .other: return "기타"
        }
    }
    public static func detect(_ url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "pdf", "txt", "md", "markdown", "csv", "tsv", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "hwp", "hwpx": return .document
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "svg", "avif": return .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return .video
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg": return .audio
        case "zip", "tar", "gz", "7z", "rar", "bz2", "xz": return .archive
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "m", "mm", "css", "html", "json", "yaml", "yml", "toml", "xml", "sh": return .code
        default: return .other
        }
    }
}

public enum FileEvidenceIssueSeverity: String, Sendable, Codable { case none, notice, warning, error }

public enum FileContentReadStatus: String, Sendable, Codable {
    case metadataOnly, textRead, pdfTextRead, ocrRead, partialRead
    case empty, unsupported, decodingFailed, readFailed, ocrDisabled, limitExceeded, cancelled, invalidFile
    public var label: String {
        switch self {
        case .metadataOnly: return "이름·종류만 확인"
        case .textRead: return "로컬 텍스트 읽음"
        case .pdfTextRead: return "PDF 텍스트 읽음"
        case .ocrRead: return "기기에서 OCR 읽음"
        case .partialRead: return "일부 내용만 읽음"
        case .empty: return "읽을 수 있는 텍스트 없음"
        case .unsupported: return "내용 읽기 미지원"
        case .decodingFailed: return "문자 인코딩을 읽을 수 없음"
        case .readFailed: return "내용 읽기 실패"
        case .ocrDisabled: return "OCR 꺼짐"
        case .limitExceeded: return "분석 한도 초과"
        case .cancelled: return "분석 취소"
        case .invalidFile: return "파일 확인 실패"
        }
    }
    public var severity: FileEvidenceIssueSeverity {
        switch self {
        case .textRead, .pdfTextRead, .ocrRead: return .none
        case .metadataOnly, .empty, .unsupported, .ocrDisabled, .cancelled: return .notice
        case .partialRead, .limitExceeded: return .warning
        case .decodingFailed, .readFailed, .invalidFile: return .error
        }
    }
}

public enum FileEvidenceSource: String, Sendable, Codable {
    case filename, localText, pdfText, imageOCR, pdfOCR
    public var label: String {
        switch self {
        case .filename: return "파일명"
        case .localText: return "로컬 텍스트"
        case .pdfText: return "PDF 텍스트"
        case .imageOCR: return "이미지 OCR"
        case .pdfOCR: return "PDF OCR"
        }
    }
}

public enum ProjectMatchState: String, Sendable, Codable {
    case unique, ambiguous, unknown
    public var label: String {
        switch self {
        case .unique: return "프로젝트 후보 1개"
        case .ambiguous: return "여러 프로젝트 후보"
        case .unknown: return "프로젝트 단서 없음"
        }
    }
}

public struct ProjectCandidate: Sendable, Codable, Equatable, Identifiable {
    public var projectID: UUID
    public var projectName: String
    public var reasons: [String]
    public var sources: [FileEvidenceSource]
    public var id: UUID { projectID }
}

public enum ProjectDocumentCue: String, Sendable, Codable, CaseIterable {
    case contract, estimate, invoice, receipt
    public var label: String {
        switch self {
        case .contract: return "계약서"
        case .estimate: return "견적서"
        case .invoice: return "청구서"
        case .receipt: return "영수증"
        }
    }
    fileprivate var tokens: [String] {
        switch self {
        case .contract: return ["계약서", "계약", "contract", "agreement"]
        case .estimate: return ["견적서", "견적", "quotation", "estimate"]
        case .invoice: return ["청구서", "인보이스", "invoice"]
        case .receipt: return ["영수증", "receipt"]
        }
    }
}

public struct ProjectFileVersion: Sendable, Codable, Equatable {
    public var identity: FileIdentity
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public static func capture(_ url: URL) throws -> Self {
        let identity = try ExistingFileDrop.inspect(url)
        let info = try SafeFileSystem.info(url)
        guard SafeFileSystem.identity(info) == identity else { throw OrganizerError("확인 중 원본 파일이 바뀌었습니다.") }
        return .init(identity: identity, size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                     modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}

public struct FileEvidence: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var sourcePath: String
    public var sourceIdentity: FileIdentity?
    public var sourceVersion: ProjectFileVersion?
    public var kind: ProjectFileKind
    public var readStatus: FileContentReadStatus
    public var reasons: [String]
    public var projectCandidates: [ProjectCandidate]
    public var documentCues: [ProjectDocumentCue]
    public var modifiedAt: Date?
    /// A short observed excerpt for review, never a generated summary or a claim of understanding.
    public var observedTextExcerpt: String?
    public var projectMatch: ProjectMatchState {
        projectCandidates.isEmpty ? .unknown : (projectCandidates.count == 1 ? .unique : .ambiguous)
    }
    public var issueSeverity: FileEvidenceIssueSeverity { readStatus.severity }
    public var name: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
    public func matchesCurrentSource() throws -> Bool {
        guard let sourceVersion else { return false }
        return try ProjectFileVersion.capture(URL(fileURLWithPath: sourcePath)) == sourceVersion
    }

    /// The caller still chooses the project and reviews each proposed destination.
    public func suggestedFolder(for project: ProjectDefinition) -> String? {
        guard sourceIdentity != nil, readStatus != .cancelled, readStatus != .invalidFile else { return nil }
        let candidate: String?
        switch project.template {
        case .simple, .workflow: candidate = nil // File format cannot establish draft/final/reference role.
        case .byKind: candidate = kind.label
        case .byDocument:
            if documentCues.count > 1 { candidate = nil }
            else if let cue = documentCues.first { candidate = cue.label }
            else { candidate = kind == .document ? "일반 문서" : (kind == .image ? "이미지" : "기타") }
        case .byMonth:
            guard let modifiedAt else { return nil }
            let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: modifiedAt)
            guard let year = components.year, let month = components.month else { return nil }
            return String(format: "%04d-%02d", year, month)
        }
        guard let candidate else { return nil }
        return project.folders.contains(candidate) ? candidate : nil
    }
}

/// CPU and file work always runs on a utility queue. No network or external AI is used.
public enum ProjectFileAnalyzer {
    public static let maximumFiles = 500
    public static let maximumContentFiles = 100
    public static let maximumFileBytes = 16 * 1_024 * 1_024
    public static let maximumTextBytes = 2 * 1_024 * 1_024
    public static let maximumPDFPages = 5
    public static let maximumTextCharacters = 24_000
    public static let maximumFileSeconds: TimeInterval = 20
    public static let maximumBatchSeconds: TimeInterval = 120

    public static func analyze(urls: [URL], projects: [ProjectDefinition], contentEnabled: Bool = true,
                               cancelled: @escaping () -> Bool = { false },
                               progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> [FileEvidence] {
        let token = AnalysisCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let batchDeadline = Date().addingTimeInterval(maximumBatchSeconds)
                    let stop = { token.isCancelled || cancelled() }
                    let validProjects = projects.filter { (try? $0.validate()) != nil }
                    var results: [FileEvidence] = []
                    for (index, url) in urls.enumerated() {
                        var evidence = blank(url)
                        if stop() { evidence.readStatus = .cancelled; evidence.reasons = ["사용자가 분석을 취소했습니다."] }
                        else if index >= maximumFiles {
                            evidence.readStatus = .limitExceeded; evidence.reasons = ["한 번에 500개의 파일 확인 한도를 넘었습니다."]
                        } else {
                            let contentLimit = contentEnabled && (index >= maximumContentFiles || Date() >= batchDeadline)
                            evidence = analyzeOne(url, projects: validProjects, contentEnabled: contentEnabled,
                                                  contentLimitReason: contentLimit ? "내용 읽기는 앞 100개·전체 120초까지 지원하여 이 파일은 이름·종류만 확인했습니다." : nil,
                                                  deadline: min(batchDeadline, Date().addingTimeInterval(maximumFileSeconds)), cancelled: stop)
                        }
                        results.append(evidence)
                        progress(index + 1, urls.count)
                    }
                    continuation.resume(returning: results)
                }
            }
        }, onCancel: { token.cancel() })
    }

    private static func blank(_ url: URL) -> FileEvidence {
        .init(id: UUID(), sourcePath: url.path, sourceIdentity: nil, sourceVersion: nil, kind: .detect(url), readStatus: .metadataOnly,
              reasons: [], projectCandidates: [], documentCues: [], modifiedAt: nil, observedTextExcerpt: nil)
    }

    private static func analyzeOne(_ url: URL, projects: [ProjectDefinition], contentEnabled: Bool,
                                   contentLimitReason: String?, deadline: Date, cancelled: @escaping () -> Bool) -> FileEvidence {
        var evidence = blank(url)
        do {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil else { throw OrganizerError("이 Mac에 있는 일반 파일만 분석합니다.") }
            let version = try ProjectFileVersion.capture(url)
            evidence.sourceVersion = version; evidence.sourceIdentity = version.identity
            evidence.modifiedAt = Date(timeIntervalSince1970: TimeInterval(version.modifiedSeconds))
            evidence.reasons = ["확장자 기준 종류: \(evidence.kind.label)"]
        } catch {
            evidence.readStatus = .invalidFile
            evidence.reasons = [error.localizedDescription]
            return evidence
        }
        var observations: [(FileEvidenceSource, String)] = [(.filename, url.deletingPathExtension().lastPathComponent)]
        if let contentLimitReason {
            evidence.readStatus = .limitExceeded; evidence.reasons.append(contentLimitReason)
        } else if contentEnabled {
            do {
                let extracted = try readContent(url, identity: evidence.sourceIdentity!, deadline: deadline, cancelled: cancelled)
                evidence.readStatus = extracted.status
                evidence.reasons.append(contentsOf: extracted.reasons)
                observations.append(contentsOf: extracted.observations)
                let joined = extracted.observations.map(\.1).joined(separator: " ")
                if !joined.isEmpty { evidence.observedTextExcerpt = String(joined.prefix(320)) }
            } catch let stop as AnalysisStop {
                evidence.readStatus = stop.status; evidence.reasons.append(stop.message)
            } catch {
                evidence.readStatus = .readFailed; evidence.reasons.append("내용 읽기에 실패했습니다: \(error.localizedDescription)")
            }
        } else {
            evidence.readStatus = evidence.kind == .image ? .ocrDisabled : .metadataOnly
            evidence.reasons.append("내용 읽기가 꺼져 있어 파일명과 확장자만 확인했습니다.")
        }
        do {
            guard try ProjectFileVersion.capture(url) == evidence.sourceVersion else { throw OrganizerError("분석 중 원본 파일의 내용이나 수정일이 바뀌었습니다.") }
        } catch {
            evidence.sourceIdentity = nil; evidence.sourceVersion = nil; evidence.readStatus = .invalidFile
            evidence.reasons.append(error.localizedDescription); evidence.observedTextExcerpt = nil
            return evidence
        }
        if evidence.readStatus == .cancelled { return evidence }
        evidence.projectCandidates = candidates(observations, projects: projects)
        for cue in ProjectDocumentCue.allCases {
            if let observation = observations.first(where: { observation in cue.tokens.contains { containsToken($0, in: observation.1) } }) {
                evidence.documentCues.append(cue)
                evidence.reasons.append("\(observation.0.label)에서 ‘\(cue.label)’ 유형 단서를 찾았습니다.")
            }
        }
        if evidence.projectCandidates.isEmpty { evidence.reasons.append("등록한 프로젝트 이름·별칭과 일치하는 단서가 없습니다.") }
        else if evidence.projectCandidates.count > 1 { evidence.reasons.append("여러 프로젝트가 언급되어 소속을 고를 수 없습니다.") }
        else { evidence.reasons.append("이름 일치는 후보 근거입니다. 실제 프로젝트 소속을 확인해 주세요.") }
        return evidence
    }

    private static func candidates(_ observations: [(FileEvidenceSource, String)], projects: [ProjectDefinition]) -> [ProjectCandidate] {
        var seen = Set<UUID>()
        return projects.compactMap { project in
            guard seen.insert(project.id).inserted else { return nil }
            var reasons: [String] = [], sources: [FileEvidenceSource] = []
            for (source, text) in observations {
                let matches = ([project.name] + project.aliases).filter { containsToken($0, in: text) }
                if !matches.isEmpty {
                    sources.append(source)
                    reasons.append("\(source.label): ‘\(matches.prefix(3).joined(separator: "’, ‘"))’ 일치")
                }
            }
            return reasons.isEmpty ? nil : ProjectCandidate(projectID: project.id, projectName: project.name, reasons: reasons, sources: sources)
        }
    }

    /// Unicode letter/number boundaries keep a short name such as O out of logo or document.
    static func containsToken(_ token: String, in text: String) -> Bool {
        let canonical = token.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return false }
        let pieces = canonical.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?<![\\p{L}\\p{N}])" + pieces.joined(separator: "[\\s_-]+") + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let text = text.precomposedStringWithCanonicalMapping
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private struct Extraction {
        var status: FileContentReadStatus
        var observations: [(FileEvidenceSource, String)] = []
        var reasons: [String] = []
    }
    private struct AnalysisStop: Error {
        var status: FileContentReadStatus
        var message: String
    }
    private static func check(_ deadline: Date, _ cancelled: () -> Bool) throws {
        if cancelled() { throw AnalysisStop(status: .cancelled, message: "사용자가 분석을 취소했습니다.") }
        if Date() >= deadline { throw AnalysisStop(status: .limitExceeded, message: "파일 분석 시간 한도를 넘었습니다.") }
    }

    private static func readContent(_ url: URL, identity: FileIdentity, deadline: Date,
                                    cancelled: @escaping () -> Bool) throws -> Extraction {
        try check(deadline, cancelled)
        let ext = url.pathExtension.lowercased()
        let textTypes: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "m", "mm", "css", "html", "sh"]
        let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "avif"]
        guard ext == "pdf" || textTypes.contains(ext) || imageTypes.contains(ext) else {
            return Extraction(status: .unsupported, reasons: ["이 형식의 내용은 읽지 않았습니다. 파일명·확장자만 근거로 사용합니다."])
        }
        let data = try readBytes(url, identity: identity, maximum: textTypes.contains(ext) ? maximumTextBytes : maximumFileBytes,
                                 deadline: deadline, cancelled: cancelled)
        guard !data.isEmpty else { return Extraction(status: .empty, reasons: ["파일이 비어 있습니다."]) }
        if textTypes.contains(ext) {
            let encoding: String.Encoding
            if data.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian }
            else if data.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian }
            else { encoding = .utf8 }
            guard let text = String(data: data, encoding: encoding), !text.contains("\0") else {
                throw AnalysisStop(status: .decodingFailed, message: "UTF-8 또는 BOM이 있는 UTF-16 텍스트로 읽을 수 없습니다.")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return Extraction(status: .empty, reasons: ["텍스트에 읽을 내용이 없습니다."]) }
            let partial = trimmed.count > maximumTextCharacters
            return Extraction(status: partial ? .partialRead : .textRead,
                              observations: [(.localText, String(trimmed.prefix(maximumTextCharacters)))],
                              reasons: [partial ? "로컬 텍스트 앞 24,000자만 읽었습니다." : "로컬 텍스트를 읽었습니다."])
        }
        if ext == "pdf" { return try readPDF(data, deadline: deadline, cancelled: cancelled) }
        return try readImage(data, deadline: deadline, cancelled: cancelled)
    }

    /// Read through no-follow directory descriptors, verify the original identity and bound allocation.
    private static func readBytes(_ url: URL, identity: FileIdentity, maximum: Int, deadline: Date,
                                  cancelled: () -> Bool) throws -> Data {
        try SafeFileSystem.withDirectoryFD(url.deletingLastPathComponent()) { parent in
            let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw SafeFileSystem.systemError("파일을 읽을 수 없습니다", url.path) }
            defer { close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0, SafeFileSystem.identity(before) == identity else {
                throw OrganizerError("읽기 전에 원본 파일이 바뀌었습니다.")
            }
            guard before.st_size >= 0, before.st_size <= maximum else {
                throw AnalysisStop(status: .limitExceeded, message: "내용 읽기 크기 한도(텍스트 2MB, PDF·이미지 16MB)를 넘었습니다.")
            }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            data.reserveCapacity(Int(before.st_size))
            while true {
                try check(deadline, cancelled)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw SafeFileSystem.systemError("파일을 읽을 수 없습니다", url.path) }
                if count == 0 { break }
                guard data.count + count <= maximum else { throw AnalysisStop(status: .limitExceeded, message: "내용 읽기 크기 한도를 넘었습니다.") }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, SafeFileSystem.identity(after) == identity,
                  before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
                throw OrganizerError("내용을 읽는 동안 원본 파일이 바뀌었습니다.")
            }
            return data
        }
    }

    private static func readPDF(_ data: Data, deadline: Date, cancelled: @escaping () -> Bool) throws -> Extraction {
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw AnalysisStop(status: .readFailed, message: "PDF를 열 수 없거나 암호로 잠겨 있습니다.")
        }
        var textParts: [String] = [], ocrParts: [String] = [], totalCharacters = 0, partial = document.pageCount > maximumPDFPages
        for index in 0..<min(document.pageCount, maximumPDFPages) {
            try check(deadline, cancelled)
            guard let page = document.page(at: index) else { partial = true; continue }
            let rawText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text: String
            if rawText.isEmpty {
                let image = try rasterize(page)
                text = try recognize(image, deadline: deadline, cancelled: cancelled)
                ocrParts.append(String(text.prefix(maximumTextCharacters - totalCharacters)))
            } else {
                text = rawText
                textParts.append(String(text.prefix(maximumTextCharacters - totalCharacters)))
            }
            totalCharacters += min(text.count, maximumTextCharacters - totalCharacters)
            if totalCharacters >= maximumTextCharacters { partial = true; break }
        }
        let text = textParts.joined(separator: "\n"), ocr = ocrParts.joined(separator: "\n")
        guard !text.isEmpty || !ocr.isEmpty else {
            return Extraction(status: partial ? .partialRead : .empty, reasons: ["확인한 PDF 페이지에서 텍스트를 찾지 못했습니다. OCR 결과는 원본과 다를 수 있습니다."])
        }
        var observations: [(FileEvidenceSource, String)] = []
        if !text.isEmpty { observations.append((.pdfText, text)) }
        if !ocr.isEmpty { observations.append((.pdfOCR, ocr)) }
        var reasons = ["PDF 앞 \(min(document.pageCount, maximumPDFPages))페이지를 확인했습니다."]
        if !ocr.isEmpty { reasons.append("텍스트가 없는 페이지는 기기에서 OCR을 실행했습니다. 인식 오류가 있을 수 있습니다.") }
        if partial { reasons.append("PDF 전체가 아닌 최대 5페이지·24,000자 범위만 확인했습니다.") }
        return Extraction(status: partial ? .partialRead : (ocr.isEmpty ? .pdfTextRead : .ocrRead), observations: observations, reasons: reasons)
    }

    private static func readImage(_ data: Data, deadline: Date, cancelled: @escaping () -> Bool) throws -> Extraction {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw AnalysisStop(status: .readFailed, message: "지원하는 이미지로 열 수 없습니다.")
        }
        guard width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 12_000, height.doubleValue <= 12_000,
              width.doubleValue * height.doubleValue <= 40_000_000 else {
            throw AnalysisStop(status: .limitExceeded, message: "이미지 크기 한도(한 변 12,000px, 4천만 화소)를 넘었습니다.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 2_200,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AnalysisStop(status: .readFailed, message: "OCR용 이미지를 만들 수 없습니다.")
        }
        let text = try recognize(image, deadline: deadline, cancelled: cancelled)
        let partial = CGImageSourceGetCount(source) > 1 || text.count > maximumTextCharacters
        return Extraction(status: text.isEmpty ? .empty : (partial ? .partialRead : .ocrRead),
                          observations: text.isEmpty ? [] : [(.imageOCR, String(text.prefix(maximumTextCharacters)))],
                          reasons: ["이미지 첫 프레임을 최대 2,200px로 읽어 기기에서 OCR을 실행했습니다. 인식 오류가 있을 수 있습니다."] +
                            (partial ? ["여러 프레임 또는 긴 텍스트 중 일부만 확인했습니다."] : []))
    }

    private static func rasterize(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              bounds.width <= 20_000, bounds.height <= 20_000 else {
            throw AnalysisStop(status: .limitExceeded, message: "PDF 페이지 크기가 OCR 한도를 넘었습니다.")
        }
        let scale = min(2, 1_600 / max(bounds.width, bounds.height))
        let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AnalysisStop(status: .readFailed, message: "PDF OCR용 이미지를 만들 수 없습니다.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw AnalysisStop(status: .readFailed, message: "PDF 이미지를 읽을 수 없습니다.") }
        return image
    }

    private static func recognize(_ image: CGImage, deadline: Date, cancelled: @escaping () -> Bool) throws -> String {
        try check(deadline, cancelled)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ko-KR", "en-US"].filter { supported.contains($0) }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { if cancelled() || Date() >= deadline { request.cancel() } }
        timer.resume()
        defer { timer.cancel() }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { try check(deadline, cancelled); throw error }
        try check(deadline, cancelled)
        return (request.results ?? []).prefix(2_000).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

private final class AnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
