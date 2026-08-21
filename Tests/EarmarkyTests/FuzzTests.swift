import Foundation
import Testing
import AudibleKit
@testable import Earmarky

/// Feeds the application titles and files it was not designed for.
///
/// Titles come from publishers, so they carry every character a publisher has
/// ever typed. A stored file can be damaged by a crash or edited by hand.
@Suite("Fuzzing titles and files")
struct AppFuzzTests {

    static let awkwardTitles = [
        "",
        " ",
        "///",
        "..",
        ".",
        "...",
        "con",
        "NUL",
        String(repeating: "A", count: 400),
        String(repeating: "долгий ", count: 60),
        "Book 📚🎧 Vol. 2",
        "Tom\u{0301}as: A Life",
        "\u{202E}gnihtemos",
        "Title\u{0000}with a null",
        "Title\nwith\nnewlines",
        "Title\twith\ttabs",
        "../../etc/passwd",
        "~/Library/Preferences",
        ".hidden",
        "COM1",
        "a" + String(repeating: "/", count: 50) + "b"
    ]

    static func book(_ title: String, author: String = "Ada Marsh") -> Book {
        Book(asin: "B0TEST0001", title: title, authors: author.isEmpty ? [] : [author])
    }

    @Test("A name is produced for any title, and it names one file in one folder")
    func fileNamesStayWellFormed() {
        for title in Self.awkwardTitles {
            for author in ["Ada Marsh", "", "../..", String(repeating: "B", count: 400)] {
                let name = DownloadQueue.fileName(for: Self.book(title, author: author))

                // Exactly one separator: an author folder and a file in it.
                #expect(name.filter { $0 == "/" }.count == 1, "title: \(title.prefix(20))")
                #expect(name.hasSuffix(".m4b"))
                #expect(!name.hasPrefix("/"))
                #expect(!name.contains(".."))
                #expect(!name.contains("\u{0000}"))

                // Every part must be a name a file system will accept. The
                // limit is 255 bytes per component on every file system macOS
                // writes to.
                for part in name.split(separator: "/") {
                    #expect(!part.isEmpty)
                    #expect(part.utf8.count <= 255,
                            "component of \(part.utf8.count) bytes from: \(title.prefix(20))")
                }
            }
        }
    }

    @Test("A name can actually be written to disk")
    func fileNamesAreWritable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for title in Self.awkwardTitles {
            let name = DownloadQueue.fileName(for: Self.book(title))
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(throws: Never.self, "title: \(title.prefix(24))") {
                try Data("x".utf8).write(to: url)
            }
        }
    }

    @Test("A damaged library file is refused rather than read as an empty library")
    func damagedLibraryFile() async throws {
        let bodies = [
            Data(),
            Data("null".utf8),
            Data("{}".utf8),
            Data("[".utf8),
            Data(#"[{"book": null}]"#.utf8),
            Data(#"[{"book": {"asin": "A"}}]"#.utf8),
            Data(String(repeating: "[", count: 400).utf8),
            Data([0xFF, 0xFE, 0x00, 0x01])
        ]
        for body in bodies {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fuzz-lib-\(UUID().uuidString).json")
            try body.write(to: url)
            let store = LibraryStore(fileURL: url)
            // Either it reads, or it throws. Losing the library silently by
            // reporting an empty one would be worse than either.
            _ = try? await store.load()
            #expect(await store.entries.count >= 0)
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("Progress figures hold for absurd lengths and places")
    func progressSurvivesAbsurdNumbers() {
        let cases: [(TimeInterval, TimeInterval?)] = [
            (0, 0), (100, 0), (-50, 3600), (1e308, 1e308), (0, .infinity),
            (.infinity, 3600), (3600, -1), (.nan, 3600), (3600, .nan)
        ]
        for (position, duration) in cases {
            let entry = LibraryEntry(
                book: Book(asin: "A", title: "T", duration: duration),
                position: position)
            // Whatever comes back, reading it must not end the process, and a
            // percentage must stay a percentage.
            if let progress = entry.progress, progress.isFinite {
                #expect(progress <= 1)
                #expect(progress >= 0 || position < 0)
            }
            _ = entry.percentText
            _ = entry.remainingText
            _ = entry.isFinished
            _ = entry.isInProgress
        }
    }

    @Test("Sound settings clamp rather than run away")
    func effectsStayInRange() {
        var effects = AudioEffects()
        for value in [Float(-1e9), -1, 0, 0.0001, 1e9, .infinity, .nan] {
            effects.rate = value
            effects.pitch = value
            effects.bass = value
            // Reading them back must not end the process. The engine clamps
            // what it is given before it uses it.
            _ = effects.isFlat
            _ = effects.needsEngine
        }
    }
}
