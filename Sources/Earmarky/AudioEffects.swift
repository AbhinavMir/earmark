import Foundation

/// How the audio is shaped on the way out.
///
/// Speed is separate from pitch: a book read too slowly should speed up
/// without the narrator turning into a chipmunk, which is what the two
/// controls are for.
struct AudioEffects: Codable, Hashable, Sendable {
    /// Playback speed, where 1 is as recorded.
    var rate: Float = 1.0
    /// Pitch shift in cents. 100 cents is one semitone.
    var pitch: Float = 0
    /// Low shelf, in decibels. Warmth, or the lack of it.
    var bass: Float = 0
    /// Mid band, in decibels. Where a voice sits.
    var mid: Float = 0
    /// High shelf, in decibels. Air and sibilance.
    var treble: Float = 0
    /// Extra gain in decibels, for a recording that is simply quiet.
    var gain: Float = 0

    static let flat = AudioEffects()

    /// Ranges the interface offers. Wider than this stops sounding like speech.
    static let rateRange: ClosedRange<Float> = 0.5...3.0
    static let pitchRange: ClosedRange<Float> = -600...600
    static let bandRange: ClosedRange<Float> = -12...12
    static let gainRange: ClosedRange<Float> = -6...12

    /// True when nothing is being changed.
    var isFlat: Bool {
        rate == 1 && pitch == 0 && bass == 0 && mid == 0 && treble == 0 && gain == 0
    }

    /// True when anything other than speed is being changed.
    ///
    /// Speed alone works on a stream. The rest needs the engine, which needs a
    /// file.
    var needsEngine: Bool {
        pitch != 0 || bass != 0 || mid != 0 || treble != 0 || gain != 0
    }

    /// Named starting points.
    static let presets: [(name: String, effects: AudioEffects)] = [
        ("Flat", .flat),
        ("Voice", AudioEffects(rate: 1, pitch: 0, bass: -2, mid: 3, treble: 1, gain: 2)),
        ("Warm", AudioEffects(rate: 1, pitch: 0, bass: 4, mid: 0, treble: -2)),
        ("Bright", AudioEffects(rate: 1, pitch: 0, bass: -1, mid: 1, treble: 4)),
        ("Quiet room", AudioEffects(rate: 1, pitch: 0, bass: -4, mid: 2, treble: 0, gain: 4))
    ]
}
