import Foundation
import Darwin

public struct ProjectRule: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var prefixes: [String]
    public init(name: String, prefixes: [String]) {
        id = UUID(); self.name = name; self.prefixes = prefixes
    }
}

public struct OrganizerRules: Sendable, Codable, Equatable {
    public var version = 1
    public var projects: [ProjectRule]
    public var protectedPaths: [String]
    public var referencePrefixes: [String]
    public var personalPrefixes: [String]
    public var maximumSnapshotBytes: Int64 = 256 * 1_024 * 1_024
    public var maximumSnapshotEntries: Int = 10_000
    public var maximumReferenceFiles: Int = 5_000
    public var maximumReferenceBytes: Int64 = 64 * 1_024 * 1_024

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> OrganizerRules {
        let protected = ["Desktop/Setly", "Desktop/Taste Buddy app", "Desktop/O", "Desktop/O 자료",
                         "Desktop/S", "Desktop/U", "Documents/Codex", "Documents/Adobe",
                         "Documents/WebEx", "Documents/plasticity", "Documents/antigravity",
                         "Documents/ChatGPT", "Downloads/electron-test"]
        return OrganizerRules(
            projects: [
                .init(name: "Taste Buddy", prefixes: ["TasteBuddy", "Taste Buddy"]),
                .init(name: "Setly", prefixes: ["Setly"]),
                .init(name: "O", prefixes: ["O"]),
                .init(name: "Pisa", prefixes: ["Pisa"]),
                .init(name: "포트폴리오", prefixes: ["포트폴리오", "Portfolio"])
            ],
            protectedPaths: protected.map { home.appendingPathComponent($0).path },
            referencePrefixes: ["Withings", "참고", "Reference", "스크린샷", "Screenshot"],
            personalPrefixes: ["이력서", "자기소개서", "경력", "시간표", "Resume", "CV"]
        )
    }

    public var categories: [String] { projects.map(\.name) + ["참고", "개인"] }
    public static let projectMarkers: Set<String> = [
        ".git", ".hg", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml",
        "settings.gradle", "settings.gradle.kts", "project.yml", ".openai"
    ]
    public static let managedNames: Set<String> = [
        "Library", "Applications", "System", "node_modules", "Pods", "__pycache__", "DerivedData",
        "SourcePackages", "build", "dist", "target", "vendor", ".build"
    ]
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "xcodeproj", "xcworkspace", "xcassets",
        "photoslibrary", "photolibrary", "logicx", "band", "pages", "numbers", "keynote"
    ]
    public static let protectedFileExtensions: Set<String> = [
        "p8", "pem", "key", "p12", "pfx", "mobileprovision", "cer", "provisionprofile",
        "mov", "mp4", "m4v", "wav", "aiff", "flac", "prproj", "aep", "aepx", "blend",
        "plasticity", "sketch", "fig", "psd", "psb", "c4d", "sln", "pbxproj"
    ]
    public static let referenceExtensions: Set<String> = [
        "md", "txt", "json", "toml", "yaml", "yml", "html", "css", "swift", "py", "js", "mjs",
        "ts", "tsx", "jsx", "sh", "plist", "pbxproj", "xcconfig", "xml"
    ]

    public func validate() throws {
        guard version == 1, maximumSnapshotEntries > 0, maximumSnapshotEntries <= 100_000,
              maximumSnapshotBytes > 0, maximumSnapshotBytes <= 2_147_483_648,
              maximumReferenceFiles > 0, maximumReferenceFiles <= 20_000,
              maximumReferenceBytes > 0, maximumReferenceBytes <= 268_435_456 else {
            throw OrganizerError("지원하지 않는 규칙 버전 또는 조사 한도입니다.")
        }
        var seen = Set<String>()
        for project in projects {
            try PathSafety.validateComponent(project.name)
            guard !["참고", "개인", "보관"].contains(project.name),
                  seen.insert(project.name.lowercased().precomposedStringWithCanonicalMapping).inserted,
                  !project.prefixes.isEmpty else { throw OrganizerError("프로젝트 이름이 겹치거나 이름 규칙이 비어 있습니다.") }
            for prefix in project.prefixes { try PathSafety.validateComponent(prefix) }
        }
        for prefix in referencePrefixes + personalPrefixes { try PathSafety.validateComponent(prefix) }
    }

    public func matchingProject(_ name: String) -> (ProjectRule, String)? {
        for project in projects {
            for prefix in project.prefixes.sorted(by: { $0.count > $1.count }) where Self.hasPrefix(name, prefix) {
                return (project, prefix)
            }
        }
        return nil
    }

    public static func hasPrefix(_ value: String, _ prefix: String) -> Bool {
        let name = value.precomposedStringWithCanonicalMapping.lowercased()
        let key = prefix.precomposedStringWithCanonicalMapping.lowercased()
        guard !key.isEmpty, name.hasPrefix(key) else { return false }
        if name.count == key.count { return true }
        let next = name.dropFirst(key.count).first!
        return " -_().[]".contains(next)
    }

    public func isProtectedPath(_ url: URL) -> Bool {
        protectedPaths.contains { PathSafety.contains(PathSafety.lexicalURL(URL(fileURLWithPath: $0)), url) }
    }

    public func normalFolderName(_ name: String, removing prefix: String?) throws -> String {
        var value = name.precomposedStringWithCanonicalMapping
        if let prefix, Self.hasPrefix(value, prefix) {
            value = String(value.dropFirst(prefix.precomposedStringWithCanonicalMapping.count))
        }
        let regex = try NSRegularExpression(pattern: "(?:19|20)[0-9]{2}-[0-9]{2}-[0-9]{2}")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var date: String?
        if let match = regex.firstMatch(in: value, range: range), let swiftRange = Range(match.range, in: value) {
            let found = String(value[swiftRange])
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            if let parsed = formatter.date(from: found), formatter.string(from: parsed) == found {
                date = found; value.removeSubrange(swiftRange)
            }
        }
        let separators = CharacterSet(charactersIn: " -_()[]")
        let words = value.components(separatedBy: separators).filter { !$0.isEmpty }
        value = words.joined(separator: " ")
        if value.isEmpty { value = prefix ?? name }
        if let date { value = date + " " + value }
        try PathSafety.validateComponent(value)
        return value
    }
}

