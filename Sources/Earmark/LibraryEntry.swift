import Foundation
import AudibleKit

/// One title as Earmark holds it: what Audible said, plus what this Mac knows.
struct LibraryEntry: Codable, Identifiable, Hashable, Sendable {
    let book: Book
    /// Where the decrypted file lives, once it exists.
    var fileName: String?
    /// Where the listener stopped on this Mac.
    var position: TimeInterval
    /// When that position was recorded here.
    var positionRecordedAt: Date?
    /// Chapters, kept from the license so the player need not re-read them.
    var chapters: [Chapter]
    var bookmarks: [Bookmark]

    var id: String { book.asin }
    var isDownloaded: Bool { fileName != nil }

    init(
        book: Book,
        fileName: String? = nil,
        position: TimeInterval = 0,
        positionRecordedAt: Date? = nil,
        chapters: [Chapter] = [],
        bookmarks: [Bookmark] = []
    ) {
        self.book = book
        self.fileName = fileName
        self.position = position
        self.positionRecordedAt = positionRecordedAt
        self.chapters = chapters
        self.bookmarks = bookmarks
    }

    /// How much of the title has been heard, from 0 to 1.
    ///
    /// Nil while the length is unknown, so the interface can show nothing
    /// rather than a bar at zero.
    var progress: Double? {
        guard let duration = book.duration, duration > 0 else { return nil }
        return min(1, position / duration)
    }

    /// True once the listener is past the start but short of the end.
    var isInProgress: Bool {
        guard let progress else { return position > 0 }
        return progress > 0.001 && progress < 0.98 && !book.isFinished
    }

    var isFinished: Bool {
        book.isFinished || (progress ?? 0) >= 0.98
    }

    /// This entry's position as the sync service exchanges it.
    var listeningPosition: ListeningPosition? {
        guard let positionRecordedAt else { return nil }
        return ListeningPosition(
            asin: book.asin, position: position, recordedAt: positionRecordedAt)
    }
}

/// A place the listener marked, with an optional note.
struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let position: TimeInterval
    var note: String
    let createdAt: Date

    init(id: UUID = UUID(), position: TimeInterval, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.position = position
        self.note = note
        self.createdAt = createdAt
    }
}
