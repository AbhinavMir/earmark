import Foundation
import AudibleKit

/// Everything Earmark remembers between launches.
///
/// The library is a few hundred entries at most, so it is held in memory and
/// written to one JSON file. Audio never goes in here; it stays as M4B files
/// in the audiobook folder, playable by anything.
actor LibraryStore {
    private(set) var entries: [String: LibraryEntry] = [:]
    private let fileURL: URL
    /// Set while a write is already scheduled, so a burst of position updates
    /// costs one write rather than one write each.
    private var writePending = false

    init(fileURL: URL = LibraryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("library.json")
    }

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Earmark", isDirectory: true)
    }

    /// Where decrypted audio is written. Readable by any other player.
    static var defaultAudioDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Audiobooks", isDirectory: true)
    }

    // MARK: Reading

    /// Entries in the order the interface shows them: newest purchase first.
    var sortedEntries: [LibraryEntry] {
        entries.values.sorted { left, right in
            switch (left.book.purchaseDate, right.book.purchaseDate) {
            case let (leftDate?, rightDate?): return leftDate > rightDate
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return left.book.title < right.book.title
            }
        }
    }

    func entry(_ asin: String) -> LibraryEntry? { entries[asin] }

    // MARK: Loading and saving

    func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let stored = try LibraryStore.decoder.decode([LibraryEntry].self, from: data)
        entries = Dictionary(uniqueKeysWithValues: stored.map { ($0.book.asin, $0) })
    }

    func save() throws {
        writePending = false
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try LibraryStore.encoder.encode(Array(entries.values))
        // Write beside the target and swap, so a crash mid-write cannot leave
        // a truncated library behind.
        let temporary = fileURL.appendingPathExtension("writing")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
    }

    /// Saves shortly, collapsing a burst of changes into one write.
    func saveSoon() {
        guard !writePending else { return }
        writePending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            try? await self?.save()
        }
    }

    /// Writes the library. A value that JSON cannot hold becomes text rather
    /// than stopping the whole file being written.
    ///
    /// Nothing should reach this: values are checked on the way in. It is here
    /// so that one bad number can never cost a library.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()

    // MARK: Updating

    /// Merges a freshly fetched library, keeping local state for titles that
    /// are already known and dropping titles the account no longer holds.
    func merge(_ books: [Book]) {
        var merged: [String: LibraryEntry] = [:]
        for book in books.map(LibraryStore.storable) {
            if var existing = entries[book.asin] {
                existing = LibraryEntry(
                    book: book,
                    fileName: existing.fileName,
                    position: existing.position,
                    positionRecordedAt: existing.positionRecordedAt,
                    chapters: existing.chapters,
                    bookmarks: existing.bookmarks)
                merged[book.asin] = existing
            } else {
                merged[book.asin] = LibraryEntry(book: book)
            }
        }
        entries = merged
    }

    func setFileName(_ fileName: String?, for asin: String) {
        entries[asin]?.fileName = fileName
        saveSoon()
    }

    func setChapters(_ chapters: [Chapter], for asin: String) {
        entries[asin]?.chapters = chapters.filter {
            $0.start.isFinite && $0.duration.isFinite
        }
        saveSoon()
    }

    /// A book whose figures can all be written.
    static func storable(_ book: Book) -> Book {
        guard let duration = book.duration, !duration.isFinite else { return book }
        return Book(
            asin: book.asin, title: book.title, subtitle: book.subtitle,
            authors: book.authors, narrators: book.narrators, series: book.series,
            publisher: book.publisher, duration: nil, releaseDate: book.releaseDate,
            coverURL: book.coverURL, purchaseDate: book.purchaseDate,
            isFinished: book.isFinished)
    }

    func setPosition(_ position: TimeInterval, at date: Date = Date(), for asin: String) {
        // JSON has no way to write a value that is not a number, so one stored
        // here would make every later save fail, and the failure is not shown
        // to anybody. Nothing that cannot be written is allowed in.
        entries[asin]?.position = LibraryStore.storable(position)
        entries[asin]?.positionRecordedAt = date
        saveSoon()
    }

    /// A number that can be written to the file, or zero.
    static func storable(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, !value.isNaN else { return 0 }
        return max(0, min(value, 60 * 60 * 24 * 30))
    }

    func addBookmark(_ bookmark: Bookmark, to asin: String) {
        let safe = Bookmark(
            id: bookmark.id,
            position: LibraryStore.storable(bookmark.position),
            note: bookmark.note,
            createdAt: bookmark.createdAt)
        entries[asin]?.bookmarks.append(safe)
        saveSoon()
    }

    func removeBookmark(_ id: UUID, from asin: String) {
        entries[asin]?.bookmarks.removeAll { $0.id == id }
        saveSoon()
    }

    /// Applies positions fetched from Audible, keeping whichever side is the
    /// authority for each title.
    func applyRemotePositions(_ remote: [String: ListeningPosition]) -> [String] {
        var changed: [String] = []
        for (asin, remotePosition) in remote {
            guard var entry = entries[asin] else { continue }
            let winner = PositionService.resolve(
                local: entry.listeningPosition, remote: remotePosition)
            guard let winner, winner.position != entry.position else { continue }
            entry.position = winner.position
            entry.positionRecordedAt = winner.recordedAt
            entries[asin] = entry
            changed.append(asin)
        }
        if !changed.isEmpty { saveSoon() }
        return changed
    }
}
