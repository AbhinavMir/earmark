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
        let stored = try JSONDecoder().decode([LibraryEntry].self, from: data)
        entries = Dictionary(uniqueKeysWithValues: stored.map { ($0.book.asin, $0) })
    }

    func save() throws {
        writePending = false
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(entries.values))
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

    // MARK: Updating

    /// Merges a freshly fetched library, keeping local state for titles that
    /// are already known and dropping titles the account no longer holds.
    func merge(_ books: [Book]) {
        var merged: [String: LibraryEntry] = [:]
        for book in books {
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
        entries[asin]?.chapters = chapters
        saveSoon()
    }

    func setPosition(_ position: TimeInterval, at date: Date = Date(), for asin: String) {
        entries[asin]?.position = position
        entries[asin]?.positionRecordedAt = date
        saveSoon()
    }

    func addBookmark(_ bookmark: Bookmark, to asin: String) {
        entries[asin]?.bookmarks.append(bookmark)
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
