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
