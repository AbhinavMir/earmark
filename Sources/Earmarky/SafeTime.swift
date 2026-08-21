import Foundation

/// Turning a length into text, safely.
///
/// AVFoundation reports a duration of NaN for an item whose length it does not
/// know yet, and infinity for a live one. Converting either to an integer ends
/// the process, so nothing here does that without checking first.
enum SafeTime {

    /// A number that can be shown, or nil when it cannot.
    static func usable(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, !value.isNaN else { return nil }
        // Beyond this a length is not a length. A day of audio is already far
        // past any real audiobook.
        guard value >= 0, value < 60 * 60 * 24 * 30 else { return nil }
        return value
    }

    /// Whole seconds, clamped, for arithmetic that cannot take NaN.
    static func seconds(_ value: TimeInterval) -> Int {
        guard let usable = usable(value) else { return 0 }
        return Int(usable)
    }

    /// A clock reading: hours only when there are hours.
    static func clock(_ value: TimeInterval) -> String {
        let total = seconds(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// A length as hours and minutes, which is how a listener judges a book.
    static func hoursAndMinutes(_ value: TimeInterval) -> String {
        let total = seconds(value) / 60
        let hours = total / 60
        let minutes = total % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// A share from 0 to 1, or nil when it cannot be worked out.
    static func fraction(_ part: TimeInterval, of whole: TimeInterval?) -> Double? {
        guard let whole = usable(whole), whole > 0 else { return nil }
        guard let part = usable(part) else { return nil }
        return min(1, max(0, part / whole))
    }

    /// A range a slider can take. A slider given NaN ends the process.
    static func sliderRange(_ upper: TimeInterval) -> ClosedRange<Double> {
        0...max(1, usable(upper) ?? 1)
    }
}
