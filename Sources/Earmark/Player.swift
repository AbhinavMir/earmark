import Foundation
import AVFoundation
import MediaPlayer
import AudibleKit

/// Plays one downloaded title.
///
/// The player owns playback only. It reports where it is; deciding what to do
/// with that position belongs to `AppModel`.
@MainActor
@Observable
final class Player: NSObject {
    /// The title now loaded, if any.
    private(set) var entry: LibraryEntry?
    private(set) var isPlaying = false
    /// Current offset from the start of the title.
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var rate: Float = 1.0 {
        didSet {
            player?.rate = rate
            if !isPlaying { player?.pause() }
            updateNowPlaying()
        }
    }

    /// Seconds a forward skip moves.
    var skipForward: TimeInterval = 30
    /// Seconds a backward skip moves.
    var skipBackward: TimeInterval = 15

    /// When set, playback stops at this moment.
    private(set) var sleepDeadline: Date?

    /// Called every time the position changes, so the model can record it.
    var onPositionChange: ((String, TimeInterval) -> Void)?
    /// Called when a title reaches its end.
    var onFinish: ((String) -> Void)?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    override init() {
        super.init()
        configureRemoteCommands()
    }

    // MARK: Loading

    /// Loads a downloaded title and seeks to its stored position.
    func load(_ entry: LibraryEntry, fileURL: URL) throws {
        stopTicker()
        let player = try AVAudioPlayer(contentsOf: fileURL)
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        // A position at or past the end restarts the title rather than
        // dropping the listener at the final second.
        player.currentTime = entry.position < player.duration - 1 ? entry.position : 0

        self.player = player
        self.entry = entry
        self.duration = player.duration
        self.position = player.currentTime
        updateNowPlaying()
    }

    func unload() {
        pause()
        player = nil
        entry = nil
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Transport

    func play() {
        guard let player else { return }
        player.play()
        player.rate = rate
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        reportPosition()
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(seconds, player.duration))
        position = player.currentTime
        reportPosition()
        updateNowPlaying()
    }

    func skipAhead() { seek(to: position + skipForward) }
    func skipBack() { seek(to: position - skipBackward) }

    // MARK: Chapters

    /// The chapter covering the current position.
    var currentChapter: Chapter? {
        entry?.chapters.last { $0.start <= position }
    }

    func jump(to chapter: Chapter) {
        seek(to: chapter.start)
    }

    func nextChapter() {
        guard let next = entry?.chapters.first(where: { $0.start > position + 1 }) else { return }
        seek(to: next.start)
    }

    func previousChapter() {
        guard let chapters = entry?.chapters else { return }
        // Within the first seconds of a chapter, go back to the one before it.
        // Later in a chapter, go to that chapter's start.
        let current = chapters.last { $0.start <= position }
        if let current, position - current.start > 3 {
            seek(to: current.start)
            return
        }
        guard let previous = chapters.last(where: { $0.start < (current?.start ?? position) })
        else {
            seek(to: 0)
            return
        }
        seek(to: previous.start)
    }

    // MARK: Sleep timer

    /// Stops playback after `interval`. Pass nil to cancel.
    func setSleepTimer(_ interval: TimeInterval?) {
        guard let interval else {
            sleepDeadline = nil
            return
        }
        sleepDeadline = Date().addingTimeInterval(interval)
    }

    /// Stops at the end of the chapter now playing.
    func sleepAtEndOfChapter() {
        guard let chapter = currentChapter else { return }
        setSleepTimer(max(1, chapter.end - position))
    }

    // MARK: Position reporting

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        position = player.currentTime

        if let deadline = sleepDeadline, Date() >= deadline {
            sleepDeadline = nil
            pause()
            return
        }
        // Record every 30 seconds of playback, not every tick.
        if Int(position) % 30 == 0 { reportPosition() }
    }

    private func reportPosition() {
        guard let asin = entry?.book.asin else { return }
        onPositionChange?(asin, position)
    }

    // MARK: System integration

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipAhead() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBack() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextChapter() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousChapter() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let entry else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: entry.book.title,
            MPMediaItemPropertyArtist: entry.book.authorLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0
        ]
        if let chapter = currentChapter {
            info[MPMediaItemPropertyAlbumTitle] = chapter.title
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension Player: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            stopTicker()
            if let asin = entry?.book.asin {
                position = duration
                onPositionChange?(asin, duration)
                onFinish?(asin)
            }
        }
    }
}
