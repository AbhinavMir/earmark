import Foundation

/// A version of the application.
///
/// The numbers carry the meaning. The middle one is a finished release; the
/// last one is a night's work. So 1.3.0 is finished and 1.2.1 is the day's.
struct AppVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    /// True when this is a finished release rather than a night's work.
    var isStable: Bool { patch == 0 }

    /// Which channel this version belongs to.
    var channel: UpdateChannel { isStable ? .stable : .nightly }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads "1.2.3", or "v1.2.3" as a release names it.
    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        let numbers = parts.map { Int($0) }
        guard let major = numbers[0], let minor = numbers[1], let patch = numbers[2],
              major >= 0, minor >= 0, patch >= 0
        else { return nil }

        self.init(major: major, minor: minor, patch: patch)
    }

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

/// Which versions a person wants to be offered.
enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    /// Finished releases alone.
    case stable
    /// Everything, including a night's work.
    case nightly

    var title: String {
        switch self {
        case .stable: return "Stable"
        case .nightly: return "Nightly"
        }
    }

    var explanation: String {
        switch self {
        case .stable: return "Finished releases only."
        case .nightly: return "Every build, including unfinished work."
        }
    }

    /// True when a version belongs on this channel.
    func carries(_ version: AppVersion) -> Bool {
        switch self {
        case .stable: return version.isStable
        case .nightly: return true
        }
    }
}
