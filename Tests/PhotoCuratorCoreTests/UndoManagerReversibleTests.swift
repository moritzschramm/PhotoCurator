import XCTest
@testable import PhotoCuratorCore

/// Exercises `registerReversiblePair` in isolation, with no `AppEnvironment`/AppKit
/// involved — this is the highest-risk logic in the undo/redo feature (the
/// synchronous-vs-deferred registration timing that keeps undo/redo "ping-pong"
/// routing onto the correct stack), so it's worth verifying on its own.
@MainActor
final class UndoManagerReversibleTests: XCTestCase {
    /// A plain reference type to serve as `registerUndo`'s weakly-held target —
    /// `UndoManager` requires a real object, not a closure capture alone.
    final class Counter {
        var undoCount = 0
        var redoCount = 0
    }

    /// The actual mutation is dispatched into a detached `Task` by
    /// `registerReversiblePair`, so its effect isn't guaranteed visible the instant
    /// `undo()`/`redo()` returns — polls briefly rather than assuming synchronous
    /// completion or mixing in `XCTestExpectation` (which would need a fresh
    /// expectation per closure invocation, awkward for a closure reused across
    /// repeated undo/redo cycles).
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition did not become true within \(timeout)s")
    }

    func testUndoThenRedoInvokesTheExpectedClosures() async throws {
        let undoManager = UndoManager()
        let counter = Counter()

        undoManager.registerReversiblePair(
            withTarget: counter,
            actionName: "Test Action",
            undo: { target in target.undoCount += 1 },
            redo: { target in target.redoCount += 1 }
        )

        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)

        undoManager.undo()
        try await waitUntil { counter.undoCount == 1 }
        XCTAssertEqual(counter.redoCount, 0)
        XCTAssertFalse(undoManager.canUndo, "the pair should have moved to the redo stack")
        XCTAssertTrue(undoManager.canRedo)

        // Redo must invoke the *original* redo closure, not the undo closure again —
        // this is exactly what the synchronous re-registration inside the handler is
        // responsible for getting right.
        undoManager.redo()
        try await waitUntil { counter.redoCount == 1 }
        XCTAssertTrue(undoManager.canUndo, "redo should have re-registered an undo")
        XCTAssertFalse(undoManager.canRedo)

        undoManager.undo()
        try await waitUntil { counter.undoCount == 2 }
    }

    func testActionNameIsSetForMenuTitles() {
        let undoManager = UndoManager()
        let counter = Counter()
        undoManager.registerReversiblePair(
            withTarget: counter, actionName: "Mark Accepted", undo: { _ in }, redo: { _ in }
        )
        XCTAssertTrue(undoManager.undoMenuItemTitle.contains("Mark Accepted"))
    }
}
