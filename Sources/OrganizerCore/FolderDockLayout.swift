import Foundation
import CoreGraphics

/// Relative placement survives display size changes; sizes are always AppKit points.
public struct FolderDockLayout: Codable, Equatable, Sendable {
    public var horizontal: Double
    public var vertical: Double
    public var width: Double
    public var height: Double
    public init(horizontal: Double = 0.5, vertical: Double = 0, width: Double = 520, height: Double = 196) {
        self.horizontal = horizontal; self.vertical = vertical; self.width = width; self.height = height
    }
    public var sanitized: Self {
        func limit(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return .init(horizontal: limit(horizontal, 0...1, 0.5), vertical: limit(vertical, 0...1, 0),
                     width: limit(width, 360...920, 520), height: limit(height, 172...340, 196))
    }
}

public enum FolderDockGeometry {
    public enum Corner: CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public static func usable(screen: CGRect, visible: CGRect, safeTop: CGFloat) -> CGRect {
        // Leave the external stroke visible even beside the menu bar or screen edge.
        let margin = handleOffset + handleLineWidth / 2 + 2
        let top = min(visible.maxY, screen.maxY - max(0, safeTop)) - margin
        return CGRect(x: visible.minX + margin, y: visible.minY + margin,
                      width: max(1, visible.width - margin * 2), height: max(1, top - visible.minY - margin))
    }
    public static func frame(layout: FolderDockLayout, usable: CGRect) -> CGRect {
        let value = layout.sanitized
        let size = CGSize(width: min(value.width, usable.width), height: min(value.height, usable.height))
        return CGRect(x: usable.minX + (usable.width - size.width) * value.horizontal,
                      y: usable.maxY - size.height - (usable.height - size.height) * value.vertical,
                      width: size.width, height: size.height)
    }
    public static func trigger(layout: FolderDockLayout, usable: CGRect) -> CGRect {
        frame(layout: layout, usable: usable)
    }
    public struct CenterAxes: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let x = Self(rawValue: 1)
        public static let y = Self(rawValue: 2)
    }
    /// Acquire within 12pt; release beyond 22pt to avoid jitter around the center.
    public static func centered(_ frame: CGRect, screen: CGRect, usable: CGRect,
                                previous: CenterAxes = []) -> (frame: CGRect, axes: CenterAxes) {
        var result = frame, axes: CenterAxes = []
        if abs(frame.midX - screen.midX) <= (previous.contains(.x) ? 22 : 12) {
            let x = screen.midX - frame.width / 2
            if x >= usable.minX && x + frame.width <= usable.maxX {
                result.origin.x = x; axes.insert(.x)
            }
        }
        if abs(frame.midY - screen.midY) <= (previous.contains(.y) ? 22 : 12) {
            let y = screen.midY - frame.height / 2
            if y >= usable.minY && y + frame.height <= usable.maxY {
                result.origin.y = y; axes.insert(.y)
            }
        }
        return (result, axes)
    }
    /// The default 520×196 shelf has a 20pt radius: keep that short-edge ratio.
    public static func cornerRadius(size: CGSize) -> CGFloat {
        max(0, min(size.width, size.height)) * (20.0 / 196.0)
    }
    public static let handleOffset: CGFloat = 12
    public static let handleLineWidth: CGFloat = 6
    public static let handleHitWidth: CGFloat = 20
    // Fixed length, shortened by 25% from the previous 13πpt handle.
    public static let handleArcLength: CGFloat = .pi * 9.75
    public static let editPadding: CGFloat = 24
    /// Editing chrome is outside the saved shelf. Hidden/drop frames have no padding.
    public static func panelFrame(dockFrame: CGRect, editing: Bool) -> CGRect {
        editing ? dockFrame.insetBy(dx: -editPadding, dy: -editPadding) : dockFrame
    }
    public static func dockBounds(size: CGSize, editing: Bool) -> CGRect {
        let padding = editing ? editPadding : 0
        return CGRect(x: padding, y: padding, width: size.width, height: size.height)
    }
    /// Flipped shelf coordinates: the outer curve shares the shelf corner's center.
    public static func handlePath(corner: Corner, size: CGSize) -> CGPath {
        let radius = cornerRadius(size: size)
        let center: CGPoint, middle: CGFloat
        switch corner {
        case .topLeft: center = .init(x: radius, y: radius); middle = .pi * 1.25
        case .topRight: center = .init(x: size.width - radius, y: radius); middle = .pi * 1.75
        case .bottomRight: center = .init(x: size.width - radius, y: size.height - radius); middle = .pi * 0.25
        case .bottomLeft: center = .init(x: radius, y: size.height - radius); middle = .pi * 0.75
        }
        let outerRadius = radius + handleOffset
        let halfAngle = min(.pi / 2, handleArcLength / outerRadius) / 2
        let path = CGMutablePath()
        path.addArc(center: center, radius: outerRadius,
                    startAngle: middle - halfAngle, endAngle: middle + halfAngle, clockwise: false)
        return path
    }
    public static func placement(frame: CGRect, usable: CGRect) -> FolderDockLayout {
        .init(horizontal: (frame.minX - usable.minX) / max(1, usable.width - frame.width),
              vertical: (usable.maxY - frame.maxY) / max(1, usable.height - frame.height),
              width: frame.width, height: frame.height).sanitized
    }
    public static func moved(_ frame: CGRect, by delta: CGSize, usable: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, usable.width), height: min(frame.height, usable.height))
        return CGRect(x: min(max(frame.minX + delta.width, usable.minX), usable.maxX - size.width),
                      y: min(max(frame.minY + delta.height, usable.minY), usable.maxY - size.height),
                      width: size.width, height: size.height)
    }
    public static func resized(_ frame: CGRect, corner: Corner, by delta: CGSize, usable: CGRect) -> CGRect {
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let maxWidth = min(920, left ? frame.maxX - usable.minX : usable.maxX - frame.minX)
        let maxHeight = min(340, top ? usable.maxY - frame.minY : frame.maxY - usable.minY)
        let width = min(max(frame.width + (left ? -delta.width : delta.width), min(360, maxWidth)), maxWidth)
        let height = min(max(frame.height + (top ? delta.height : -delta.height), min(172, maxHeight)), maxHeight)
        return CGRect(x: left ? frame.maxX - width : frame.minX, y: top ? frame.minY : frame.maxY - height,
                      width: width, height: height)
    }
    /// Flipped content coordinates, shared by drawing and native drop hit testing.
    public static func items(size: CGSize, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let gap: CGFloat = 12, available = max(1, size.width - 48)
        let width = min(180, (available - gap * CGFloat(count - 1)) / CGFloat(count))
        let total = width * CGFloat(count) + gap * CGFloat(count - 1)
        return (0..<count).map { CGRect(x: (size.width - total) / 2 + CGFloat($0) * (width + gap),
                                       y: 24, width: width, height: max(70, size.height - 48)) }
    }
    public static func corner(at point: CGPoint, size: CGSize) -> Corner? {
        Corner.allCases.first {
            handlePath(corner: $0, size: size)
                .copy(strokingWithWidth: handleHitWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
                .contains(point)
        }
    }
}
