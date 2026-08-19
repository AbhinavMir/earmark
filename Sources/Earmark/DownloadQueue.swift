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
            guard let fraction else { return "Downloading" }
            return "Downloading \(Int(fraction * 100))%"
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

    /// True when this title is queued or downloading.
    func isQueued(_ asin: String) -> Bool {
        jobs.contains { $0.asin == asin && $0.state.isActive }
    }

    /// Adds titles that are not already queued or downloaded.
    func enqueue(_ entries: [LibraryEntry]) {
        for entry in entries where !isQueued(entry.book.asin) && !entry.isDownloaded {
            jobs.removeAll { $0.asin == entry.book.asin }
            jobs.append(DownloadJob(asin: entry.book.asin, title: entry.book.title))
        }
        startNext()
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

    private func startNext() {
        guard running.count < DownloadQueue.concurrency else { return }
        guard let next = jobs.first(where: { $0.state == .queued }) else { return }
        running.insert(next.asin)
        Task { await run(next.asin) }
        startNext()
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

        do {
            update(asin, .licensing)
            let license = try await LicenseService(client: client).license(for: asin)
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

            update(asin, .decrypting)
            try await DecryptService().decrypt(
                encrypted,
                license: license,
                to: decrypted,
                expectedDuration: entry.book.duration)
            try? FileManager.default.removeItem(at: encrypted)

            await store.setFileName(fileName, for: asin)
            update(asin, .done)
        } catch {
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
        return "\(author)/\(series)\(book.title.fileSafe).m4b"
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
        let trimmed = separated.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
