import Foundation

/// A version of the application.
///
/// Three numbers, each with a meaning. The first moves when the shape of the
/// application changes. The middle moves for a finished release. The last
/// moves for a night's work.
struct AppVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    /// True when this is a finished release rather than a night's work.
    var isSequential: Bool { patch == 0 }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads a version from a tag or a name.
    ///
    /// Accepts `vX.Y.Z`, `X.Y.Z`, `X.Y`, and `X`, and stops at a dash so that
    /// `1.2.3-beta1` reads as `1.2.3`. Anything else is not a version and
    /// gives nothing: a tag nobody can read is not a reason to tell somebody
    /// to upgrade.
    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[text.startIndex..<dash]) }
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            // Digits alone. "1.2.3rc" is not a number, and guessing at it is
            // how a build nobody meant to ship reaches somebody.
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else {
                return nil
            }
            numbers.append(value)
        }
        self.init(
            major: numbers[0],
            minor: numbers.count > 1 ? numbers[1] : 0,
            patch: numbers.count > 2 ? numbers[2] : 0)
    }

    /// Compared as numbers, in turn.
    ///
    /// Comparing the text says 1.10.0 is older than 1.9.0, which is the oldest
    /// mistake in this area.
    static func < (left: AppVersion, right: AppVersion) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }

    /// The version this copy of the application was built as.
    static var current: AppVersion {
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        return AppVersion(text) ?? AppVersion(major: 0, minor: 0, patch: 0)
    }
}

/// Which releases a person is offered.
enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    /// Finished work, for everybody.
    case stable
    /// The day's work, for people who want it early.
    case nightly

    var title: String {
        switch self {
        case .stable: return "Sequential releases"
        case .nightly: return "Nightly builds"
        }
    }

    var explanation: String {
        switch self {
        case .stable:
            return "Finished work. The middle number moves, as in 1.3.0."
        case .nightly:
            return "The day's work as well, as in 1.3.1. Newer, and less settled."
        }
    }

    /// How long to leave between looking.
    var interval: TimeInterval {
        switch self {
        case .stable: return 60 * 60 * 24
        case .nightly: return 60 * 60 * 6
        }
    }

    /// True when a release belongs on this channel.
    ///
    /// Decided by the version, never by whether the release is marked as a
    /// prerelease. A finished release marked that way while it is tried out is
    /// still a finished release.
    func carries(_ version: AppVersion) -> Bool {
        switch self {
        case .stable: return version.isSequential
        case .nightly: return true
        }
    }
}
