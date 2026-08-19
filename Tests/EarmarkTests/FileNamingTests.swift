import Foundation
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
