import Foundation
import SwiftUI
import AppKit
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
        /// The first fetch, with covers being cached. Shown once.
        case settingUp
        case ready
    }

    private(set) var stage: Stage = .checkingCredentials
    private(set) var entries: [LibraryEntry] = [] {
        didSet {
            entriesByID = Dictionary(
                entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    /// The same titles, by identifier.
    ///
    /// Finding a title by walking the whole library, once per selected title,
    /// is work that grows with the square of the library, and it runs every
    /// time anything on screen changes.
    private(set) var entriesByID: [String: LibraryEntry] = [:]
    private(set) var isRefreshing = false
    /// The most recent failure, shown in place rather than as an alert.
    var banner: String?
    /// Set when a remote position overrode the local one, so it can be undone.
    var positionOverride: (asin: String, previous: TimeInterval)?

    let player = Player()
    let queue: DownloadQueue
    let store: LibraryStore
    /// Covers on disk, so the library draws without the network.
    let covers = CoverCache()
    /// The account's Audible plan, when it has one. The API reports no credit
    /// balance, so the plan is what can be shown.
    private(set) var membership: Membership?
    /// What the setup screen says it is doing.
    private(set) var setupMessage = "Reaching Audible..."
    /// How far setup has gone, from 0 to 1. Nil while the total is unknown.
    private(set) var setupFraction: Double?
    /// The title being prepared, shown at once so a click has an effect
    /// before any audio exists.
    private(set) var preparingEntry: LibraryEntry?
    /// The stream now running, if any.
    private var stream: StreamService?
    /// The work that prepares playback. Cancelled when another title starts.
    private var prepareTask: Task<Void, Never>?

    private let credentials: CredentialStore
    private let audioDirectory: URL
    private var client: AudibleClient?
    private var syncTask: Task<Void, Never>?

    init(
        credentials: CredentialStore = MigratingCredentialStore(),
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
            self?.stream?.stop()
            self?.stream = nil
            self?.player.unload()
        }
        player.onSeekBeyondStream = { [weak self] asin, position in
            self?.restartStream(asin, at: position)
        }
        queue.onFinish = { [weak self] asin in
            self?.switchToDownloadedFile(asin)
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
            Log.write("Connected. Fetching the library.")
            // The setup screen is for the work that has to finish before the
            // library is worth looking at: the first fetch, and the covers.
            // A library whose covers are already saved opens straight away.
            let known = await store.sortedEntries
            let missing = known.count
                - (await covers.cachedCount(of: known.map(\.book.asin)))
            stage = (known.isEmpty || missing > 10) ? .settingUp : .ready

            await refresh()
            if stage == .settingUp {
                await cacheCovers()
                stage = .ready
            } else {
                // A handful of new titles are fetched quietly behind the
                // library, which already draws.
                Task { await self.cacheCovers() }
            }
            startSyncLoop()
        } catch AudibleError.notRegistered {
            Log.write("Connect found no stored identity.")
            stage = .signedOut
        } catch {
            Log.write("Connect failed: \(error.localizedDescription)")
            banner = error.localizedDescription
            stage = .signedOut
        }
    }

    func signOut() {
        syncTask?.cancel()
        stopPlayback()
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
            setupMessage = "Fetching your library..."
            let books = try await LibraryService(client: client).all()
            setupMessage = "Found \(books.count) titles"
            Log.write("Library returned \(books.count) titles.")
            await store.merge(books)
            await reconcileDownloadedFiles()
            entries = await store.sortedEntries
            await pullPositions()
            await loadMembership()
            try? await store.save()
        } catch {
            Log.write("Library refresh failed: \(error.localizedDescription)")
            banner = error.localizedDescription
        }
    }

    /// Reads the account's plan. A failure here is not worth a banner.
    private func loadMembership() async {
        guard let client else { return }
        membership = try? await MembershipService(client: client).membership()
    }

    /// Fetches every cover that is not on disk yet, reporting progress.
    private func cacheCovers() async {
        let entries = await store.sortedEntries
        guard !entries.isEmpty else { return }

        let wanted = entries.map { (asin: $0.book.asin, url: $0.book.coverURL) }
        let already = await covers.cachedCount(of: entries.map(\.book.asin))
        guard already < wanted.count else { return }

        setupMessage = "Saving covers 0 of \(wanted.count)"
        setupFraction = 0
        await covers.warm(wanted) { [weak self] done, total in
            await MainActor.run {
                self?.setupMessage = "Saving covers \(done) of \(total)"
                self?.setupFraction = Double(done) / Double(total)
            }
        }
        Log.write("Cached covers for \(wanted.count) titles.")
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

    /// Opens Audible in a browser, because buying happens there.
    func openStore(path: String = "") {
        let domain = client == nil ? "com" : "com"
        guard let url = URL(string: "https://www.audible.\(domain)\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the small player in its own window.
    func showMiniPlayer() {
        MiniPlayerWindow.shared.show(model: self)
    }

    /// Opens the audio file's folder, with the file selected.
    func revealInFinder(_ entry: LibraryEntry) {
        guard let url = fileURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Deletes the audio file and clears the mark. The position is kept.
    func removeDownload(_ entry: LibraryEntry) async {
        if let url = fileURL(for: entry) {
            try? FileManager.default.removeItem(at: url)
        }
        await store.setFileName(nil, for: entry.book.asin)
        if let updated = await store.entry(entry.book.asin) { replace(updated) }
    }

    // MARK: Playback

    /// Plays a title.
    ///
    /// A downloaded title plays from disk. Anything else streams, so playback
    /// starts without waiting for a whole book to arrive.
    /// Plays a title.
    ///
    /// A downloaded title plays from disk. Anything else streams, so playback
    /// starts without waiting for a whole book.
    ///
    /// The title appears in the player straight away, before any audio is
    /// ready, so the click has a visible effect. Starting another title
    /// cancels this one rather than leaving two streams running.
    func play(_ entry: LibraryEntry) async {
        // A second press on a title already being prepared is not a request to
        // start it again. Restarting tore down the stream that was starting.
        if preparingEntry?.id == entry.id { return }

        prepareTask?.cancel()
        stream?.stop()
        stream = nil
        preparingEntry = entry
        banner = nil

        let task = Task { [weak self] in
            guard let self else { return }
            await self.prepare(entry)
        }
        prepareTask = task
        await task.value
    }

    /// Stops whatever is playing or being prepared.
    func stopPlayback() {
        prepareTask?.cancel()
        prepareTask = nil
        preparingEntry = nil
        stream?.stop()
        stream = nil
        player.unload()
    }

    private func prepare(_ entry: LibraryEntry) async {
        defer { if preparingEntry?.id == entry.id { preparingEntry = nil } }

        // Take the position Audible holds before starting, so a session begun
        // on the phone continues here rather than restarting.
        // A downloaded title needs nothing from the network to start, so the
        // position is fetched after playback begins rather than before it.
        if let existing = await store.entry(entry.book.asin), let url = fileURL(for: existing) {
            player.load(existing, url: url, source: .file(url))
            player.play()
            Task { await self.followRemotePositionIfNewer(existing.book.asin) }
            return
        }

        await pullPosition(for: entry.book.asin)
        guard !Task.isCancelled else { return }
        guard let fresh = await store.entry(entry.book.asin) else { return }

        if let url = fileURL(for: fresh) {
            stream?.stop()
            stream = nil
            player.load(fresh, url: url, source: .file(url))
            player.play()
            return
        }
        await startStream(of: fresh, from: fresh.position)
    }

    /// Streams a title from `offset`, replacing any stream already running.
    private func startStream(of entry: LibraryEntry, from offset: TimeInterval) async {
        guard let client else { return }
        let began = Date()
        do {
            let license = try await LicenseService(client: client).license(for: entry.book.asin)
            let licensed = Date()
            guard !Task.isCancelled else { return }
            if !license.chapters.isEmpty {
                await store.setChapters(license.chapters, for: entry.book.asin)
                if let updated = await store.entry(entry.book.asin) { replace(updated) }
            }

            let service = try StreamService()
            let started = try await service.start(license, from: offset)
            guard !Task.isCancelled else {
                service.stop()
                return
            }
            stream?.stop()
            stream = service

            let fresh = await store.entry(entry.book.asin) ?? entry
            player.load(fresh, url: started.playlistURL, source: .stream(offset: offset))
            player.play()
            Log.write(String(
                format: "Ready to play %@: license %.1fs, stream %.1fs, total %.1fs",
                entry.book.title,
                licensed.timeIntervalSince(began),
                Date().timeIntervalSince(licensed),
                Date().timeIntervalSince(began)))

            // Keep what is being listened to. The stream holds nothing, so
            // without this the same audio is fetched again next time.
            queue.enqueue([fresh], quietly: true)
        } catch {
            guard !Task.isCancelled else { return }
            Log.write("Streaming \(entry.book.title) failed: \(error.localizedDescription)")
            banner = "\(entry.book.title) could not be played. \(error.localizedDescription)"
        }
    }

    /// Moves a title now streaming onto its downloaded file.
    ///
    /// The file seeks anywhere at once and needs no network, so it is better
    /// in every way than the stream it replaces. The switch keeps the current
    /// position, and does nothing when this title is not the one playing.
    private func switchToDownloadedFile(_ asin: String) {
        Task {
            guard player.entry?.book.asin == asin,
                  player.source?.isStream == true,
                  let entry = await store.entry(asin),
                  let url = fileURL(for: entry)
            else { return }

            let position = player.position
            let wasPlaying = player.isPlaying
            var current = entry
            current.position = position

            player.load(current, url: url, source: .file(url))
            if wasPlaying { player.play() }
            stream?.stop()
            stream = nil
            Log.write("Moved \(entry.book.title) from the stream to its file.")
        }
    }

    /// Restarts the stream at a position it does not hold.
    private func restartStream(_ asin: String, at position: TimeInterval) {
        Task {
            guard let entry = await store.entry(asin) else { return }
            await startStream(of: entry, from: position)
        }
    }

    private func recordPosition(_ position: TimeInterval, for asin: String) {
        Task {
            await store.setPosition(position, for: asin)
            // One title moved, so one row changes. Replacing the whole list
            // makes every row on screen rebuild, twice a minute, while a book
            // is playing.
            if let updated = await store.entry(asin) { replace(updated) }
            await pushPosition(position, for: asin)
        }
    }

    /// The titles with these identifiers, in the order they are on screen.
    func entries(withIDs ids: Set<String>) -> [LibraryEntry] {
        guard !ids.isEmpty else { return [] }
        return entries.filter { ids.contains($0.id) }
    }

    /// Puts one title back in the list, leaving the rest alone.
    private func replace(_ entry: LibraryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard entries[index] != entry else { return }
        entries[index] = entry
    }

    // MARK: Bookmarks

    func addBookmark(note: String = "") async {
        guard let entry = player.entry else { return }
        let bookmark = Bookmark(position: player.position, note: note)
        await store.addBookmark(bookmark, to: entry.book.asin)
        if let updated = await store.entry(entry.book.asin) { replace(updated) }
    }

    func removeBookmark(_ id: UUID, from asin: String) async {
        await store.removeBookmark(id, from: asin)
        if let updated = await store.entry(asin) { replace(updated) }
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
            for asin in changed {
                if let updated = await store.entry(asin) { replace(updated) }
            }
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
            for asin in await store.applyRemotePositions(remote) {
                if let updated = await store.entry(asin) { replace(updated) }
            }
        } catch {
            // Fall through to the local position.
        }
    }

    /// Checks Audible's position after playback has begun, and moves to it
    /// when the other device stopped later.
    ///
    /// A downloaded title starts at its local position at once. Waiting on the
    /// network first would delay every play for a check that rarely changes
    /// anything.
    private func followRemotePositionIfNewer(_ asin: String) async {
        await pullPosition(for: asin)
        guard let entry = await store.entry(asin),
              player.entry?.book.asin == asin,
              abs(entry.position - player.position) > PositionService.conflictThreshold
        else { return }
        await followRemotePosition(for: asin)
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
