import Foundation
import Testing
import AudibleKit
@testable import Earmarky

@Suite("Library entry")
struct LibraryEntryTests {

    static func entry(
        position: TimeInterval,
        duration: TimeInterval?,
        finished: Bool = false
    ) -> LibraryEntry {
        LibraryEntry(
            book: Book(asin: "A", title: "T", duration: duration, isFinished: finished),
            position: position)
    }

    @Test("Progress is the heard share of the whole")
    func progressFraction() {
        #expect(Self.entry(position: 1800, duration: 3600).progress == 0.5)
    }

    @Test("A title of unknown length reports no progress rather than zero")
    func unknownLengthHasNoProgress() {
        #expect(Self.entry(position: 100, duration: nil).progress == nil)
    }

    @Test("Progress never passes one, even past the reported end")
    func progressIsCapped() {
        #expect(Self.entry(position: 7200, duration: 3600).progress == 1)
    }

    @Test("A title just started counts as in progress")
    func startedTitleIsInProgress() {
        #expect(Self.entry(position: 300, duration: 3600).isInProgress)
    }

    @Test("An untouched title is not in progress")
    func untouchedTitleIsNotInProgress() {
        #expect(!Self.entry(position: 0, duration: 3600).isInProgress)
    }

    @Test("A title near its end counts as finished, not in progress")
    func nearlyCompleteTitleIsFinished() {
        let entry = Self.entry(position: 3570, duration: 3600)
        #expect(entry.isFinished)
        #expect(!entry.isInProgress)
    }

    @Test("A title Audible marks finished is finished whatever the position")
    func serverFinishedWins() {
        #expect(Self.entry(position: 10, duration: 3600, finished: true).isFinished)
    }

    @Test("An entry with no recorded time has no position to sync")
    func noTimestampMeansNoSyncablePosition() {
        #expect(Self.entry(position: 500, duration: 3600).listeningPosition == nil)
    }

    @Test("A downloaded entry knows it has a file")
    func downloadState() {
        var entry = Self.entry(position: 0, duration: 3600)
        #expect(!entry.isDownloaded)
        entry.fileName = "Ada Marsh/T.m4b"
        #expect(entry.isDownloaded)
    }
}

@Suite("Progress shown to a listener")
struct ProgressTextTests {

    static func entry(position: TimeInterval, duration: TimeInterval?) -> LibraryEntry {
        LibraryEntry(
            book: Book(asin: "A", title: "T", duration: duration),
            position: position)
    }

    @Test("Progress reads as a percentage")
    func percentText() {
        #expect(Self.entry(position: 1800, duration: 3600).percentText == "50%")
    }

    @Test("A title barely started reads as one percent, not none")
    func neverRoundsDownToZero() {
        // Zero would say "untouched", which is a different thing.
        #expect(Self.entry(position: 5, duration: 3600).percentText == "1%")
    }

    @Test("An untouched title has no percentage to show")
    func untouchedHasNoPercent() {
        #expect(Self.entry(position: 0, duration: 3600).percentText == nil)
    }

    @Test("What is left reads as hours and minutes")
    func remainingText() {
        #expect(Self.entry(position: 3600, duration: 3600 * 4).remainingText == "3h 0m")
        #expect(Self.entry(position: 0, duration: 1500).remainingText == "25m")
    }

    @Test("A finished title has nothing left to show")
    func finishedHasNoRemaining() {
        #expect(Self.entry(position: 3600, duration: 3600).remainingText == nil)
    }

    @Test("A title of unknown length shows neither figure")
    func unknownLength() {
        let entry = Self.entry(position: 100, duration: nil)
        #expect(entry.percentText == nil)
        #expect(entry.remainingText == nil)
        #expect(entry.remaining == nil)
    }

    @Test("Past the end, nothing is left rather than a negative")
    func neverNegative() {
        #expect(Self.entry(position: 7200, duration: 3600).remaining == 0)
    }
}

@Suite("Sound settings")
struct AudioEffectsTests {

    @Test("Flat settings change nothing")
    func flatIsFlat() {
        #expect(AudioEffects.flat.isFlat)
        #expect(!AudioEffects.flat.needsEngine)
    }

    @Test("Speed alone does not need the engine")
    func speedAloneStaysOnAVPlayer() {
        // Speed works on a stream. Pitch and tone need a file.
        var effects = AudioEffects()
        effects.rate = 2.0
        #expect(!effects.needsEngine)
        #expect(!effects.isFlat)
    }

    @Test("Pitch and tone need the engine")
    func toneNeedsEngine() {
        var effects = AudioEffects()
        effects.pitch = 100
        #expect(effects.needsEngine)

        var tone = AudioEffects()
        tone.treble = 3
        #expect(tone.needsEngine)
    }

    @Test("Every preset stays inside the ranges the interface offers")
    func presetsAreInRange() {
        for preset in AudioEffects.presets {
            let e = preset.effects
            #expect(AudioEffects.rateRange.contains(e.rate))
            #expect(AudioEffects.pitchRange.contains(e.pitch))
            #expect(AudioEffects.bandRange.contains(e.bass))
            #expect(AudioEffects.bandRange.contains(e.mid))
            #expect(AudioEffects.bandRange.contains(e.treble))
            #expect(AudioEffects.gainRange.contains(e.gain))
        }
    }

    @Test("The first preset is the one that changes nothing")
    func firstPresetIsFlat() {
        #expect(AudioEffects.presets.first?.effects.isFlat == true)
    }
}
