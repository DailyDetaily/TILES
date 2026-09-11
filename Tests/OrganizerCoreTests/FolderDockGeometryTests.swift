import XCTest
@testable import OrganizerCore

final class FolderDockGeometryTests: XCTestCase {
    let screens: [(CGRect, CGRect, CGFloat)] = [
        (CGRect(x: 0, y: 0, width: 2048, height: 1280), CGRect(x: 0, y: 0, width: 2048, height: 1249), 0),
        (CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: -1920, y: -250, width: 1920, height: 1000), 38),
        (CGRect(x: 0, y: 0, width: 320, height: 240), CGRect(x: 0, y: 20, width: 320, height: 200), 30)
    ]
    func testPlacementStaysInVisibleScreenIncludingSmallAndNegativeDisplays() {
        for (screen, visible, safe) in screens {
            let area = FolderDockGeometry.usable(screen: screen, visible: visible, safeTop: safe)
            for x in [0.0, 0.5, 1] { for y in [0.0, 0.5, 1] {
                let layout = FolderDockLayout(horizontal: x, vertical: y, width: 920, height: 340)
                let frame = FolderDockGeometry.frame(layout: layout, usable: area)
                XCTAssertTrue(area.insetBy(dx: -1, dy: -1).contains(frame))
                let trigger = FolderDockGeometry.trigger(layout: layout, usable: area)
                XCTAssertEqual(trigger, frame)
                let restored = FolderDockGeometry.frame(layout: FolderDockGeometry.placement(frame: frame, usable: area), usable: area)
                XCTAssertEqual(restored, frame)
            }}
        }
    }
    func testResizingKeepsOppositeCornerAndClampsLargeDeltas() {
        let area = CGRect(x: -1200, y: -100, width: 1800, height: 1000)
        let frame = CGRect(x: -700, y: 300, width: 520, height: 196)
        for corner in FolderDockGeometry.Corner.allCases {
            for delta in [CGSize(width: 120, height: 70), CGSize(width: -5000, height: 5000), CGSize(width: 5000, height: -5000)] {
                let result = FolderDockGeometry.resized(frame, corner: corner, by: delta, usable: area)
                XCTAssertTrue(area.contains(result)); XCTAssertTrue((360...920).contains(result.width)); XCTAssertTrue((172...340).contains(result.height))
                XCTAssertEqual(corner == .topLeft || corner == .bottomLeft ? result.maxX : result.minX,
                               corner == .topLeft || corner == .bottomLeft ? frame.maxX : frame.minX)
                XCTAssertEqual(corner == .topLeft || corner == .topRight ? result.minY : result.maxY,
                               corner == .topLeft || corner == .topRight ? frame.minY : frame.maxY)
            }
        }
    }
    func testMoveAndInvalidSavedValuesRecoverWithoutLeavingScreen() {
        let area = CGRect(x: -1920, y: 0, width: 1896, height: 1010)
        let invalid = FolderDockLayout(horizontal: .nan, vertical: .infinity, width: -100, height: .infinity).sanitized
        XCTAssertEqual(invalid.horizontal, 0.5); XCTAssertEqual(invalid.vertical, 0)
        let frame = FolderDockGeometry.frame(layout: invalid, usable: area)
        for delta in [CGSize(width: 99999, height: 99999), CGSize(width: -99999, height: -99999)] {
            XCTAssertTrue(area.contains(FolderDockGeometry.moved(frame, by: delta, usable: area)))
        }
    }
    func testCenterSnapAcquiresHoldsAndReleasesEachAxis() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let area = CGRect(x: -1908, y: -188, width: 1896, height: 1037)
        let centered = CGRect(x: screen.midX - 260, y: screen.midY - 98, width: 520, height: 196)
        let near = centered.offsetBy(dx: 11, dy: -9)
        let acquired = FolderDockGeometry.centered(near, screen: screen, usable: area)
        XCTAssertEqual(acquired.frame, centered); XCTAssertEqual(acquired.axes, [.x, .y])
        let held = FolderDockGeometry.centered(centered.offsetBy(dx: 20, dy: -21), screen: screen, usable: area, previous: acquired.axes)
        XCTAssertEqual(held.frame, centered); XCTAssertEqual(held.axes, [.x, .y])
        let released = FolderDockGeometry.centered(centered.offsetBy(dx: 23, dy: -9), screen: screen, usable: area, previous: held.axes)
        XCTAssertEqual(released.axes, [.y]); XCTAssertEqual(released.frame.midX, screen.midX + 23)
        XCTAssertEqual(released.frame.midY, screen.midY)
        let outside = centered.offsetBy(dx: 13, dy: 13)
        let unsnapped = FolderDockGeometry.centered(outside, screen: screen, usable: area)
        XCTAssertEqual(unsnapped.frame, outside); XCTAssertTrue(unsnapped.axes.isEmpty)
    }
    func testFractionalSavedSizesDoNotGrowAcrossRepeatedCentering() {
        let screen = CGRect(x: 0, y: 0, width: 2048, height: 1280)
        let area = FolderDockGeometry.usable(screen: screen, visible: CGRect(x: 0, y: 0, width: 2048, height: 1249), safeTop: 0)
        var layout = FolderDockLayout(horizontal: 0.5, vertical: 0.5, width: 780.4254150390625, height: 307.25)
        for _ in 0..<20 {
            let frame = FolderDockGeometry.frame(layout: layout, usable: area)
            XCTAssertEqual(frame.width, 780.4254150390625, accuracy: 0.000001)
            XCTAssertEqual(frame.height, 307.25, accuracy: 0.000001)
            let snapped = FolderDockGeometry.centered(frame, screen: screen, usable: area)
            XCTAssertEqual(snapped.frame.midX, screen.midX, accuracy: 0.000001)
            layout = FolderDockGeometry.placement(frame: snapped.frame, usable: area)
        }
    }
    func testSnapNeverPlacesWindowOutsideUsableArea() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let area = CGRect(x: 100, y: 10, width: 800, height: 390)
        let frame = CGRect(x: 100, y: 10, width: 800, height: 380)
        let result = FolderDockGeometry.centered(frame, screen: screen, usable: area, previous: [.x, .y])
        XCTAssertTrue(area.contains(result.frame)); XCTAssertFalse(result.axes.contains(.y))
    }
    func testRoundingPreservesDefaultShortEdgeRatioAtAllSizes() {
        let base = FolderDockGeometry.cornerRadius(size: .init(width: 520, height: 196))
        XCTAssertEqual(base, 20, accuracy: 0.0001)
        for scale in [0.7, 1.0, 1.5, 2.0] {
            XCTAssertEqual(FolderDockGeometry.cornerRadius(size: .init(width: 520 * scale, height: 196 * scale)), base * scale, accuracy: 0.0001)
        }
        let size = CGSize(width: 780, height: 340)
        XCTAssertEqual(FolderDockGeometry.cornerRadius(size: size) / size.height, 20 / 196.0, accuracy: 0.0001)
    }
    func testOuterHandlesFollowRoundedCornersAndLeaveButtonsAvailable() {
        for size in [CGSize(width: 360, height: 172), CGSize(width: 520, height: 196), CGSize(width: 780, height: 340)] {
            let radius = FolderDockGeometry.cornerRadius(size: size), gap = FolderDockGeometry.handleOffset
            let diagonal = (radius + gap) / sqrt(2)
            let targets: [(FolderDockGeometry.Corner, CGPoint)] = [
                (.topLeft, .init(x: radius - diagonal, y: radius - diagonal)),
                (.topRight, .init(x: size.width - radius + diagonal, y: radius - diagonal)),
                (.bottomRight, .init(x: size.width - radius + diagonal, y: size.height - radius + diagonal)),
                (.bottomLeft, .init(x: radius - diagonal, y: size.height - radius + diagonal))
            ]
            let padded = CGRect(origin: .zero, size: size).insetBy(dx: -FolderDockGeometry.editPadding, dy: -FolderDockGeometry.editPadding)
            for (corner, point) in targets {
                XCTAssertEqual(FolderDockGeometry.corner(at: point, size: size), corner)
                let path = FolderDockGeometry.handlePath(corner: corner, size: size)
                // The footprint stays compact instead of scaling with the shelf.
                XCTAssertTrue((20...22).contains(path.boundingBoxOfPath.width))
                XCTAssertEqual(path.boundingBoxOfPath.height, path.boundingBoxOfPath.width, accuracy: 0.00001)
                let hit = path.copy(strokingWithWidth: FolderDockGeometry.handleHitWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
                XCTAssertTrue(padded.contains(hit.boundingBoxOfPath))
            }
            // The external interaction band must not turn Done/Default into resize targets.
            for x in stride(from: size.width - 140, through: size.width - 28, by: 4) {
                XCTAssertNil(FolderDockGeometry.corner(at: .init(x: x, y: size.height - 17), size: size))
            }
            XCTAssertNil(FolderDockGeometry.corner(at: .init(x: size.width / 2, y: 13), size: size))
        }
    }
    func testHandleLineLengthStaysFixedWhileCurvatureFollowsShelf() {
        for size in [CGSize(width: 360, height: 172), CGSize(width: 520, height: 196), CGSize(width: 920, height: 340)] {
            let radius = FolderDockGeometry.cornerRadius(size: size)
            for corner in FolderDockGeometry.Corner.allCases {
                let center = CGPoint(x: corner == .topLeft || corner == .bottomLeft ? radius : size.width - radius,
                                     y: corner == .topLeft || corner == .topRight ? radius : size.height - radius)
                let points = sampledPoints(FolderDockGeometry.handlePath(corner: corner, size: size))
                let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) {
                    $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
                }
                XCTAssertEqual(length, .pi * 9.75, accuracy: 0.01)
                for point in points {
                    XCTAssertEqual(hypot(point.x - center.x, point.y - center.y) - radius, 12, accuracy: 0.01)
                }
            }
        }
    }
    private func sampledPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = [], current = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                current = element.points[0]; points.append(current)
            case .addCurveToPoint:
                let start = current, first = element.points[0], second = element.points[1], end = element.points[2]
                for step in 1...100 {
                    let t = CGFloat(step) / 100, u = 1 - t
                    points.append(.init(x: u*u*u*start.x + 3*u*u*t*first.x + 3*u*t*t*second.x + t*t*t*end.x,
                                        y: u*u*u*start.y + 3*u*u*t*first.y + 3*u*t*t*second.y + t*t*t*end.y))
                }
                current = end
            default: break
            }
        }
        return points
    }
    func testEditCanvasPaddingDoesNotChangeDockPlacementOrHiddenReceiver() {
        for (screen, visible, safe) in screens {
            let area = FolderDockGeometry.usable(screen: screen, visible: visible, safeTop: safe)
            let dock = FolderDockGeometry.frame(layout: .init(width: 769.20703125, height: 329.94110107421875), usable: area)
            let panel = FolderDockGeometry.panelFrame(dockFrame: dock, editing: true)
            let content = FolderDockGeometry.dockBounds(size: dock.size, editing: true)
            XCTAssertEqual(content.offsetBy(dx: panel.minX, dy: panel.minY), dock)
            XCTAssertEqual(FolderDockGeometry.panelFrame(dockFrame: dock, editing: false), dock)
            let saved = FolderDockGeometry.placement(frame: dock, usable: area)
            XCTAssertEqual(FolderDockGeometry.trigger(layout: saved, usable: area), dock)
        }
    }
    func testDestinationFramesDoNotOverlapOrCoverHeaderAndResizeCorners() {
        for size in [CGSize(width: 360, height: 172), CGSize(width: 520, height: 196), CGSize(width: 920, height: 340)] {
            for count in 1...3 {
                let frames = FolderDockGeometry.items(size: size, count: count)
                for (index, rect) in frames.enumerated() {
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect)); XCTAssertGreaterThan(rect.width, 70)
                    XCTAssertGreaterThanOrEqual(rect.minY, 24); XCTAssertLessThanOrEqual(rect.maxY, size.height - 24)
                    for other in frames.dropFirst(index + 1) { XCTAssertFalse(rect.intersects(other)) }
                }
            }
        }
    }
}
