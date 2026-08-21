import Foundation
import AVFoundation
import MediaPlayer
import AudibleKit

/// Plays one title, either from a downloaded file or from a stream.
///
/// The player owns playback only. It reports where it is; deciding what to do
/// with that position belongs to `AppModel`.
@MainActor
@Observable
final class Player {

    /// Where the audio comes from.
    enum Source: Equatable {
        /// A decrypted file on this Mac. Seeking anywhere is free.
        case file(URL)
        /// A stream that begins partway into the title. Its zero is the
        /// offset, so every reported position adds it back.
        case stream(offset: TimeInterval)

        var isStream: Bool {
            if case .stream = self { return true }
            return false
        }

        var offset: TimeInterval {
            if case .stream(let offset) = self { return offset }
            return 0
        }
    }

    private(set) var entry: LibraryEntry?
    private(set) var source: Source?
    private(set) var isPlaying = false
    /// Position within the whole title, not within the stream.
    private(set) var position: TimeInterval = 0
    /// Length of the whole title.
    private(set) var duration: TimeInterval = 0
    /// True while the player has no audio ready to play.
    ///
    /// This comes from the player itself rather than from a guess, so it
    /// clears the moment sound starts and returns if the stream runs dry.
    private(set) var isBuffering = false
    /// How much of the title is ready to play, from 0 to 1. Nil when the
    /// length is unknown.
    private(set) var bufferedFraction: Double?

    /// How the audio is shaped. Speed works everywhere; the rest needs the
    /// engine, which needs a downloaded file.
    var effects = AudioEffects() {
        didSet {
            engine.apply(effects)
            if isPlaying, !usingEngine { player.rate = effects.rate }
            if effects.needsEngine, !usingEngine, canUseEngine {
                switchToEngine()
            }
            updateNowPlaying()
        }
    }

    /// Speed on its own, which every source supports.
    var rate: Float {
        get { effects.rate }
        set { effects.rate = newValue }
    }

    /// True when tone and pitch can be changed for what is loaded.
    var canUseEngine: Bool {
        if case .file = source { return true }
        return false
    }

    /// True while the graph is doing the playing rather than AVPlayer.
    private(set) var usingEngine = false

    var skipForward: TimeInterval = 30
    var skipBackward: TimeInterval = 15

    private(set) var sleepDeadline: Date?

    /// Called as the position changes, so the model can record it.
    var onPositionChange: ((String, TimeInterval) -> Void)?
    /// Called when a title reaches its end.
    var onFinish: ((String) -> Void)?
    /// Called when a seek leaves what the stream holds, with the wanted
    /// position. The model restarts the stream there.
    var onSeekBeyondStream: ((String, TimeInterval) -> Void)?

    private let player = AVPlayer()
    private let engine = EngineAudio()
    private var engineTicker: Timer?
    private var fileURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservers: [NSKeyValueObservation] = []

    init() {
        player.actionAtItemEnd = .pause
        engine.onFinish = { [weak self] in self?.finish() }
        configureRemoteCommands()
    }

    // MARK: Loading

    /// Loads a title from `url`, which is either a local file or a playlist.
    func load(_ entry: LibraryEntry, url: URL, source: Source) {
        teardownObservers()
        stopEngine()
        fileURL = { if case .file = source { return url } else { return nil } }()

        let item = AVPlayerItem(url: url)
        // Speech stays intelligible at high rates with this algorithm.
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)

        self.entry = entry
        self.source = source
        self.duration = entry.book.duration ?? 0
        self.position = source.offset
        self.isBuffering = true
        self.bufferedFraction = nil

        if case .file = source {
            // A position at or past the end restarts the title rather than
            // leaving the listener on the final second.
            let start = entry.position < (entry.book.duration ?? .infinity) - 5
                ? entry.position : 0
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            position = start
        }

