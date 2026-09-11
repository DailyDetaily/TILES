import AppKit
import XCTest
import OrganizerCore
@testable import MaterialOrganizer

final class OverlayTransportTests: XCTestCase {
    private func operationTestFolder() throws -> FolderDropTarget {
        let identity = try JSONDecoder().decode(FileIdentity.self,
            from: Data(#"{"device":1,"inode":2,"kind":"directory"}"#.utf8))
        return .folder(.init(destination: .init(path: "/tmp/destination", identity: identity), reason: "기존 폴더"))
    }

    func testFinderGenericAndCopyOnlyDragsUseTargetSpecificOperations() throws {
        let folder = try operationTestFolder()
        let cases: [(NSDragOperation, NSDragOperation, NSDragOperation)] = [
            (.init(rawValue: 4), .generic, .generic),
            ([.generic, .move, .copy], .generic, .generic),
            (.copy, .copy, []),
            (.move, [], .move),
            ([.copy, .move], .copy, .move),
            ([], [], []), (.link, [], []), (.delete, [], [])
        ]
        for (mask, reviewOperation, folderOperation) in cases {
            XCTAssertEqual(FolderOverlayDragOperations.operation(for: .recommendation, mask: mask), reviewOperation)
            XCTAssertEqual(FolderOverlayDragOperations.operation(for: folder, mask: mask), folderOperation)
            XCTAssertEqual(FolderOverlayDragOperations.supportsInput(mask), !reviewOperation.isEmpty || !folderOperation.isEmpty)
        }
        let files = [URL(fileURLWithPath: "/tmp/first.txt"), URL(fileURLWithPath: "/tmp/second.txt")]
        XCTAssertEqual(try ExistingFileDrop.validateInputs(urls: files, itemCount: 2, hasFilePromise: false,
            allowsFileHandoff: FolderOverlayDragOperations.supportsInput(.generic)), files)
        XCTAssertEqual(try ExistingFileDrop.validateInputs(urls: files, itemCount: 2, hasFilePromise: false,
            allowsFileHandoff: FolderOverlayDragOperations.supportsInput(.copy)), files)
        XCTAssertThrowsError(try ExistingFileDrop.validateInputs(urls: files, itemCount: 2, hasFilePromise: false,
            allowsFileHandoff: FolderOverlayDragOperations.supportsInput(.link)))
    }

    func testCopyOnlyReviewKeepsOnceOnlySessionAndCannotAcceptDirectMove() throws {
        let sources = ["/tmp/first.txt", "/tmp/second.txt"]
        let folder = try operationTestFolder()
        var session = FolderDropSession()
        let token = try XCTUnwrap(session.begin(sequence: 700, sources: sources))
        XCTAssertTrue(session.freeze(targets: [.recommendation, folder], for: token))
        session.hover(folder.id)
        let moveOperation = FolderOverlayDragOperations.operation(for: folder, mask: .copy)
        XCTAssertNil(session.accept(sequence: 700, sources: sources, allowsOperation: !moveOperation.isEmpty, busy: false))
        session.hover(FolderDropTarget.recommendation.id)
        let reviewOperation = FolderOverlayDragOperations.operation(for: .recommendation, mask: .copy)
        XCTAssertNil(session.accept(sequence: 700, sources: [sources[0]], allowsOperation: true, busy: false))
        XCTAssertEqual(session.accept(sequence: 700, sources: sources, allowsOperation: !reviewOperation.isEmpty, busy: false), .recommendation)
        XCTAssertNil(session.accept(sequence: 700, sources: sources, allowsOperation: true, busy: false))
        session.ended(sequence: 700); session.finish(); session.reset()
        XCTAssertNil(session.begin(sequence: 700, sources: sources))
    }

    func testBatchReviewPacketRoundTripAndLegacySingleSourceFallback() throws {
        let paths = ["/tmp/자료/두 줄\n이름.txt", "/tmp/자료/따옴표 \"파일\".txt"]
        let packet = FolderOverlayPacket(nonce: "review", kind: .recommendation, id: UUID(), sources: paths)
        let encoded = try FolderOverlayPipe.encode(packet)
        let decoded = try JSONDecoder().decode(FolderOverlayPacket.self, from: encoded.dropLast())
        XCTAssertEqual(decoded.kind, .recommendation)
        XCTAssertEqual(try decoded.validatedSources().map(\.path), paths)
        let old = Data("{\"nonce\":\"old\",\"kind\":\"drop\",\"source\":\"/tmp/file.txt\"}".utf8)
        let legacy = try JSONDecoder().decode(FolderOverlayPacket.self, from: old)
        XCTAssertNil(legacy.sources)
        XCTAssertEqual(try legacy.validatedSources().map(\.path), ["/tmp/file.txt"])
    }

    func testHostBoundaryRejectsAmbiguousPathsDuplicatesAndOversizedSelections() throws {
        let invalid = [[], ["relative.txt"], ["file:///tmp/a.txt"], ["/tmp/../a.txt"], ["/tmp/./a.txt"],
                       ["//remote/a.txt"], ["/tmp/a\0.txt"], ["/"], ["/tmp/a", "/tmp/a"],
                       (0..<501).map { "/tmp/\($0).txt" }]
        for paths in invalid {
            let packet = FolderOverlayPacket(nonce: "test", kind: .recommendation, sources: paths)
            XCTAssertThrowsError(try packet.validatedSources(), "Accepted invalid path list: \(paths.prefix(2))")
        }
    }

    @MainActor func testReviewAcknowledgementUnblocksNewDropsAndShutdownCompletesPendingRequestOnce() async throws {
        let input = Pipe(), output = Pipe()
        let channel = FolderOverlayPipe(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        defer { channel.close(); try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let snapshot = FolderOverlaySnapshot(revision: 1, root: "/tmp", sources: [], destinationConnected: false,
            rules: .standard(), catalogue: [], catalogueLoading: false, busy: false, isDemo: true)
        var acquired: [URL] = [], released: [URL] = []
        let context = FolderOverlayContext(snapshot: snapshot, channel: channel, nonce: "test",
            startAccess: { acquired.append($0); return true }, stopAccess: { released.append($0) })
        var completionCount = 0
        context.acceptFilesForReview([URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]) { _ in completionCount += 1 }
        XCTAssertTrue(context.busy)
        let data = output.fileHandleForReading.availableData
        let packet = try JSONDecoder().decode(FolderOverlayPacket.self, from: data.dropLast())
        XCTAssertEqual(packet.sources?.count, 2)
        context.resolve(.init(nonce: "test", kind: .result, id: packet.id))
        XCTAssertFalse(context.busy)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(acquired.count, 2)
        XCTAssertTrue(released.isEmpty, "Intake acknowledgement must keep grants alive for the persistent review")
        context.resolve(.init(nonce: "test", kind: .result, id: packet.id))
        context.releaseReview(try XCTUnwrap(packet.id)); context.releaseReview(try XCTUnwrap(packet.id))
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(released, acquired)
        context.acceptFilesForReview([URL(fileURLWithPath: "/tmp/c.txt")]) { result in
            if case .success = result { XCTFail("Pending review should fail on shutdown") }; completionCount += 1
        }
        context.shutdown(); context.shutdown()
        XCTAssertEqual(completionCount, 2)
        XCTAssertEqual(released, acquired, "Every acquired URL must be closed exactly once")
    }

    func testFramingPreservesUnicodeAndNewlinesAcrossPartialReads() throws {
        let input = Pipe(), output = Pipe()
        let channel = FolderOverlayPipe(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        defer { channel.close(); try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let done = expectation(description: "two complete packets")
        done.expectedFulfillmentCount = 2
        let source = "/tmp/자료/두 줄\n파일 \"이름\".txt"
        let first = FolderOverlayPacket(nonce: "one", kind: .drop, source: source)
        let second = FolderOverlayPacket(nonce: "two", kind: .dragging, dragging: false)
        var received: [FolderOverlayPacket] = []
        let lock = NSLock()
        channel.receive = { packet in lock.lock(); received.append(packet); lock.unlock(); done.fulfill() }
        channel.start()
        let frame = try FolderOverlayPipe.encode(first)
        try input.fileHandleForWriting.write(contentsOf: frame.prefix(frame.count / 2))
        var rest = Data(frame.dropFirst(frame.count / 2)); rest.append(try FolderOverlayPipe.encode(second))
        try input.fileHandleForWriting.write(contentsOf: rest)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(received.map(\.nonce), ["one", "two"])
        XCTAssertEqual(received.first?.source, source)
        XCTAssertEqual(received.last?.dragging, false)
    }

    func testMalformedAndOversizedFramesCloseWithoutDispatchingACommand() throws {
        for data in [Data("{broken}\n".utf8), Data(repeating: 65, count: FolderOverlayPipe.maximumPacketBytes + 1)] {
            let input = Pipe(), output = Pipe()
            let channel = FolderOverlayPipe(input: input.fileHandleForReading, output: output.fileHandleForWriting)
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let done = expectation(description: "invalid stream closed")
            channel.receive = { _ in XCTFail("Invalid bytes must not dispatch an operation") }
            channel.disconnected = { done.fulfill() }
            channel.start()
            DispatchQueue.global().async { try? input.fileHandleForWriting.write(contentsOf: data) }
            wait(for: [done], timeout: 3)
            channel.close(); try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
    }

    func testParentEOFIsObservedOnce() throws {
        let input = Pipe(), output = Pipe()
        let channel = FolderOverlayPipe(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let done = expectation(description: "EOF")
        done.assertForOverFulfill = true
        channel.disconnected = { done.fulfill() }
        channel.start(); try input.fileHandleForWriting.close()
        wait(for: [done], timeout: 3)
        channel.close(notify: true); try? output.fileHandleForReading.close()
    }
}
