import Foundation
import AppKit
import SwiftUI
import Testing
import AudibleKit
@testable import Earmark

@Suite("File naming and filters")
struct FileNamingTests {

    @Test("A downloaded file is filed under its author")
    func filesUnderAuthor() {
        let book = Book(asin: "A", title: "The Long Walk Home", authors: ["Ada Marsh"])
        #expect(DownloadQueue.fileName(for: book) == "Ada Marsh/The Long Walk Home.m4b")
    }

    @Test("A series title carries its number so the folder sorts")
    func includesSeriesPosition() {
        let book = Book(
            asin: "A",
            title: "Second Light",
            authors: ["Ada Marsh"],
            series: SeriesEntry(asin: "S", name: "Wayfarer", position: "2"))
        #expect(DownloadQueue.fileName(for: book) == "Ada Marsh/2 - Second Light.m4b")
    }

    @Test("Characters a file name cannot hold are replaced")
    func stripsIllegalCharacters() {
        let book = Book(asin: "A", title: "What/Now: A Story?", authors: ["Ada: Marsh"])
        let name = DownloadQueue.fileName(for: book)
        #expect(!name.dropFirst().contains(":"))
        #expect(name.hasSuffix(".m4b"))
        #expect(name.hasPrefix("Ada-Marsh/"))
        #expect(name.contains("What-Now-A Story"))
    }

    @Test("A title with no author still gets a folder")
    func handlesMissingAuthor() {
        let book = Book(asin: "A", title: "Anonymous Work")
        #expect(DownloadQueue.fileName(for: book) == "Unknown Author/Anonymous Work.m4b")
    }

    @Test("A name that reduces to nothing becomes Untitled")
    func neverProducesAnEmptyName() {
        #expect("///".fileSafe == "Untitled")
    }

    // MARK: Filters

    @Test("Each sidebar filter selects what its name says")
    func filtersMatch() {
        let downloaded = LibraryEntry(
            book: Book(asin: "A", title: "T", duration: 3600),
            fileName: "x.m4b", position: 1800)
        let untouched = LibraryEntry(book: Book(asin: "B", title: "U", duration: 3600))
        let done = LibraryEntry(
            book: Book(asin: "C", title: "V", duration: 3600, isFinished: true))

        #expect(LibraryFilter.all.matches(untouched))
        #expect(LibraryFilter.downloaded.matches(downloaded))
        #expect(!LibraryFilter.downloaded.matches(untouched))
        #expect(LibraryFilter.inProgress.matches(downloaded))
        #expect(!LibraryFilter.inProgress.matches(untouched))
        #expect(LibraryFilter.finished.matches(done))
    }

    @Test("A series filter selects only that series")
    func seriesFilter() {
        let inSeries = LibraryEntry(book: Book(
            asin: "A", title: "T",
            series: SeriesEntry(asin: "S", name: "Wayfarer", position: "1")))
        let outside = LibraryEntry(book: Book(asin: "B", title: "U"))
        #expect(LibraryFilter.series("Wayfarer").matches(inSeries))
        #expect(!LibraryFilter.series("Wayfarer").matches(outside))
    }

    @Test("Download states report whether work is still going on")
    func stateActivity() {
        #expect(DownloadState.queued.isActive)
        #expect(DownloadState.downloading(fraction: 0.5).isActive)
        #expect(!DownloadState.done.isActive)
        #expect(!DownloadState.failed("no").isActive)
        #expect(DownloadState.downloading(fraction: 0.42).label == "Downloading 42%")
        #expect(DownloadState.failed("Not entitled").label == "Not entitled")
    }
}

@Suite("Download queue")
@MainActor
struct DownloadQueueTests {

    static func entry(_ asin: String, downloaded: Bool = false) -> LibraryEntry {
        LibraryEntry(
            book: Book(asin: asin, title: "Title \(asin)", authors: ["Ada Marsh"]),
            fileName: downloaded ? "Ada Marsh/Title.m4b" : nil)
    }

    @Test("Enqueuing more titles than the limit does not spin")
    func enqueueManyTerminates() {
        // Before the fix, a started job stayed queued, so the starter chose it
        // again on every pass and recursed until the stack ran out.
        let queue = DownloadQueue(store: LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("queue-test-\(UUID().uuidString).json")))
        queue.enqueue((1...50).map { Self.entry(String(format: "B%04d", $0)) })

