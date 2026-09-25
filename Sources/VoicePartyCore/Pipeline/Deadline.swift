import Foundation

/// Runs work with a hard deadline: the result, or nil once the time is up (or the work throws). The caller is
/// released at the deadline even when the work ignores cancellation (a stuck model or recognizer call); the
/// work is cancelled and its late result dropped.
public enum Deadline {
    public static func value<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        let first = FirstResult<T?>()
        return await withCheckedContinuation { continuation in
            first.continuation = continuation
            let job = Task { first.finish(try? await work()) }
            Task {
                try? await Task.sleep(for: limit)
                job.cancel()
                first.finish(nil)
            }
        }
    }
}
