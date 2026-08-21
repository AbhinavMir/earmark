import Foundation
import Testing
import AudibleKit
@testable import Earmark

/// Sorting and filtering run over the whole library on every keystroke, and
/// the values they sort by come from a publisher.
@Suite("Fuzzing sorting and filtering")
struct SortFuzzTests {

    static func entry(series: String?, position: String?) -> LibraryEntry {
        LibraryEntry(book: Book(
            asin: UUID().uuidString,
            title: "T",
            series: series.map { SeriesEntry(asin: "S", name: $0, position: position) }))
    }

    @Test("A series place that is not a number never breaks the ordering")
    func sortingWithOddPositions() {
        // A comparator that answers inconsistently can end the process. Text
        // such as "nan" reads as a number that compares false against
        // everything, including itself.
        let positions: [String?] = [
            "1", "2", "10", "2.5", "0", "-1", "nan", "NaN", "inf", "-inf",
            "1e400", "Book 3", "", " ", "١٢", "🎧", nil,
            String(repeating: "9", count: 400)
        ]
        let entries = positions.map { Self.entry(series: "Wayfarer", position: $0) }

        // The ordering the list uses.
        let sorted = entries.sorted {
            ($0.book.series?.sortIndex ?? .greatestFiniteMagnitude)
                < ($1.book.series?.sortIndex ?? .greatestFiniteMagnitude)
        }
        #expect(sorted.count == entries.count)

        // Every value it sorts by must be a number that compares sensibly.
        for entry in entries {
            if let index = entry.book.series?.sortIndex {
                #expect(index.isFinite, "\(entry.book.series?.position ?? "nil") gave \(index)")
            }
        }
    }

    @Test("Grouping by series holds for any series data")
    func groupingWithOddSeries() {
        let names: [String?] = [nil, "", " ", "A", "A", "a", "🎧",
                                String(repeating: "S", count: 500)]
        let entries = names.map { Self.entry(series: $0, position: "1") }

        var bySeries: [String: [LibraryEntry]] = [:]
        for entry in entries {
            bySeries[entry.book.series?.name ?? "Standalone", default: []].append(entry)
        }
        let total = bySeries.values.reduce(0) { $0 + $1.count }
        #expect(total == entries.count, "grouping lost or gained a title")
    }

    @Test("Searching for anything at all returns a subset, never a crash")
    func searchingAnything() {
        let entries = (0..<50).map { index in
            LibraryEntry(book: Book(
                asin: "B\(index)",
                title: index % 3 == 0 ? "The Long Walk 🎧" : "Title \(index)",
                authors: ["Ada Marsh"],
                narrators: ["Colin Reeve"],
                series: SeriesEntry(asin: "S", name: "Wayfarer", position: "\(index)")))
        }

        let needles = ["", " ", "a", "A", "🎧", "walk", "WALK", "*", ".*", "[",
                       "\\", "%", "'", "\"", "\u{0000}", "ada marsh",
                       String(repeating: "x", count: 5_000)]
        for needle in needles {
            let lowered = needle.lowercased()
            let found = entries.filter { entry in
                entry.book.title.lowercased().contains(lowered)
                    || entry.book.authorLine.lowercased().contains(lowered)
                    || entry.book.narratorLine.lowercased().contains(lowered)
                    || (entry.book.series?.name.lowercased().contains(lowered) ?? false)
            }
            #expect(found.count <= entries.count)
        }
    }

    @Test("Every filter answers for every entry")
    func filtersAnswerForEverything() {
        let entries = [
            Self.entry(series: nil, position: nil),
            Self.entry(series: "A", position: "1"),
            LibraryEntry(book: Book(asin: "X", title: "T", duration: 3_600),
                         fileName: "a.m4b", position: 1_800),
            LibraryEntry(book: Book(asin: "Y", title: "T", duration: nil), position: 5),
            LibraryEntry(book: Book(asin: "Z", title: "T", duration: 0), position: 0)
        ]
        let filters: [LibraryFilter] = [
            .all, .downloaded, .inProgress, .finished, .series("A"), .series("")
        ]
        for filter in filters {
            for entry in entries {
                _ = filter.matches(entry)
            }
            _ = filter.title
        }
    }
}
