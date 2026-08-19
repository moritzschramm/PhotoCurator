import Foundation

extension UndoManager {
    /// Registers a reversible pair of `async` closures under `actionName`.
    ///
    /// `registerUndo(withTarget:handler:)`'s handler is synchronous, but our actual
    /// mutation work is `async` (DB writes, file moves). Cocoa's undo/redo "ping-pong"
    /// (undoing an action re-registers it as a redo, and vice versa, indefinitely)
    /// only routes onto the correct stack if the re-registration happens
    /// *synchronously*, within the extent of the `undo()`/`redo()` call —
    /// `isUndoing`/`isRedoing` reverts to false the moment that call returns, so
    /// deferring the re-registration into a spawned `Task` would silently route it
    /// onto the wrong stack. This splits the two: the opposite-direction
    /// registration happens synchronously inside the handler, and only the actual
    /// mutation (whose completion timing has no bearing on stack bookkeeping) is
    /// deferred into a `Task`.
    ///
    /// `registerUndo(withTarget:handler:)` also requires an *open* undo group —
    /// normally opened automatically per user event by AppKit, but only for a
    /// document's own undo manager reached via the responder chain. This app has no
    /// `NSDocument`, so `AppEnvironment`'s `UndoManager` is a standalone instance
    /// AppKit doesn't know about and never opens a group on — without this explicit
    /// `beginUndoGrouping`/`endUndoGrouping` pair, every `registerUndo` call throws
    /// an uncaught `NSInternalInconsistencyException` ("must begin a group before
    /// registering undo"), which crashes the app since Swift can't catch it. Safe to
    /// nest: this also runs inside the recursive re-registration during an actual
    /// `undo()`/`redo()` replay, where Foundation has already opened its own group
    /// around invoking the stored handler — `UndoManager` groups nest freely.
    @MainActor
    public func registerReversiblePair<Target: AnyObject>(
        withTarget target: Target,
        actionName: String,
        undo: @escaping @MainActor @Sendable (Target) async -> Void,
        redo: @escaping @MainActor @Sendable (Target) async -> Void
    ) {
        beginUndoGrouping()
        registerUndo(withTarget: target) { [weak self] innerTarget in
            self?.registerReversiblePair(withTarget: innerTarget, actionName: actionName, undo: redo, redo: undo)
            Task { @MainActor in await undo(innerTarget) }
        }
        setActionName(actionName)
        endUndoGrouping()
    }
}
