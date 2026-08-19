import XCTest
@testable import PhotoCuratorCore

final class LifecycleActionsTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        let dbURL = try makeTempDirectory().appendingPathComponent("test.sqlite")
        return try AppDatabase(path: dbURL)
    }

    func testMarkUnreviewedSendsAnAlreadyReviewedPhotoBackToNew() async throws {
        let database = try makeDatabase()
        let libraryId = try await database.write { db in try PhotoLibraryRepository.create(name: "Test", bookmarkData: Data(), now: 1, in: db).id! }
        let photoId = try await database.write { db in
            var photo = try PhotoRepository.upsertPhoto(libraryId: libraryId, basename: "IMG_0001", sourceDir: "", captureDate: nil, now: 1, in: db)
            photo.lifecycleState = .accepted
            try photo.update(db)
            return photo.id!
        }

        try await LifecycleActions.markUnreviewed(photoIds: [photoId], database: database)

        let state = try await database.read { db in try Photo.fetchOne(db, key: photoId)?.lifecycleState }
        XCTAssertEqual(state, .new)
    }
}
