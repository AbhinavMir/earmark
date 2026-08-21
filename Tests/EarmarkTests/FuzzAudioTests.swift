import Foundation
import AVFoundation
import Testing
import AudibleKit
@testable import Earmark

/// The audio graph opens files from disk, which can be anything by the time it
/// gets to them.
@Suite("Fuzzing the audio graph")
@MainActor
struct AudioEngineFuzzTests {

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func realAudio(in directory: URL, seconds: Int = 4) throws -> URL? {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { return nil }

        let url = directory.appendingPathComponent("real.m4a")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", String(seconds), "-c:a", "aac", url.path
        ]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? url : nil
    }

    @Test("Opening something that is not audio is refused, never fatal")
    func refusesRubbish() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bodies: [Data] = [
            Data(),
            Data("not audio".utf8),
            Data(repeating: 0, count: 8_192),
            Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]),
            Data((0..<4096).map { UInt8($0 % 256) })
        ]
        let engine = EngineAudio()
        for (index, body) in bodies.enumerated() {
            let file = dir.appendingPathComponent("rubbish\(index).m4a")
            try body.write(to: file)
            #expect(throws: (any Error).self) {
                try engine.load(file, at: 0)
            }
        }
        // A file that is not there at all.
        #expect(throws: (any Error).self) {
            try engine.load(dir.appendingPathComponent("absent.m4a"), at: 0)
        }
    }

    @Test("A real file opens at any place, including past its end")
    func opensAtAnyPlace() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let file = try Self.realAudio(in: dir, seconds: 4) else { return }

        let engine = EngineAudio()
        for place in [0.0, 0.5, 3.9, 4.0, 10, 1e9, -1, -1e9, .infinity, .nan]
            as [TimeInterval] {
            #expect(throws: Never.self, "place: \(place)") {
                try engine.load(file, at: place)
            }
            #expect(engine.duration > 0)
            #expect(engine.position.isFinite, "place: \(place)")
        }
        engine.stop()
    }

    @Test("Seeking anywhere, repeatedly, leaves the graph usable")
    func repeatedSeeks() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let file = try Self.realAudio(in: dir, seconds: 6) else { return }

        let engine = EngineAudio()
        try engine.load(file, at: 0)

        var state: UInt64 = 99
        for _ in 0..<120 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let place = Double(state % 12_000) / 1_000 - 3
            engine.seek(to: place)
            #expect(engine.position.isFinite)
        }
        engine.stop()
    }

    @Test("Settings applied in any order leave the graph usable")
    func effectsInAnyOrder() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let file = try Self.realAudio(in: dir, seconds: 3) else { return }

        let engine = EngineAudio()
        try engine.load(file, at: 0)

        // Every extreme, including values no interface offers, because a
        // stored setting can be edited by hand.
        for value in [Float(0), 0.0001, -1e9, 1e9, .infinity, -.infinity, .nan, 1] {
            var effects = AudioEffects()
            effects.rate = value
            effects.pitch = value
            effects.bass = value
            effects.mid = value
            effects.treble = value
            effects.gain = value
            engine.apply(effects)
        }
        engine.apply(.flat)
        engine.stop()
    }

    @Test("Loading, stopping, and loading again is safe")
    func reloadRepeatedly() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let file = try Self.realAudio(in: dir, seconds: 2) else { return }

        let engine = EngineAudio()
        for _ in 0..<15 {
            try engine.load(file, at: 0)
            engine.stop()
            engine.pause()
            engine.seek(to: 1)
        }
        #expect(engine.duration > 0)
    }

    @Test("A file removed after it opens does not break the graph")
    func fileVanishes() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let file = try Self.realAudio(in: dir, seconds: 2) else { return }

        let engine = EngineAudio()
        try engine.load(file, at: 0)
        try FileManager.default.removeItem(at: file)

        engine.seek(to: 1)
        engine.pause()
        engine.stop()
        #expect(engine.position.isFinite)
    }
}

/// What happens when a value that cannot be written reaches the store.
@Suite("Fuzzing what gets saved")
struct SaveFuzzTests {

    @Test("A place that is not a number never stops the library being saved")
    func nanPositionDoesNotBlockSaving() async throws {
        // JSON has no way to write NaN, so an encoder refuses the whole file.
        // One bad value would then stop every later change being kept.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        await store.merge([
            Book(asin: "A", title: "T", duration: 3_600),
            Book(asin: "B", title: "U", duration: 3_600)
        ])
        await store.setPosition(.nan, for: "A")
        await store.setPosition(1_800, for: "B")

        await #expect(throws: Never.self) { try await store.save() }

        let reloaded = LibraryStore(fileURL: url)
        try await reloaded.load()
        #expect(await reloaded.entries.count == 2)
        #expect(await reloaded.entry("B")?.position == 1_800)
        // Whatever the bad value became, it must be a number.
        let recovered = await reloaded.entry("A")?.position ?? 0
        #expect(recovered.isFinite)
    }

    @Test("A length that is not a number never stops the library being saved")
    func nanDurationDoesNotBlockSaving() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nan2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        await store.merge([Book(asin: "A", title: "T", duration: .nan)])
        await #expect(throws: Never.self) { try await store.save() }

        let reloaded = LibraryStore(fileURL: url)
        try await reloaded.load()
        #expect(await reloaded.entries.count == 1)
    }

    @Test("A bookmark at a place that is not a number is still saved")
    func nanBookmark() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nan3-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        await store.merge([Book(asin: "A", title: "T", duration: 3_600)])
        await store.addBookmark(Bookmark(position: .infinity, note: "far"), to: "A")
        await #expect(throws: Never.self) { try await store.save() }
    }
}
