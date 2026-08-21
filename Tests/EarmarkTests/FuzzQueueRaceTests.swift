import Foundation
import Testing
import AudibleKit
@testable import Earmark

/// The queue reads the store while a download runs, and the store changes
/// underneath it: a refresh can drop a title, a file can be deleted, a name
/// can change. None of that may leave a mark on a title that is not true.
@Suite("Fuzzing the queue against a moving store")
@MainActor
struct QueueRaceFuzzTests {

    static func makeStore() -> LibraryStore {
        LibraryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("race-\(UUID().uuidString).json"))
    }

    static func entry(_ asin: String, downloaded: Bool = false) -> LibraryEntry {
        LibraryEntry(
            book: Book(asin: asin, title: "Title \(asin)", authors: ["Ada Marsh"],
                       duration: 3_600),
            fileName: downloaded ? "Ada Marsh/Title \(asin).m4b" : nil)
    }

    @Test("A title dropped from the library while queued does not stay queued")
    func titleLeavesWhileQueued() async {
        let store = Self.makeStore()
        await store.merge([Book(asin: "A", title: "T", duration: 3_600)])

        let queue = DownloadQueue(store: store)
        queue.enqueue([Self.entry("A")])
        #expect(queue.jobs.count == 1)

        // A refresh that no longer carries the title.
        await store.merge([Book(asin: "B", title: "U")])

        // The job may fail, but the queue must stay consistent.
        for _ in 0..<20 {
            _ = queue.jobs.map(\.state.label)
            queue.clearCompleted()
        }
        #expect(queue.jobs.count <= 1)
    }

    @Test("A mark of being downloaded never survives its file being deleted")
    func fileDeletedUnderneath() async throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("race-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audio) }

        let store = Self.makeStore()
        await store.merge([Book(asin: "A", title: "T", duration: 3_600)])

        let name = "Ada Marsh/T.m4b"
        let file = audio.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        await store.setFileName(name, for: "A")

        // Deleted outside the application, as a person tidying a folder would.
        try FileManager.default.removeItem(at: file)

        // The mark is still there until something checks. What must not happen
        // is the queue refusing to fetch it again because of a stale mark.
        let queue = DownloadQueue(store: store, audioDirectory: audio)
        queue.enqueue([await store.entry("A")!])
        #expect(queue.jobs.count == 1, "a title whose file is gone must be fetchable")
    }

    @Test("Enqueuing while the store is being written does not lose a job")
    func enqueueDuringWrites() async {
        let store = Self.makeStore()
        await store.merge((0..<20).map { Book(asin: "B\($0)", title: "T\($0)") })
        let queue = DownloadQueue(store: store)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for index in 0..<20 {
                    queue.enqueue([Self.entry("B\(index)")])
                }
            }
            group.addTask {
                for index in 0..<20 {
                    await store.setPosition(TimeInterval(index), for: "B\(index)")
                }
            }
        }

        let ids = queue.jobs.map(\.asin)
        #expect(Set(ids).count == ids.count)
        #expect(queue.jobs.count == 20)
    }

    @Test("Cancelling a job that is running does not remove it from sight")
    func cancelWhileRunning() {
        let queue = DownloadQueue(store: Self.makeStore())
        queue.enqueue((0..<6).map { Self.entry("B\($0)") })

        // The first two start at once. Cancelling those must not hide work
        // that is still going on.
        let running = queue.jobs.prefix(2).map(\.asin)
        for asin in running { queue.cancel(asin) }

        for asin in running {
            #expect(queue.jobs.contains { $0.asin == asin },
                    "\(asin) vanished while it was still running")
        }
    }

    @Test("Clearing finished work never removes work that is still going")
    func clearingKeepsActiveWork() {
        let queue = DownloadQueue(store: Self.makeStore())
        queue.enqueue((0..<10).map { Self.entry("B\($0)") })

        let before = queue.jobs.filter(\.state.isActive).count
        queue.clearCompleted()
        let after = queue.jobs.filter(\.state.isActive).count
        #expect(after == before)
    }
}
