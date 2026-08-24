import Foundation

/// Holds a long-lived `Task` so it can be cancelled from `deinit`.
///
/// A `@MainActor` type can't reference its own isolated stored properties from
/// `deinit`, which is nonisolated — so a store that owns a database observation has no
/// way to cancel it on the way out, and the observation simply keeps running (and
/// re-querying on every write) for the rest of the session. Keeping the handle in an
/// immutable `let` box sidesteps that: `deinit` may read the box, and cancelling
/// through it is safe from any isolation.
final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// Installs `newTask`, cancelling whatever it replaces.
    func replace(with newTask: Task<Void, Never>?) {
        lock.lock()
        let previous = task
        task = newTask
        lock.unlock()
        previous?.cancel()
    }

    func cancel() {
        replace(with: nil)
    }
}
