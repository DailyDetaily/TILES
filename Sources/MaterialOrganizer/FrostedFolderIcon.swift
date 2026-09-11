import AppKit
import CoreImage
import OrganizerCore
import UniformTypeIdentifiers

/// Reference-shaped folder: crisp file tips above a blurred, tinted front pocket.
@MainActor enum FrostedFolderIcon {
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private static let size = CGSize(width: 144, height: 132)

    static func make(primary: Bool, previews: [FolderContentPreview]) -> NSImage {
        let stack = fileStack(previews)
        let blurred = blur(stack)
        let backTop = primary ? color(0.10, 0.43, 0.79) : color(0.17, 0.18, 0.19)
        let backBottom = primary ? color(0.04, 0.23, 0.49) : color(0.055, 0.06, 0.065)
        return NSImage(size: size, flipped: true) { _ in
            let back = NSBezierPath(roundedRect: .init(x: 8, y: 8, width: 128, height: 112), xRadius: 13, yRadius: 13)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
            shadow.shadowBlurRadius = 5; shadow.shadowOffset = .init(width: 0, height: -3); shadow.set()
            backBottom.setFill(); back.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: backTop, ending: backBottom)?.draw(in: back, angle: 90)
            NSColor.white.withAlphaComponent(0.18).setStroke(); back.lineWidth = 0.8; back.stroke()
            stack.draw(in: .init(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let front = frontPath()
            NSGraphicsContext.saveGraphicsState(); front.addClip()
            NSGradient(starting: backTop, ending: backBottom)?.draw(in: front, angle: 90)
            blurred.draw(in: .init(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let top = primary ? color(0.17, 0.52, 0.91, 0.50) : color(0.12, 0.13, 0.14, 0.56)
            let bottom = primary ? color(0.07, 0.33, 0.68, 0.90) : color(0.065, 0.07, 0.075, 0.94)
            NSGradient(starting: top, ending: bottom)?.draw(in: front, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(primary ? 0.34 : 0.25).setStroke()
            front.lineWidth = 0.9; front.stroke()
            return true
        }
    }
    private static func fileStack(_ previews: [FolderContentPreview]) -> NSImage {
        let images = previews.prefix(3).map { item in
            item.thumbnail.flatMap(NSImage.init(data:)) ?? NSWorkspace.shared.icon(for: UTType(item.typeIdentifier) ?? .data)
        }
        return NSImage(size: size, flipped: true) { _ in
            for (index, image) in images.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                let x = CGFloat(22 + index * 8), y = CGFloat(24 - index * 4)
                let transform = NSAffineTransform()
                transform.translateX(by: x + 43, yBy: y + 46)
                transform.rotate(byDegrees: [-7.0, 4.0, -2.0][index])
                transform.translateX(by: -43, yBy: -46); transform.concat()
                let paper = NSBezierPath(roundedRect: .init(x: 0, y: 0, width: 86, height: 94), xRadius: 4, yRadius: 4)
                color(0.91, 0.91, 0.88).setFill(); paper.fill(); paper.addClip()
                image.draw(in: .init(x: 3, y: 3, width: 80, height: 88), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }
    private static func blur(_ image: NSImage) -> NSImage {
        guard let data = image.tiffRepresentation, let input = CIImage(data: data) else { return image }
        let output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.8]).cropped(to: input.extent)
        guard let cgImage = imageContext.createCGImage(output, from: input.extent) else { return image }
        return NSImage(cgImage: cgImage, size: size)
    }
    private static func frontPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: .init(x: 16, y: 30)); path.line(to: .init(x: 67, y: 30))
        path.curve(to: .init(x: 78, y: 36), controlPoint1: .init(x: 74, y: 30), controlPoint2: .init(x: 76, y: 32))
        path.line(to: .init(x: 82, y: 42))
        path.curve(to: .init(x: 92, y: 47), controlPoint1: .init(x: 85, y: 46), controlPoint2: .init(x: 88, y: 47))
        path.line(to: .init(x: 130, y: 47))
        path.curve(to: .init(x: 142, y: 59), controlPoint1: .init(x: 139, y: 47), controlPoint2: .init(x: 142, y: 52))
        path.line(to: .init(x: 142, y: 112))
        path.curve(to: .init(x: 130, y: 124), controlPoint1: .init(x: 142, y: 121), controlPoint2: .init(x: 139, y: 124))
        path.line(to: .init(x: 16, y: 124))
        path.curve(to: .init(x: 4, y: 112), controlPoint1: .init(x: 7, y: 124), controlPoint2: .init(x: 4, y: 121))
        path.line(to: .init(x: 4, y: 43))
        path.curve(to: .init(x: 16, y: 30), controlPoint1: .init(x: 4, y: 34), controlPoint2: .init(x: 8, y: 30))
        path.close(); return path
    }
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
