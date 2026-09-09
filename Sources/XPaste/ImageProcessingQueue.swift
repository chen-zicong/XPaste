import Foundation

/// One worker owns image processing from decode through encoding and hashing.
/// Limits include the running job, not just waiting jobs. Rejected submissions
/// are never retained by the queue.
actor ImageProcessingQueue {
    private struct Job {
        let id: UUID
        let byteCount: Int
        let operation: @Sendable () async throws -> ProcessedImage
        let continuation: CheckedContinuation<ProcessedImage, Error>
    }

    private let maxBytes: Int
    private let maxJobs: Int
    private var reservedBytes = 0
    private var jobCount = 0
    private var pending: [Job] = []
    private var isRunning = false

    var outstandingJobs: Int { jobCount }

    init(maxBytes: Int = 128 * 1_024 * 1_024, maxJobs: Int = 4) {
        self.maxBytes = max(0, maxBytes)
        self.maxJobs = max(1, maxJobs)
    }

    func run(
        byteCount: Int,
        operation: @escaping @Sendable () async throws -> ProcessedImage
    ) async throws -> ProcessedImage {
        try Task.checkCancellation()
        guard byteCount >= 0, byteCount <= maxBytes - reservedBytes,
              jobCount < maxJobs else { throw ImageProcessingError.queueFull }
        let id = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reservedBytes += byteCount
                jobCount += 1
                pending.append(Job(id: id, byteCount: byteCount, operation: operation, continuation: continuation))
                if !isRunning {
                    isRunning = true
                    Task { await drain() }
                }
            }
        } onCancel: {
            Task { await self.cancelPending(id) }
        }
        try Task.checkCancellation()
        return result
    }

    private func drain() async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            let result: Result<ProcessedImage, Error>
            do { result = .success(try await job.operation()) }
            catch { result = .failure(error) }
            reservedBytes -= job.byteCount
            jobCount -= 1
            job.continuation.resume(with: result)
        }
        isRunning = false
    }

    private func cancelPending(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let job = pending.remove(at: index)
        reservedBytes -= job.byteCount
        jobCount -= 1
        job.continuation.resume(throwing: CancellationError())
    }
}
