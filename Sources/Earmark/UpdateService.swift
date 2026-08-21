import Foundation
import AudibleKit

/// One release, as the releases page describes it.
struct Release: Sendable, Hashable {
    let version: AppVersion
    let notes: String

    /// Where its disk image lives.
    ///
    /// Worked out from the version rather than read from a list, so there is
    /// nothing to keep in step.
    var downloadURL: URL {
        URL(string: "https://github.com/\(UpdateService.repository)"
            + "/releases/download/v\(version)/Earmark-\(version).dmg")!
    }

    /// The page a person can read for themselves.
    var pageURL: URL {
        URL(string: "https://github.com/\(UpdateService.repository)/releases/tag/v\(version)")!
    }
}

/// How badly a build behaves.
enum Severity: String, Codable, Sendable, Comparable {
    /// Says so on every launch, and cannot be silenced. Staying on such a
    /// build is not a decision worth remembering.
    case critical
    /// Can be set aside, against that exact version.
    case serious

    var rank: Int { self == .critical ? 1 : 0 }
    static func < (left: Severity, right: Severity) -> Bool { left.rank < right.rank }
}

/// A build that turned out to be harmful.
struct Advisory: Sendable, Hashable {
    /// The exact versions affected. Never a range: a range that is one
    /// character wrong condemns builds that are fine.
    let affects: [AppVersion]
    let severity: Severity
    /// One line, the headline.
    let summary: String
    /// What goes wrong, in full.
    let detail: String
    /// The version that fixes it, when one exists yet.
    let fixedIn: AppVersion?
    /// A version known to be good, to go back to.
    let rollBackTo: AppVersion?

    func covers(_ version: AppVersion) -> Bool { affects.contains(version) }
}

/// Asks what releases exist, and what builds are known to be harmful.
///
/// There is no update server. The releases page is asked what exists, and a
/// download address is worked out from a version. Nothing reports what is
/// installed anywhere: the running version is compared here.
actor UpdateService {
    static let repository = "AbhinavMir/earmark"
    static let advisoriesURL = URL(
        string: "https://abhinavmir.github.io/earmark/advisories.json")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Names this application and its version, and nothing else.
    static func userAgent(for version: AppVersion) -> String {
        "Earmark/\(version)"
    }

    // MARK: Releases

    /// The newest release on `channel` that is newer than `current`.
    func newestRelease(
        after current: AppVersion,
        on channel: UpdateChannel
    ) async throws -> Release? {
        let releases = try await allReleases(reportedAs: current)
        return releases
            .filter { channel.carries($0.version) && $0.version > current }
            .max { $0.version < $1.version }
    }

    /// Every release the page lists, newest first.
    ///
    /// The list is asked for rather than the latest release alone, because the
    /// latest never includes a prerelease and a nightly would be invisible.
    func allReleases(reportedAs version: AppVersion) async throws -> [Release] {
        // Looking needs the network. Nothing else in the application waits on
        // this, so a machine with no network keeps working and simply is not
        // told about newer versions.
        var request = URLRequest(url: URL(
            string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            UpdateService.userAgent(for: version), forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudibleError.downloadFailed("The releases page did not answer.")
        }
        guard http.statusCode == 200 else {
            throw AudibleError.downloadFailed(
                "The releases page answered \(http.statusCode).")
        }
        return UpdateService.releases(from: data)
    }

    static func releases(from data: Data) -> [Release] {
        guard let listed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return listed.compactMap { entry in
            // A draft is not published. A prerelease is: that is what a
            // nightly is, and the channel is decided by the version.
            guard entry["draft"] as? Bool != true,
                  let tag = entry["tag_name"] as? String,
                  let version = AppVersion(tag)
            else { return nil }
            return Release(version: version, notes: entry["body"] as? String ?? "")
        }
        .sorted { $0.version > $1.version }
    }

    // MARK: Advisories

    /// The worst advisory covering `version`, when there is one.
    func advisory(for version: AppVersion) async -> Advisory? {
        var request = URLRequest(url: Self.advisoriesURL)
        request.setValue(
            UpdateService.userAgent(for: version), forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        // Matched here. The list is the same for everybody, and nothing is
        // sent about what is installed.
        return UpdateService.advisories(from: data)
            .filter { $0.covers(version) }
            .max { $0.severity < $1.severity }
    }

    static func advisories(from data: Data) -> [Advisory] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let listed = root["advisories"] as? [[String: Any]]
        else { return [] }

        // A record that cannot be read is left out rather than stopping the
        // rest: one bad entry must not hide a real warning.
        return listed.compactMap { entry in
            let affects = (entry["affects"] as? [String] ?? []).compactMap(AppVersion.init)
            guard !affects.isEmpty,
                  let summary = entry["summary"] as? String, !summary.isEmpty
            else { return nil }

            return Advisory(
                affects: affects,
                severity: Severity(rawValue: entry["severity"] as? String ?? "") ?? .serious,
                summary: summary,
                detail: entry["detail"] as? String ?? summary,
                fixedIn: (entry["fixedIn"] as? String).flatMap(AppVersion.init),
                rollBackTo: (entry["rollBackTo"] as? String).flatMap(AppVersion.init))
        }
    }
}
