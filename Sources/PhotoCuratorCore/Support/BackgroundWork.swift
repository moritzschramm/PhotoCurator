import Foundation

/// Runs blocking, CPU- or IO-bound work off Swift Concurrency's cooperative thread
/// pool.
///
/// The pool sizes itself to the core count and assumes tasks yield promptly; hashing
/// a 60 MB RAW or decoding a thumbnail does neither. Several of those running at once
/// (the derivation backlog alone allows four) can occupy most of the pool, stalling
/// every unrelated `await` in the app — including the database observations that
/// drive the UI. Handing that work to a dedicated queue keeps the pool free for
/// actual concurrency.
enum BackgroundWork {
    private static let queue = DispatchQueue(
        label: "com.photocurator.background-work",
        qos: .utility,
        attributes: .concurrent
    )

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
