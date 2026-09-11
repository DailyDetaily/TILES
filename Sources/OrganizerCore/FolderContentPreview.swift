import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Small, ephemeral display data. The panel process never reads the source file.
public struct FolderContentPreview: Codable, Equatable, Sendable {
    public var name: String
    public var typeIdentifier: String
    public var thumbnail: Data?
}

public enum FolderContentPreviews {
    /// Top-level files only, sampled while the host refreshes its authorized catalogue.
    public static func load(catalogue: [FolderDestination], root: URL, rules: OrganizerRules) -> [String: [FolderContentPreview]] {
        var result: [String: [FolderContentPreview]] = [:]
        let thumbnailDeadline = Date().addingTimeInterval(2)
        for folder in catalogue.prefix(32) {
            let directory = URL(fileURLWithPath: folder.path)
            guard PathSafety.contains(root, directory),
                  (try? SafeFileSystem.validateDirectory(directory)) != nil,
                  (try? SafeFileSystem.identity(at: directory)) == folder.identity,
                  let enumerator = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]) else { continue }
            var items: [FolderContentPreview] = []
            var inspected = 0
            while let url = enumerator.nextObject() as? URL, inspected < 64, items.count < 3 {
                inspected += 1
                guard !rules.isProtectedPath(url),
                      let identity = try? ExistingFileDrop.inspect(url),
                      let before = try? SafeFileSystem.info(url) else { continue }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: url.pathExtension) ?? .data
                var thumbnail: Data?
                if type.conforms(to: .image), Date() < thumbnailDeadline, before.st_size <= 16_777_216 {
                    thumbnail = try? SafeFileSystem.withDirectoryFD(directory) { parent in
                        var parentInfo = stat()
                        guard fstat(parent, &parentInfo) == 0,
                              SafeFileSystem.identity(parentInfo) == folder.identity else { return nil }
                        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard descriptor >= 0 else { return nil }
                        defer { close(descriptor) }
                        var opened = stat()
                        guard fstat(descriptor, &opened) == 0, SafeFileSystem.identity(opened) == identity,
                              opened.st_flags & UInt32(SF_DATALESS) == 0,
                              opened.st_size > 0, opened.st_size <= 16_777_216 else { return nil }
                        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
                        while data.count <= 16_777_216 {
                            let count = read(descriptor, &buffer, buffer.count)
                            if count == 0 { break }
                            if count < 0 { if errno == EINTR { continue }; return nil }
                            data.append(contentsOf: buffer.prefix(count))
                        }
                        var after = stat()
                        guard data.count <= 16_777_216, fstat(descriptor, &after) == 0,
                              after.st_size == opened.st_size,
                              after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else { return nil }
                        return thumbnailData(data)
                    }
                }
                items.append(.init(name: url.lastPathComponent, typeIdentifier: type.identifier, thumbnail: thumbnail))
            }
            result[folder.path] = items
        }
        return result
    }
    private static func thumbnailData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.45] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 4_096 else { return nil }
        return output as Data
    }
}