public enum PathSafety {
    /// Foundation standardization turns /private/var back into /var on macOS.
    /// Keep lexical normalization separate from explicit, one-time root resolution.
    public static func lexicalURL(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.path.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    public static func resolveExistingPrefix(_ url: URL) throws -> URL {
        var existing = lexicalURL(url)
        var suffix: [String] = []
        while !SafeFileSystem.exists(existing) {
            guard existing.path != "/" else { throw OrganizerError("상위 폴더를 찾을 수 없습니다.") }
            suffix.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        guard let pointer = realpath(existing.path, nil) else { throw OrganizerError("폴더의 실제 경로를 확인할 수 없습니다.") }
        defer { free(pointer) }
        var resolved = URL(fileURLWithPath: String(cString: pointer))
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved
    }

    public static func contains(_ root: URL, _ item: URL) -> Bool {
        let a = lexicalURL(root).path.precomposedStringWithCanonicalMapping
        let b = lexicalURL(item).path.precomposedStringWithCanonicalMapping
        return b == a || b.hasPrefix(a == "/" ? "/" : a + "/")
    }
    public static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              value.utf8.count <= 200,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":" }) else {
            throw OrganizerError("폴더 이름에 사용할 수 없는 문자가 있습니다: \(value)")
        }
    }
    public static func canonicalRoot(_ url: URL) throws -> URL {
        let value = try resolveExistingPrefix(url)
        guard value.path != "/", value.pathComponents.count >= 3 else { throw OrganizerError("전체 디스크 대신 자료가 담긴 폴더를 선택해 주세요.") }
        let forbidden = ["/System", "/Library", "/Applications", "/private/etc", "/private/var/db", "/usr", "/bin", "/sbin"]
        guard !forbidden.contains(where: { contains(URL(fileURLWithPath: $0), value) }),
              !value.pathComponents.contains(where: { $0 == "Library" || $0.hasPrefix(".") }) else {
            throw OrganizerError("시스템·앱 데이터·숨김 폴더는 정리 대상에 넣을 수 없습니다.")
        }
        return value
    }
    public static func nonOverlappingRoots(_ values: [URL]) throws -> [URL] {
        var result: [URL] = []
        for url in try values.map(canonicalRoot).sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { contains($0, url) }) { result.append(url) }
        }
        return result
    }
}
