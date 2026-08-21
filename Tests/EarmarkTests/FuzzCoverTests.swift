import Foundation
import AppKit
import Testing
import AudibleKit
@testable import Earmark

/// The cover cache writes files named after identifiers that come from a
/// server, and reads whatever is on disk at those names.
@Suite("Fuzzing the cover cache")
struct CoverCacheFuzzTests {

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("An identifier of any shape never writes outside the cache")
    func identifiersStayInside() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = dir.deletingLastPathComponent().appendingPathComponent("escaped.img")
        try? FileManager.default.removeItem(at: outside)

        let cache = CoverCache(directory: dir)
        let identifiers = ["../escaped", "../../escaped", "/etc/passwd", "..",
                           "", " ", "a/b", String(repeating: "z", count: 400)]
        for identifier in identifiers {
            _ = await cache.isCached(identifier)
            _ = await cache.image(for: identifier, url: nil)
        }

        // Nothing may have been created next to the cache.
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("A name for a cover always stays inside the cache folder")
    func namesStayInside() {
        // An identifier comes from a server, and one carrying a path would
        // write a file wherever it pointed.
        let awkward = ["../escaped", "../../escaped", "/etc/passwd", "..", ".",
                       "", " ", "a/b", "a\u{0000}b", String(repeating: "z", count: 400),
                       "🎧", "a b"]
        for asin in awkward {
            let name = CoverCache.fileName(for: asin)
            #expect(!name.contains("/"), "\(asin) gave \(name)")
            #expect(!name.contains(".."), "\(asin) gave \(name)")
            #expect(!name.isEmpty)
            #expect(name.utf8.count <= 100)

            let base = URL(fileURLWithPath: "/tmp/covers", isDirectory: true)
            let file = base.appendingPathComponent("\(name).img").standardizedFileURL
            #expect(file.path.hasPrefix("/tmp/covers/"), "\(asin) wrote to \(file.path)")
        }
    }

    @Test("A real identifier keeps its own name")
    func realIdentifiersAreUnchanged() {
        for asin in ["B0TEST0001", "B004ZLBCO8", "1508280282", "B086WNG3RK"] {
            #expect(CoverCache.fileName(for: asin) == asin)
        }
    }

    @Test("Two identifiers never share a name")
    func namesDoNotCollide() {
        let names = ["../a", "../b", "a/b", "b/a", "", " "].map(CoverCache.fileName(for:))
        #expect(Set(names).count == names.count)
    }

    @Test("Reading the same cover from everywhere at once gives one answer")
    func concurrentReads() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pixel = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        try pixel.write(to: dir.appendingPathComponent("B0TEST0001.img"))

        let cache = CoverCache(directory: dir)
        let found = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 {
                group.addTask { await cache.image(for: "B0TEST0001", url: nil) != nil }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
        #expect(found == 40)
    }

    @Test("Counting what is cached works for any list of identifiers")
    func countingIsSafe() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = CoverCache(directory: dir)

        #expect(await cache.cachedCount(of: []) == 0)
        #expect(await cache.cachedCount(of: ["", "..", "a/b"]) == 0)
        #expect(await cache.cachedCount(of: (0..<500).map { "B\($0)" }) == 0)
    }

    @Test("A cover fetch from an address that answers nothing is not an error")
    func unreachableCovers() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = CoverCache(directory: dir)

        // A port nothing listens on, and an address that resolves to nothing.
        for text in ["http://127.0.0.1:9/cover.jpg",
                     "https://this-host-does-not-exist.invalid/cover.jpg"] {
            let url = URL(string: text)!
            #expect(await cache.image(for: "B0TEST0002", url: url) == nil)
        }
    }
}
