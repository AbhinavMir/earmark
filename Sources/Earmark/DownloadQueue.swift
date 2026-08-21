import Foundation
import AudibleKit

/// What is happening to one title in the queue.
enum DownloadState: Equatable, Sendable {
    case queued
    case licensing
    case downloading(fraction: Double?)
    case decrypting
    case done
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .licensing, .downloading, .decrypting: return true
        case .done, .failed: return false
        }
    }

    /// What the interface prints beside the title.
    var label: String {
        switch self {
        case .queued: return "Waiting"
        case .licensing: return "Getting permission"
        case .downloading(let fraction):
            guard let fraction, fraction.isFinite else { return "Downloading" }
            return "Downloading \(Int(min(100, max(0, fraction * 100))))%"
        case .decrypting: return "Preparing"
        case .done: return "Done"
        case .failed(let reason): return reason
        }
    }
}

/// One title's place in the queue.
struct DownloadJob: Identifiable, Sendable {
    let asin: String
    let title: String
    var state: DownloadState = .queued
    /// True when nobody asked for this download: it follows a stream, so that
    /// the title is kept once it has been listened to.
    var isQuiet = false
    var id: String { asin }
}

/// Downloads titles one after another, two at a time.
///
/// The queue survives a failure of any single title: a failed job keeps its
/// reason and the others carry on.
@MainActor
@Observable
final class DownloadQueue {
    private(set) var jobs: [DownloadJob] = []

    /// How many titles download at once. More than this competes for bandwidth
    /// without finishing any title sooner.
    static let concurrency = 2

    /// Called when a title finishes downloading, so a stream of that title
    /// can hand over to the file.
    var onFinish: ((String) -> Void)?

    private let audioDirectory: URL
    private let store: LibraryStore
    private var client: AudibleClient?
    private var running: Set<String> = []

    init(store: LibraryStore, audioDirectory: URL = LibraryStore.defaultAudioDirectory) {
        self.store = store
        self.audioDirectory = audioDirectory
    }

    func use(client: AudibleClient) {
        self.client = client
    }

    /// True when this title's audio is actually on disk.
    ///
    /// The mark on a title says it was downloaded once. A file deleted in the
    /// Finder leaves that mark behind, and trusting it alone meant refusing to
    /// fetch a title whose audio was gone.
    func hasFile(_ entry: LibraryEntry) -> Bool {
        guard let fileName = entry.fileName else { return false }
        return FileManager.default.fileExists(
            atPath: audioDirectory.appendingPathComponent(fileName).path)
    }

    /// True when this title is queued or downloading.
    func isQueued(_ asin: String) -> Bool {
        jobs.contains { $0.asin == asin && $0.state.isActive }
    }

    /// Adds titles that are not already queued or downloaded.
    ///
    /// - Parameter quietly: Pass true for a download that follows a stream.
    ///   Such a job stays out of the count on the toolbar, because nobody
    ///   asked for it and nobody is waiting on it.
    func enqueue(_ entries: [LibraryEntry], quietly: Bool = false) {
        for entry in entries where !isQueued(entry.book.asin) && !hasFile(entry) {
            jobs.removeAll { $0.asin == entry.book.asin }
            jobs.append(DownloadJob(
                asin: entry.book.asin, title: entry.book.title, isQuiet: quietly))
        }
        startNext()
    }

    /// Jobs a person is waiting on. A quiet job is not one of them.
    var visibleActiveCount: Int {
        jobs.filter { $0.state.isActive && !$0.isQuiet }.count
    }

    func cancel(_ asin: String) {
        jobs.removeAll { $0.asin == asin && !running.contains($0.asin) }
    }

    func retry(_ asin: String) {
        guard let index = jobs.firstIndex(where: { $0.asin == asin }) else { return }
        jobs[index].state = .queued
        startNext()
    }

    /// Removes finished and failed jobs from the list.
    func clearCompleted() {
        jobs.removeAll { !$0.state.isActive }
    }

    // MARK: Running

    /// Starts jobs until the limit is reached or nothing is waiting.
    ///
    /// A started job leaves the queued state here, before its task runs. While
    /// it stayed queued, every pass picked the same job again, which recursed
    /// until the stack ran out.
    private func startNext() {
        while running.count < DownloadQueue.concurrency {
            guard let index = jobs.firstIndex(where: {
                $0.state == .queued && !running.contains($0.asin)
            }) else { return }

            let asin = jobs[index].asin
            jobs[index].state = .licensing
            running.insert(asin)
            Task { await run(asin) }
        }
    }

