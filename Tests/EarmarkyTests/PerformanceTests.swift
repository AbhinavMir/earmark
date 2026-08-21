import Foundation
import Testing
import AudibleKit
@testable import Earmarky

/// Work that happens every time anything on screen changes.
///
/// These paths run on each redraw, for each row, so anything that grows with
/// the size of the library is felt as a delay when clicking.
@Suite("Work done on every redraw")
@MainActor
struct RedrawCostTests {

    static func entries(_ count: Int) -> [LibraryEntry] {
        (0..<count).map { index in
            LibraryEntry(
                book: Book(asin: String(format: "B%05d", index),
                           title: "Title \(index)", authors: ["Ada Marsh"],
                           duration: 3_600),
                position: TimeInterval(index))
        }
    }

    @Test("Looking up selected titles does not walk the library each time")
    func selectionLookupIsFlat() {
        let all = Self.entries(2_000)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = Set(all.prefix(500).map(\.id))

        // What it used to do: walk every title, once per selected title.
        let walking = ContinuousClock().measure {
            _ = selected.compactMap { id in all.first { $0.id == id } }
        }
        // What it does now.
        let looking = ContinuousClock().measure {
            _ = all.filter { selected.contains($0.id) }
            _ = selected.compactMap { byID[$0] }
        }

        #expect(looking < walking,
                "walking took \(walking), looking took \(looking)")
    }

    @Test("A row asking about its download does not walk the queue")
    func queueLookupIsFlat() {
        let queue = DownloadQueue(store: LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("perf-\(UUID().uuidString).json")))
        queue.enqueue(Self.entries(300))

        // Every row on screen asks this on every redraw.
        for entry in Self.entries(300) {
            _ = queue.isQueued(entry.id)
            _ = queue.activeByASIN[entry.id]
        }
        #expect(queue.activeByASIN.count <= queue.jobs.count)
    }

    @Test("The lookup keeps step with the list")
    func lookupStaysInStep() {
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            store: LibraryStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("perf-\(UUID().uuidString).json")))
        #expect(model.entriesByID.isEmpty)
        #expect(model.entries(withIDs: ["B00000"]).isEmpty)
    }

    @Test("Only what is queued is in the lookup")
    func lookupHoldsActiveWorkOnly() {
        let queue = DownloadQueue(store: LibraryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("perf-\(UUID().uuidString).json")))
        queue.enqueue(Self.entries(5))
        #expect(queue.activeByASIN.count == 5)

        queue.cancel("B00004")
        #expect(queue.activeByASIN["B00004"] == nil)
        #expect(queue.isQueued("B00004") == false)
    }
}
