import Foundation
import AVFoundation

/// Plays a local file through an audio graph, so speed, pitch, and tone can be
/// changed while it plays.
///
/// `AVPlayer` changes speed and nothing else. Pitch and tone need the audio to
/// pass through units that can work on it, which means a file rather than a
/// stream.
@MainActor
final class EngineAudio {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 3)

    private var file: AVAudioFile?
    /// Frame the current segment started at. Position is measured from here,
    /// because the node's clock restarts on every scheduled segment.
    private var segmentStart: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100

    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false

    /// Called when the file reaches its end.
    var onFinish: (() -> Void)?

    init() {
        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(equalizer)

        // Speech stays intelligible at speed with this algorithm.
        timePitch.overlap = 8

        equalizer.bands[0].filterType = .lowShelf
        equalizer.bands[0].frequency = 120
        equalizer.bands[1].filterType = .parametric
        equalizer.bands[1].frequency = 1_000
        equalizer.bands[1].bandwidth = 1.2
        equalizer.bands[2].filterType = .highShelf
        equalizer.bands[2].frequency = 6_000
        for band in equalizer.bands {
            band.bypass = false
            band.gain = 0
        }
    }

    /// Opens a file and prepares the graph for it.
    func load(_ url: URL, at position: TimeInterval) throws {
        stop()

        let file = try AVAudioFile(forReading: url)
        self.file = file
        sampleRate = file.processingFormat.sampleRate
        duration = Double(file.length) / sampleRate

        engine.connect(node, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: equalizer, format: file.processingFormat)
        engine.connect(equalizer, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()

        schedule(from: position)
    }

    /// Points the graph at a place in the file.
    private func schedule(from position: TimeInterval) {
        guard let file else { return }
        let start = AVAudioFramePosition(max(0, position) * sampleRate)
        guard start < file.length else {
            onFinish?()
            return
        }
        let frames = AVAudioFrameCount(file.length - start)

        segmentStart = start
        node.stop()
        node.scheduleSegment(
            file,
            startingFrame: start,
            frameCount: frames,
            at: nil
        ) { [weak self] in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                // The callback also fires on a stop, so only an end that
                // arrives while playing is the end of the book.
                if self.position >= self.duration - 0.5 {
                    self.isPlaying = false
                    self.onFinish?()
                }
            }
        }
    }

    // MARK: Transport

    func play() throws {
        guard file != nil else { return }
        if !engine.isRunning { try engine.start() }
        node.play()
        isPlaying = true
    }

    func pause() {
        node.pause()
        isPlaying = false
    }

    func stop() {
        node.stop()
        engine.stop()
        isPlaying = false
        segmentStart = 0
    }

    func seek(to position: TimeInterval) {
        let wasPlaying = isPlaying
        schedule(from: position)
        if wasPlaying {
            try? play()
        }
    }

    /// Where the file is now, measured from its start.
    var position: TimeInterval {
        guard let time = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: time)
        else {
            return Double(segmentStart) / sampleRate
        }
        return Double(segmentStart + played.sampleTime) / played.sampleRate
    }

    // MARK: Effects

    /// Applies the current settings. Safe to call while playing.
    func apply(_ effects: AudioEffects) {
        timePitch.rate = max(1.0 / 32, min(32, effects.rate))
        timePitch.pitch = effects.pitch
        equalizer.bands[0].gain = effects.bass
        equalizer.bands[1].gain = effects.mid
        equalizer.bands[2].gain = effects.treble
        equalizer.globalGain = effects.gain
    }
}