    private func update(_ asin: String, _ state: DownloadState) {
        guard let index = jobs.firstIndex(where: { $0.asin == asin }) else { return }
        jobs[index].state = state
    }

    private func run(_ asin: String) async {
        defer {
            running.remove(asin)
            startNext()
        }

        guard let client else {
            update(asin, .failed("Not signed in."))
            return
        }
        guard let entry = await store.entry(asin) else {
            update(asin, .failed("This title is no longer in the library."))
            return
        }
        // A title downloaded by an earlier run needs nothing further. Retrying
        // an old failure must not fetch a file that is already here.
        if hasFile(entry) {
            Log.write("\(entry.book.title) is already downloaded.")
            update(asin, .done)
            return
        }

        do {
            Log.write("Requesting a license for \(asin) (\(entry.book.title)).")
            let license = try await LicenseService(client: client).license(for: asin)
            Log.write("License granted. \(license.chapters.count) chapters.")
            if !license.chapters.isEmpty {
                await store.setChapters(license.chapters, for: asin)
            }

            update(asin, .downloading(fraction: nil))
            let encrypted = audioDirectory
                .appendingPathComponent("Incomplete", isDirectory: true)
                .appendingPathComponent("\(asin).aaxc")
            let fileName = DownloadQueue.fileName(for: entry.book)
            let decrypted = audioDirectory.appendingPathComponent(fileName)

            let reporter = ProgressBridge { [weak self] fraction in
                Task { @MainActor in self?.update(asin, .downloading(fraction: fraction)) }
            }
            try await DownloadService().download(license, to: encrypted) { progress in
                reporter.report(progress.fraction)
            }
            let size = FileManager.default.fileSize(at: encrypted) ?? 0
            Log.write("Downloaded \(size / 1_048_576) MB to \(encrypted.lastPathComponent).")

            update(asin, .decrypting)
            try await DecryptService().decrypt(
                encrypted,
                license: license,
                to: decrypted,
                expectedDuration: entry.book.duration)
            try? FileManager.default.removeItem(at: encrypted)

            await store.setFileName(fileName, for: asin)
            Log.write("Finished \(entry.book.title).")
            update(asin, .done)
            onFinish?(asin)
        } catch {
            Log.write("Failed \(entry.book.title): \(error.localizedDescription)")
            update(asin, .failed(error.localizedDescription))
        }
    }

    /// Builds the on-disk name: author folder, then title.
    ///
    /// Pure text work, so it stays off the main actor and stays testable.
    nonisolated static func fileName(for book: Book) -> String {
        let author = book.authors.first?.fileSafe ?? "Unknown Author"
        let series = book.series.map { entry -> String in
            guard let position = entry.position else { return "" }
            return "\(position.fileSafe) - "
        } ?? ""
        // The series prefix and the extension share the component's budget.
        let stem = "\(series)\(book.title.fileSafe)"
            .truncatedToBytes(String.fileNameByteLimit)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return "\(author)/\(stem.isEmpty ? "Untitled" : stem).m4b"
    }
}

/// Forwards download progress from a background callback onto the main actor,
/// dropping updates smaller than a whole percent.
final class ProgressBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private let onChange: (Double?) -> Void

    init(onChange: @escaping (Double?) -> Void) {
        self.onChange = onChange
    }

    func report(_ fraction: Double?) {
        guard let fraction else { return }
        let percent = Int(fraction * 100)
        let shouldSend = lock.withLock {
            guard percent > lastPercent else { return false }
            lastPercent = percent
            return true
        }
        if shouldSend { onChange(fraction) }
    }
}

extension String {
    /// The longest a single part of a path can be, in bytes.
    ///
    /// Every file system macOS writes to stops at 255 bytes per component. A
    /// longer name is not truncated for you: the write fails.
    static let fileNameByteLimit = 200

    /// The text with characters a file name cannot hold replaced.
    ///
    /// Runs of replaced characters collapse to one dash, and dashes at either
    /// end are dropped, so a title made only of illegal characters yields a
    /// name rather than a row of dashes.
    var fileSafe: String {
        let separated = components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        // Control characters, including the null a file system will not take.
        let printable = String(separated.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        })

        let trimmed = printable
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
            .truncatedToBytes(String.fileNameByteLimit)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. "))

        // A name of dots alone is a reference to a folder, not a file.
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "Untitled" }
        return trimmed
    }

    /// The text cut to fit a byte count, never through a character.
    func truncatedToBytes(_ limit: Int) -> String {
        guard utf8.count > limit else { return self }
        var result = ""
        var used = 0
        for character in self {
            let width = String(character).utf8.count
            if used + width > limit { break }
            result.append(character)
            used += width
        }
        return result
    }
}
