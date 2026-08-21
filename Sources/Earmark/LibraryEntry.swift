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

    /// What is left to hear, at normal speed.
    var remaining: TimeInterval? {
        guard let duration = book.duration else { return nil }
        return max(0, duration - position)
    }

    /// How far through, as a percentage, for a listener rather than a machine.
    ///
    /// A title barely started reads as 1 rather than 0, because 0 says
    /// "untouched" and that would be wrong.
    var percentText: String? {
        guard let progress else { return nil }
        if progress <= 0 { return nil }
        return "\(max(1, Int(progress * 100)))%"
    }

    /// What is left, as hours and minutes.
    var remainingText: String? {
        guard let remaining, remaining > 0 else { return nil }
        return LibraryEntry.hoursAndMinutes(remaining)
    }

    /// A length as hours and minutes, which is how a listener judges a book.
    static func hoursAndMinutes(_ seconds: TimeInterval) -> String {
        let total = Int(seconds) / 60
        let hours = total / 60
        let minutes = total % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
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
