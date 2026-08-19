import Foundation
import Testing
import AudibleKit
@testable import Earmark

@Suite("Library store")
struct LibraryStoreTests {

    static func makeBook(
        _ asin: String,
        title: String = "A Title",
        duration: TimeInterval? = 3600,
        finished: Bool = false,
        purchased: Date? = nil
    ) -> Book {
        Book(
            asin: asin,
            title: title,
            authors: ["Ada Marsh"],
            duration: duration,
            purchaseDate: purchased,
            isFinished: finished)
    }

    static func temporaryStore() -> LibraryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-test-\(UUID().uuidString).json")
        return LibraryStore(fileURL: url)
    }

    @Test("Merging adds titles the account holds")
    func mergeAddsBooks() async {
        let store = Self.temporaryStore()
        await store.merge([Self.makeBook("A"), Self.makeBook("B")])
        #expect(await store.entries.count == 2)
    }

    @Test("Merging keeps local state for a title already known")
    func mergeKeepsLocalState() async {
        let store = Self.temporaryStore()
        await store.merge([Self.makeBook("A")])
        await store.setFileName("Ada Marsh/A Title.m4b", for: "A")
        await store.setPosition(742, for: "A")
        await store.addBookmark(Bookmark(position: 100, note: "here"), to: "A")

        await store.merge([Self.makeBook("A", title: "A Retitled Book")])

        let entry = await store.entry("A")
        #expect(entry?.book.title == "A Retitled Book")
        #expect(entry?.fileName == "Ada Marsh/A Title.m4b")
        #expect(entry?.position == 742)
        #expect(entry?.bookmarks.count == 1)
    }

    @Test("Merging drops titles the account no longer holds")
    func mergeDropsRemovedBooks() async {
        let store = Self.temporaryStore()
        await store.merge([Self.makeBook("A"), Self.makeBook("B")])
        await store.merge([Self.makeBook("A")])
        #expect(await store.entry("B") == nil)
    }

    @Test("The library survives a save and reload")
    func persistsAcrossReload() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earmark-test-\(UUID().uuidString).json")
        let store = LibraryStore(fileURL: url)
        await store.merge([Self.makeBook("A")])
        await store.setPosition(512, for: "A")
        try await store.save()

        let reloaded = LibraryStore(fileURL: url)
        try await reloaded.load()
        #expect(await reloaded.entry("A")?.position == 512)
    }

    @Test("Loading with no saved file leaves an empty library")
    func loadsMissingFileQuietly() async throws {
        let store = LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("earmark-absent-\(UUID().uuidString).json"))
        try await store.load()
        #expect(await store.entries.isEmpty)
    }

    @Test("Newest purchase sorts first, and undated titles sort last")
    func sortsByPurchaseDate() async {
        let store = Self.temporaryStore()
        await store.merge([
            Self.makeBook("OLD", title: "Old", purchased: Date(timeIntervalSince1970: 1000)),
            Self.makeBook("NEW", title: "New", purchased: Date(timeIntervalSince1970: 9000)),
            Self.makeBook("NONE", title: "Undated", purchased: nil)
        ])
        let order = await store.sortedEntries.map(\.book.asin)
        #expect(order == ["NEW", "OLD", "NONE"])
    }

    // MARK: Position conflicts

    @Test("A later remote position moves the local one")
    func remotePositionWins() async {
        let store = Self.temporaryStore()
        await store.merge([Self.makeBook("A")])
        await store.setPosition(100, at: Date(timeIntervalSince1970: 1000), for: "A")

        let changed = await store.applyRemotePositions([
            "A": ListeningPosition(asin: "A", position: 900, recordedAt: Date())
        ])
        #expect(changed == ["A"])
        #expect(await store.entry("A")?.position == 900)
    }

    @Test("An older remote position never rewinds the local one")
    func staleRemotePositionIgnored() async {
        let store = Self.temporaryStore()
        await store.merge([Self.makeBook("A")])
        await store.setPosition(900, at: Date(), for: "A")

        let changed = await store.applyRemotePositions([
            "A": ListeningPosition(
                asin: "A", position: 100, recordedAt: Date(timeIntervalSince1970: 1000))
        ])
        #expect(changed.isEmpty)
        #expect(await store.entry("A")?.position == 900)
    }

    @Test("A position for a title not in the library is ignored")
    func ignoresUnknownTitles() async {
        let store = Self.temporaryStore()
        let changed = await store.applyRemotePositions([
            "GHOST": ListeningPosition(asin: "GHOST", position: 10, recordedAt: Date())
        ])
        #expect(changed.isEmpty)
    }
}
