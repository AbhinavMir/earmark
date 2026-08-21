import Foundation
import Testing
import AudibleKit
@testable import Earmark

/// Drives the queue and the store the way a restless person would.
@Suite("Fuzzing the queue and the store")
@MainActor
struct StateFuzzTests {

    static func entry(_ n: Int, downloaded: Bool = false) -> LibraryEntry {
        LibraryEntry(
            book: Book(asin: String(format: "B%05d", n), title: "Title \(n)",
                       authors: ["Ada Marsh"], duration: 3600),
            fileName: downloaded ? "Ada Marsh/Title \(n).m4b" : nil)
    }

    static func makeQueue() -> DownloadQueue {
        DownloadQueue(store: LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fuzz-\(UUID().uuidString).json")))
    }

    @Test("Any order of queue actions leaves it consistent", arguments: [1 as UInt64, 42, 777])
    func queueActionsInAnyOrder(seed: UInt64) {
        var state = seed | 1
        func roll(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }

        let queue = Self.makeQueue()
        let entries = (0..<25).map { Self.entry($0, downloaded: $0 % 7 == 0) }

        for _ in 0..<400 {
            let target = entries[roll(entries.count)]
            switch roll(6) {
            case 0: queue.enqueue([target])
            case 1: queue.enqueue([target], quietly: true)
            case 2: queue.cancel(target.id)
            case 3: queue.retry(target.id)
            case 4: queue.clearCompleted()
            default: queue.enqueue(entries.filter { _ in roll(3) == 0 })
            }

            // A title never appears twice, whatever the order of actions.
            let ids = queue.jobs.map(\.asin)
            #expect(Set(ids).count == ids.count)
            // Nothing already downloaded is ever queued.
            for job in queue.jobs {
                let entry = entries.first { $0.id == job.asin }
                #expect(entry?.isDownloaded != true)
            }
            #expect(queue.visibleActiveCount <= queue.jobs.count)
        }
    }

    @Test("Merging in any order keeps one entry per title", arguments: [3 as UInt64, 31])
    func mergeKeepsOneEntryPerTitle(seed: UInt64) async {
        var state = seed | 1
        func roll(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }

        let store = LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fuzz-\(UUID().uuidString).json"))

        for _ in 0..<60 {
            // A page that repeats a title, which the server has been known to do.
            let books = (0..<roll(12)).flatMap { index -> [Book] in
                let book = Book(
                    asin: String(format: "B%05d", roll(8)),
                    title: "Title \(index)",
                    duration: TimeInterval(roll(100_000)))
                return roll(4) == 0 ? [book, book] : [book]
            }
            await store.merge(books)

            let asins = await store.sortedEntries.map(\.book.asin)
            #expect(Set(asins).count == asins.count)

            for asin in asins where roll(2) == 0 {
                await store.setPosition(TimeInterval(roll(200_000)), for: asin)
            }
            _ = await store.sortedEntries.map(\.progress)
        }
    }

    @Test("Positions arriving in any order never move a place backwards in time")
    func remotePositionsNeverRewindNewerLocalOnes() async {
        let store = LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fuzz-\(UUID().uuidString).json"))
        await store.merge([Book(asin: "A", title: "T", duration: 10_000)])

        let now = Date()
        await store.setPosition(5_000, at: now, for: "A")

        // Everything older must lose, whatever position it carries.
        for offset in [-1.0, -60, -3_600, -86_400] {
            let stale = ListeningPosition(
                asin: "A", position: 9_999, recordedAt: now.addingTimeInterval(offset))
            _ = await store.applyRemotePositions(["A": stale])
            #expect(await store.entry("A")?.position == 5_000)
        }
    }

    @Test("A cover cache handles files that are not images")
    func coverCacheHandlesRubbish() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-covers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = CoverCache(directory: dir)
        for (index, body) in [Data(), Data("not an image".utf8),
                              Data([0xFF, 0xD8, 0xFF]), Data(repeating: 0, count: 4096)].enumerated() {
            let asin = "B\(index)"
            try body.write(to: dir.appendingPathComponent("\(asin).img"))
            // A damaged file yields no image, and does not end the process.
            _ = await cache.image(for: asin, url: nil)
        }
    }

    @Test("Seeking anywhere at all leaves the player usable")
    func seekAnywhere() {
        let player = Player()
        for target in [-1e9, -1, 0, 0.5, 1e9, .infinity, -.infinity, .nan] as [TimeInterval] {
            player.seek(to: target)
            #expect(player.position.isFinite)
        }
    }
}

/// Hammers the pieces the interface touches from several places at once.
@Suite("Fuzzing the application under load")
struct AppConcurrencyFuzzTests {

    @Test("A store written from everywhere at once keeps one entry per title")
    func storeUnderLoad() async {
        let store = LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("load-\(UUID().uuidString).json"))
        await store.merge((0..<40).map {
            Book(asin: "B\($0)", title: "Title \($0)", duration: 3600)
        })

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<120 {
                group.addTask {
                    let asin = "B\(index % 40)"
                    switch index % 5 {
                    case 0: await store.setPosition(TimeInterval(index * 7), for: asin)
                    case 1: await store.setFileName("Ada/\(asin).m4b", for: asin)
                    case 2: await store.addBookmark(Bookmark(position: 12), to: asin)
                    case 3: _ = await store.applyRemotePositions([
                        asin: ListeningPosition(
                            asin: asin, position: TimeInterval(index), recordedAt: Date())
                    ])
                    default: _ = await store.sortedEntries
                    }
                }
            }
        }

        let entries = await store.sortedEntries
        #expect(entries.count == 40)
        #expect(Set(entries.map(\.book.asin)).count == 40)
        for entry in entries {
            #expect(entry.position.isFinite)
            #expect(entry.position >= 0)
        }
    }

    @Test("Saving while writing leaves a file that reads back")
    func savingUnderLoad() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        await store.merge((0..<30).map { Book(asin: "B\($0)", title: "T\($0)") })

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<60 {
                group.addTask {
                    await store.setPosition(TimeInterval(index), for: "B\(index % 30)")
                    if index % 10 == 0 { try? await store.save() }
                }
            }
        }
        try await store.save()

        // Whatever order the writes landed in, the file must be whole.
        let reloaded = LibraryStore(fileURL: url)
        try await reloaded.load()
        #expect(await reloaded.entries.count == 30)
    }

    @Test("The player survives every order of transport calls")
    @MainActor
    func playerTransportInAnyOrder() {
        let player = Player()
        var state: UInt64 = 12345
        func roll(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }

        for _ in 0..<300 {
            switch roll(9) {
            case 0: player.play()
            case 1: player.pause()
            case 2: player.togglePlayPause()
            case 3: player.skipAhead()
            case 4: player.skipBack()
            case 5: player.nextChapter()
            case 6: player.previousChapter()
            case 7: player.seek(to: TimeInterval(roll(100_000)) - 50_000)
            default: player.unload()
            }
            #expect(player.position.isFinite)
            #expect(player.duration.isFinite)
            #expect(player.effects.rate.isFinite)
        }
    }

    @Test("Sound settings can be changed in any order while nothing plays")
    @MainActor
    func effectsInAnyOrder() {
        let player = Player()
        for value in [Float(0.5), 3.0, 1.0, -1, 1e9, 0.75] {
            player.effects.rate = value
            player.effects.pitch = value * 100
            player.effects.bass = value
            player.rate = value
            #expect(player.effects.rate == value)
        }
        player.effects = .flat
        #expect(player.effects.isFlat)
    }
}