        #expect(queue.jobs.count == 50)
        #expect(queue.jobs.filter { $0.state == .queued }.count == 48)
    }

    @Test("A title already downloaded is not queued again")
    func skipsDownloadedTitles() {
        let queue = DownloadQueue(store: LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("queue-test-\(UUID().uuidString).json")))
        queue.enqueue([Self.entry("A", downloaded: true)])
        #expect(queue.jobs.isEmpty)
    }

    @Test("Enqueuing the same title twice queues it once")
    func doesNotDuplicate() {
        let queue = DownloadQueue(store: LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("queue-test-\(UUID().uuidString).json")))
        queue.enqueue([Self.entry("A")])
        queue.enqueue([Self.entry("A")])
        #expect(queue.jobs.count == 1)
    }
}

@Suite("Quiet downloads")
@MainActor
struct QuietDownloadTests {

    static func makeQueue() -> DownloadQueue {
        DownloadQueue(store: LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("quiet-\(UUID().uuidString).json")))
    }

    static func entry(_ asin: String) -> LibraryEntry {
        LibraryEntry(book: Book(asin: asin, title: "Title \(asin)", authors: ["Ada Marsh"]))
    }

    @Test("A download that follows a stream stays out of the count")
    func quietJobsAreNotCounted() {
        let queue = Self.makeQueue()
        queue.enqueue([Self.entry("A")], quietly: true)
        #expect(queue.jobs.count == 1)
        #expect(queue.visibleActiveCount == 0)
    }

    @Test("A download somebody asked for is counted")
    func requestedJobsAreCounted() {
        let queue = Self.makeQueue()
        queue.enqueue([Self.entry("A")])
        #expect(queue.visibleActiveCount == 1)
    }

    @Test("A quiet job still appears in the queue list")
    func quietJobsAreStillVisibleInTheQueue() {
        // Quiet means unannounced, not hidden. Somebody looking at the queue
        // should still see what is using the network.
        let queue = Self.makeQueue()
        queue.enqueue([Self.entry("A")], quietly: true)
        #expect(queue.jobs.first?.isQuiet == true)
        #expect(queue.jobs.first?.title == "Title A")
    }
}


@Suite("Cover placeholder")
struct CoverPlaceholderTests {

    @Test("A title always gets the same colour")
    func hueIsStable() {
        // A card that changed colour on every redraw would be worse than a
        // blank one.
        #expect(CoverPalette.hue(for: "B0TEST0001") == CoverPalette.hue(for: "B0TEST0001"))
    }

    @Test("Different titles get different colours")
    func huesDiffer() {
        #expect(CoverPalette.hue(for: "B0TEST0001") != CoverPalette.hue(for: "B0TEST0002"))
    }

    @Test("Every colour is a usable hue")
    func hueIsInRange() {
        for asin in ["A", "B0TEST0001", "1508280282", ""] {
            let hue = CoverPalette.hue(for: asin)
            #expect(hue >= 0 && hue < 1)
        }
    }
}

@Suite("Cover cache")
struct CoverCacheTests {

    static func temporaryCache() -> (CoverCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-\(UUID().uuidString)", isDirectory: true)
        return (CoverCache(directory: dir), dir)
    }

    @Test("A title with no cached cover reports as missing")
    func reportsMissing() async {
        let (cache, _) = Self.temporaryCache()
        #expect(await cache.isCached("B0TEST0001") == false)
        #expect(await cache.cachedCount(of: ["A", "B"]) == 0)
    }

    @Test("A title with no cover URL yields no image and does not fail")
    func handlesMissingURL() async {
        let (cache, _) = Self.temporaryCache()
        #expect(await cache.image(for: "B0TEST0001", url: nil) == nil)
    }

    @Test("A cover written to disk is found again")
    func readsFromDisk() async throws {
        let (cache, dir) = Self.temporaryCache()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A single pixel, written as bytes rather than drawn, so the test
        // needs neither a network nor a screen.
        let pixel = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        try pixel.write(to: dir.appendingPathComponent("B0TEST0001.img"))

        #expect(await cache.isCached("B0TEST0001"))
        #expect(await cache.image(for: "B0TEST0001", url: nil) != nil)
        #expect(await cache.cachedCount(of: ["B0TEST0001", "B0TEST0002"]) == 1)
    }

}
