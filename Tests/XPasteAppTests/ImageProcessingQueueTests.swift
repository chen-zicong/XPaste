import XCTest
import XPasteCore
@testable import XPaste

final class ImageProcessingQueueTests: XCTestCase {
    func testFIFOAndCancellationReleaseCapacityWithoutOverlappingWork() async throws {
        let queue = ImageProcessingQueue(maxBytes: 10, maxJobs: 3)
        let gate = ImageGate()
        let first = Task { try await queue.run(byteCount: 6) { await gate.process(1) } }
        try await waitUntil { await gate.started == [1] }
        let cancelled = Task { try await queue.run(byteCount: 4) { await gate.process(2) } }
        try await waitUntil { await queue.outstandingJobs == 2 }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled job succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let third = Task { try await queue.run(byteCount: 4) { await gate.process(3) } }
        try await waitUntil { await queue.outstandingJobs == 2 }
        let before = await gate.started
        XCTAssertEqual(before, [1])
        await gate.release(1)
        _ = try await first.value
        try await waitUntil { await gate.started == [1, 3] }
        await gate.release(3)
        _ = try await third.value
        let remaining = await queue.outstandingJobs
        XCTAssertEqual(remaining, 0)
    }

    func testByteAndJobBudgetsIncludeRunningJobAndRecoverAfterFailure() async throws {
        let queue = ImageProcessingQueue(maxBytes: 10, maxJobs: 2)
        let gate = ImageGate()
        let first = Task { try await queue.run(byteCount: 6) { await gate.process(1) } }
        try await waitUntil { await gate.started == [1] }
        do {
            _ = try await queue.run(byteCount: 5) { XCTFail("Oversized job ran"); return Self.result() }
            XCTFail("Expected byte limit")
        } catch ImageProcessingError.queueFull {} catch { XCTFail("Unexpected error: \(error)") }
        let failing = Task {
            try await queue.run(byteCount: 4) { throw ImageProcessingError.unreadable }
        }
        try await waitUntil { await queue.outstandingJobs == 2 }
        do {
            _ = try await queue.run(byteCount: 0) { XCTFail("Excess job ran"); return Self.result() }
            XCTFail("Expected job limit")
        } catch ImageProcessingError.queueFull {} catch { XCTFail("Unexpected error: \(error)") }
        await gate.release(1)
        _ = try await first.value
        do { _ = try await failing.value; XCTFail("Expected worker failure") }
        catch ImageProcessingError.unreadable {} catch { XCTFail("Unexpected error: \(error)") }
        _ = try await queue.run(byteCount: 10) { Self.result() }
        let remaining = await queue.outstandingJobs
        XCTAssertEqual(remaining, 0)
    }

    func testPNGBytesAndBackgroundHashArePreserved() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5WQAAAAASUVORK5CYII="))
        let processed = try await ImageProcessor.process(png)
        XCTAssertEqual(processed.pngData, png)
        XCTAssertEqual(processed.contentHash, ContentHasher.data(png))
        XCTAssertEqual(processed.pixelWidth, 1)
        XCTAssertFalse(processed.thumbnailData.isEmpty)
        let edited = try await ImageProcessor.edit(png, operations: [.rotateRight])
        XCTAssertEqual(edited.contentHash, ContentHasher.data(edited.pngData))
    }

    fileprivate static func result() -> ProcessedImage {
        ProcessedImage(pngData: Data(), thumbnailData: Data(), pixelWidth: 1, pixelHeight: 1)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for queue")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor ImageGate {
    private(set) var started: [Int] = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func process(_ id: Int) async -> ProcessedImage {
        started.append(id)
        await withCheckedContinuation { waiters[id] = $0 }
        return ImageProcessingQueueTests.result()
    }

    func release(_ id: Int) { waiters.removeValue(forKey: id)?.resume() }
}
