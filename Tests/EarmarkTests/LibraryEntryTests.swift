import Foundation
import Testing
import AudibleKit
@testable import Earmark

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
