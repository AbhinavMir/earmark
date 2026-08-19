import Foundation
import SwiftUI
import AudibleKit

/// The state the whole interface reads.
///
/// It owns the library, the sync loop, the queue, and the player, and is the
/// only place that decides what happens when they disagree.
@MainActor
@Observable
final class AppModel {
    enum Stage: Equatable {
        case checkingCredentials
        case signedOut
        case ready
    }

    private(set) var stage: Stage = .checkingCredentials
    private(set) var entries: [LibraryEntry] = []
    private(set) var isRefreshing = false
    /// The most recent failure, shown in place rather than as an alert.
    var banner: String?
    /// Set when a remote position overrode the local one, so it can be undone.
    var positionOverride: (asin: String, previous: TimeInterval)?

    let player = Player()
    let queue: DownloadQueue
    let store: LibraryStore

    private let credentials: CredentialStore
    private let audioDirectory: URL
    private var client: AudibleClient?
    private var syncTask: Task<Void, Never>?

    init(
        credentials: CredentialStore = KeychainCredentialStore(),
        store: LibraryStore = LibraryStore(),
        audioDirectory: URL = LibraryStore.defaultAudioDirectory
    ) {
        self.credentials = credentials
        self.store = store
        self.audioDirectory = audioDirectory
        self.queue = DownloadQueue(store: store, audioDirectory: audioDirectory)

        player.onPositionChange = { [weak self] asin, position in
            self?.recordPosition(position, for: asin)
        }
        player.onFinish = { [weak self] _ in
            self?.player.unload()
        }
    }

    // MARK: Startup

    func start() async {
        do {
            try await store.load()
            entries = await store.sortedEntries
        } catch {
            banner = "The saved library could not be read. \(error.localizedDescription)"
        }

        let stored = try? credentials.load()
        guard stored != nil else {
            stage = .signedOut
            return
        }
        await connect()
    }

    /// Builds the client from stored credentials and starts the sync loop.
    func connect() async {
        do {
            let client = try AudibleClient(store: credentials)
            self.client = client
            queue.use(client: client)
            stage = .ready
            await refresh()
            startSyncLoop()
        } catch AudibleError.notRegistered {
            stage = .signedOut
        } catch {
            banner = error.localizedDescription
            stage = .signedOut
        }
    }

    func signOut() {
        syncTask?.cancel()
        player.unload()
        client = nil
        try? credentials.clear()
        stage = .signedOut
    }

    // MARK: Library

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let books = try await LibraryService(client: client).all()
            await store.merge(books)
            await reconcileDownloadedFiles()
            entries = await store.sortedEntries
            await pullPositions()
        } catch {
            banner = error.localizedDescription
        }
    }

    /// Checks that each title marked as downloaded still has its file.
    ///
    /// A file deleted outside Earmark must clear the mark; otherwise the
    /// player would try to open a file that is not there.
    private func reconcileDownloadedFiles() async {
        for entry in await store.sortedEntries {
            guard let fileName = entry.fileName else { continue }
            let url = audioDirectory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                await store.setFileName(nil, for: entry.book.asin)
            }
        }
    }

    func fileURL(for entry: LibraryEntry) -> URL? {
        entry.fileName.map { audioDirectory.appendingPathComponent($0) }
    }

    func download(_ entries: [LibraryEntry]) {
        queue.enqueue(entries)
    }

    /// Deletes the audio file and clears the mark. The position is kept.
    func removeDownload(_ entry: LibraryEntry) async {
        if let url = fileURL(for: entry) {
            try? FileManager.default.removeItem(at: url)
        }
        await store.setFileName(nil, for: entry.book.asin)
        entries = await store.sortedEntries
    }

    // MARK: Playback

    func play(_ entry: LibraryEntry) async {
        guard let url = fileURL(for: entry) else {
            queue.enqueue([entry])
            banner = "\(entry.book.title) is downloading. It will play once it is ready."
            return
        }
        // Take the phone's position before starting, so a session begun there
        // continues here rather than restarting.
        await pullPosition(for: entry.book.asin)
        guard let fresh = await store.entry(entry.book.asin) else { return }

        do {
            try player.load(fresh, fileURL: url)
            player.play()
        } catch {
            banner = "\(entry.book.title) could not be opened. \(error.localizedDescription)"
        }
    }

    private func recordPosition(_ position: TimeInterval, for asin: String) {
        Task {
            await store.setPosition(position, for: asin)
            entries = await store.sortedEntries
            await pushPosition(position, for: asin)
        }
    }

    // MARK: Bookmarks

    func addBookmark(note: String = "") async {
        guard let entry = player.entry else { return }
        let bookmark = Bookmark(position: player.position, note: note)
        await store.addBookmark(bookmark, to: entry.book.asin)
        entries = await store.sortedEntries
    }

    func removeBookmark(_ id: UUID, from asin: String) async {
        await store.removeBookmark(id, from: asin)
        entries = await store.sortedEntries
    }

    // MARK: Position sync

    /// Pulls positions every two minutes while the application runs.
    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.pullPositions()
            }
        }
    }

    private func pullPositions() async {
        guard let client else { return }
        let asins = await store.sortedEntries.map(\.book.asin)
        guard !asins.isEmpty else { return }
        do {
            let remote = try await PositionService(client: client).positions(for: asins)
            let changed = await store.applyRemotePositions(remote)
            entries = await store.sortedEntries
            // A title being listened to now is the one worth mentioning.
            if let playing = player.entry?.book.asin, changed.contains(playing) {
                await followRemotePosition(for: playing)
            }
        } catch {
            // A sync failure is not worth interrupting playback over. The next
            // pass tries again.
        }
    }

    private func pullPosition(for asin: String) async {
        guard let client else { return }
        do {
            let remote = try await PositionService(client: client).positions(for: [asin])
            _ = await store.applyRemotePositions(remote)
            entries = await store.sortedEntries
        } catch {
            // Fall through to the local position.
        }
    }

    /// Moves the running player onto a position the phone recorded later.
    private func followRemotePosition(for asin: String) async {
        guard let entry = await store.entry(asin), player.entry?.book.asin == asin else { return }
        let previous = player.position
        player.seek(to: entry.position)
        positionOverride = (asin: asin, previous: previous)
    }

    /// Puts the position back where it was before a remote override.
    func undoPositionOverride() {
        guard let override = positionOverride else { return }
        player.seek(to: override.previous)
        positionOverride = nil
    }

    private func pushPosition(_ position: TimeInterval, for asin: String) async {
        guard let client else { return }
        do {
            try await PositionService(client: client).record(
                ListeningPosition(asin: asin, position: position, recordedAt: Date()))
        } catch {
            // The local position is already saved. The next push carries it.
        }
    }
}