        observe(item)
        updateNowPlaying()
    }

    func unload() {
        pause()
        stopEngine()
        teardownObservers()
        player.replaceCurrentItem(with: nil)
        entry = nil
        source = nil
        position = 0
        duration = 0
        isBuffering = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Transport

    func play() {
        guard entry != nil else { return }
        if usingEngine {
            try? engine.play()
            isPlaying = true
            startEngineTicker()
            updateNowPlaying()
            return
        }
        // Playing as soon as the buffer allows, rather than stalling silently
        // when it does not.
        player.automaticallyWaitsToMinimizeStalling = true
        player.rate = rate
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        if usingEngine {
            engine.pause()
        } else {
            player.pause()
        }
        isPlaying = false
        reportPosition()
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Moves to `seconds` measured from the start of the title.
    func seek(to seconds: TimeInterval) {
        guard let entry, let source else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))

        switch source {
        case .file where usingEngine:
            engine.seek(to: target)
            position = target
            reportPosition()
            updateNowPlaying()

        case .file:
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero)
            position = target
            reportPosition()
            updateNowPlaying()

        case .stream(let offset):
            // The stream holds only what it has written since it started.
            // Anything outside that needs a stream that begins there.
            let withinStream = target - offset
            if withinStream >= 0, withinStream <= loadedStreamSeconds() {
                player.seek(to: CMTime(seconds: withinStream, preferredTimescale: 600))
                position = target
                reportPosition()
                updateNowPlaying()
            } else {
                isBuffering = true
                onSeekBeyondStream?(entry.book.asin, target)
            }
        }
    }

    func skipAhead() { seek(to: position + skipForward) }
    func skipBack() { seek(to: position - skipBackward) }

    /// Works out how much of the title is ready to play.
    private func updateBufferedFraction() {
        guard duration > 0, let source else {
            bufferedFraction = nil
            return
        }
        let ready = source.offset + loadedStreamSeconds()
        bufferedFraction = min(1, ready / duration)
    }

    /// How many seconds the stream has ready from its own start.
    private func loadedStreamSeconds() -> TimeInterval {
        guard let ranges = player.currentItem?.loadedTimeRanges, let last = ranges.last else {
            return 0
        }
        let range = last.timeRangeValue
        return CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
    }

    // MARK: Chapters

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

    func setSleepTimer(_ interval: TimeInterval?) {
        guard let interval else {
            sleepDeadline = nil
            return
        }
        sleepDeadline = Date().addingTimeInterval(interval)
    }

    func sleepAtEndOfChapter() {
        guard let chapter = currentChapter else { return }
        setSleepTimer(max(1, chapter.end - position))
    }

    // MARK: Observation

    private func observe(_ item: AVPlayerItem) {
        // The player knows whether it can keep playing. Asking it beats
        // inferring from elapsed time, which reports "loading" over audio that
        // is already playing.
        statusObservers = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    self.isPlaying = player.timeControlStatus == .playing
                    self.updateNowPlaying()
                }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    guard let self, item.isPlaybackLikelyToKeepUp else { return }
                    self.isBuffering = false
                }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.updateBufferedFraction()
                }
            }
        ]

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(CMTimeGetSeconds(time))
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish()
            }
        }
    }

    // MARK: The engine

    /// Moves playback onto the graph, keeping the place and whether it plays.
    ///
    /// The graph gives pitch and tone, which AVPlayer cannot do. It is only
    /// used when asked for, because it needs a file and gives nothing extra
    /// when the settings are flat.
    private func switchToEngine() {
        guard let fileURL, let entry, !usingEngine else { return }
        let resumeAt = position
        let wasPlaying = isPlaying

        player.pause()
        do {
            try engine.load(fileURL, at: resumeAt)
            engine.apply(effects)
            usingEngine = true
            duration = entry.book.duration ?? engine.duration
            position = resumeAt
            isBuffering = false
            if wasPlaying { try engine.play(); isPlaying = true; startEngineTicker() }
        } catch {
            // The file could not be opened by the graph. AVPlayer keeps it.
            usingEngine = false
            if wasPlaying { player.rate = effects.rate }
        }
    }

    private func stopEngine() {
        engineTicker?.invalidate()
        engineTicker = nil
        engine.stop()
        usingEngine = false
    }

    /// The graph has no time observer, so the position is read on a timer.
    private func startEngineTicker() {
        engineTicker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.usingEngine, self.isPlaying else { return }
                self.tickEngine()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        engineTicker = timer
    }

    private func tickEngine() {
        position = min(engine.position, duration > 0 ? duration : engine.duration)
        if let deadline = sleepDeadline, Date() >= deadline {
            sleepDeadline = nil
            pause()
            return
        }
        if Int(position) % 30 == 0 { reportPosition() }
    }

    private func teardownObservers() {
        statusObservers.forEach { $0.invalidate() }
        statusObservers.removeAll()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func tick(_ elapsed: TimeInterval) {
        guard let source else { return }
        position = source.offset + elapsed

        // A title of unknown length takes the length the player reports once
        // it knows it, rather than staying at zero.
        if duration <= 0, case .file = source,
           let itemDuration = player.currentItem?.duration,
           itemDuration.isNumeric {
            duration = CMTimeGetSeconds(itemDuration)
        }

        if let deadline = sleepDeadline, Date() >= deadline {
            sleepDeadline = nil
            pause()
            return
        }
        if Int(position) % 30 == 0 { reportPosition() }
    }

    private func finish() {
        isPlaying = false
        guard let asin = entry?.book.asin else { return }
        // A stream ends every time its written part runs out, which is not the
        // end of the book. Only a file that reaches its end is finished.
        if source?.isStream == true, duration > 0, position < duration - 5 {
            isBuffering = true
            onSeekBeyondStream?(asin, position)
            return
        }
        position = duration
        onPositionChange?(asin, duration)
        onFinish?(asin)
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
