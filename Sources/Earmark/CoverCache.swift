import Foundation
import AppKit
import AudibleKit

/// Keeps cover images on disk, so the library draws without the network.
///
/// Covers never change for a title, so a cached file is good forever. The
/// cache lives under Caches, which is the right place for something the
/// application can fetch again.
actor CoverCache {
    private let directory: URL
    private let session: URLSession
    /// Images already decoded, kept so scrolling does not read the disk.
    private var memory: [String: NSImage] = [:]

    init(directory: URL = CoverCache.defaultDirectory, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Earmarky/Covers", isDirectory: true)
    }

    private func fileURL(for asin: String) -> URL {
        directory.appendingPathComponent("\(CoverCache.fileName(for: asin)).img")
    }

    /// A name that stays inside the cache folder.
    ///
    /// An identifier comes from a server. One carrying a path would otherwise
    /// write a file wherever it pointed: "../x" leaves the folder entirely.
    /// Only the characters an identifier really uses are kept, and anything
    /// else becomes a digest of the original, which stays unique.
    static func fileName(for asin: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(asin.unicodeScalars.filter { allowed.contains($0) })
        guard !cleaned.isEmpty, cleaned == asin, cleaned.utf8.count <= 100 else {
            return "id-\(abs(asin.hashValue))"
        }
        return cleaned
    }

    /// True when this title's cover is already on disk.
    func isCached(_ asin: String) -> Bool {
        memory[asin] != nil || FileManager.default.fileExists(atPath: fileURL(for: asin).path)
    }

    /// The cover for a title, from memory, then disk, then the network.
    ///
    /// Returns nil when the title has no cover or the fetch fails. A caller
    /// shows its own placeholder rather than an empty space.
    func image(for asin: String, url: URL?) async -> NSImage? {
        if let cached = memory[asin] { return cached }

        let file = fileURL(for: asin)
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            memory[asin] = image
            return image
        }

        guard let url else { return nil }
        guard let data = try? await fetch(url), let image = NSImage(data: data) else {
            return nil
        }
        try? data.write(to: file, options: .atomic)
        memory[asin] = image
        return image
    }

    /// Fetches every cover that is not cached yet.
    ///
    /// - Parameter onProgress: Called after each title, with how many are done
    ///   and how many there are. Runs on the main actor.
    func warm(
        _ entries: [(asin: String, url: URL?)],
        onProgress: @Sendable @escaping (Int, Int) async -> Void
    ) async {
        let total = entries.count
        var done = 0
        // A few at a time: enough to be quick, few enough to leave the network
        // to whatever is playing.
        let batchSize = 6

        for batch in entries.chunked(into: batchSize) {
            await withTaskGroup(of: Void.self) { group in
                for entry in batch {
                    group.addTask { _ = await self.image(for: entry.asin, url: entry.url) }
                }
            }
            done += batch.count
            await onProgress(min(done, total), total)
        }
    }

    /// How many of these titles already have a cover on disk.
    func cachedCount(of asins: [String]) -> Int {
        asins.filter(isCached).count
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AudibleError.downloadFailed("The cover could not be fetched.")
        }
        return data
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
