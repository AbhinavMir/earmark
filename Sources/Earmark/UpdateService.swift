import Foundation
import AppKit
import AudibleKit

/// One release, as the releases page describes it.
struct Release: Sendable, Hashable {
    let version: AppVersion
    let notes: String
    /// Where its disk image lives. Built from the version rather than read
    /// from a list, so there is nothing to keep in step.
    var downloadURL: URL {
        URL(string: "https://github.com/\(UpdateService.repository)"
            + "/releases/download/v\(version)/Earmark-\(version).dmg")!
    }
}

/// A version that turned out to be harmful, and what to do about it.
struct Recall: Sendable, Hashable, Codable {
    /// The version that is affected.
    let version: AppVersion
    /// What goes wrong, in a sentence a person can act on.
    let reason: String
    /// The version that fixes it, when there is one.
    let fixedIn: AppVersion?
    /// The last version known to be good, to go back to.
    let lastGood: AppVersion?
}

/// Finds out whether a newer version exists, and installs one.
///
/// There is no update server. The releases page is asked what exists, and the
/// address of a disk image is worked out from its version. Nothing reports
/// what is installed anywhere.
actor UpdateService {
    static let repository = "AbhinavMir/earmark"
    /// Where the list of harmful versions lives.
    static let recallsURL = URL(
        string: "https://abhinavmir.github.io/earmark/recalls.json")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Looking

    /// The newest release on `channel` that is newer than `current`.
    func newestRelease(
        after current: AppVersion,
        on channel: UpdateChannel
    ) async throws -> Release? {
        let releases = try await allReleases()
        return releases
            .filter { channel.carries($0.version) && $0.version > current }
            .max { $0.version < $1.version }
    }

    /// Every release the page lists, newest first.
    func allReleases() async throws -> [Release] {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AudibleError.downloadFailed("The releases could not be read.")
        }
        return UpdateService.releases(from: data)
    }

    static func releases(from data: Data) -> [Release] {
        guard let listed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return listed.compactMap { entry in
            guard let tag = entry["tag_name"] as? String,
                  let version = AppVersion(tag),
                  entry["draft"] as? Bool != true
            else { return nil }
            return Release(version: version, notes: entry["body"] as? String ?? "")
        }
        .sorted { $0.version > $1.version }
    }

    // MARK: Recalls

    /// The recall covering `version`, when there is one.
    func recall(for version: AppVersion) async -> Recall? {
        var request = URLRequest(url: Self.recallsURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return UpdateService.recalls(from: data).first { $0.version == version }
    }

    static func recalls(from data: Data) -> [Recall] {
        guard let listed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return listed.compactMap { entry in
            guard let text = entry["version"] as? String,
                  let version = AppVersion(text),
                  let reason = entry["reason"] as? String, !reason.isEmpty
            else { return nil }
            return Recall(
                version: version,
                reason: reason,
                fixedIn: (entry["fixed_in"] as? String).flatMap(AppVersion.init),
                lastGood: (entry["last_good"] as? String).flatMap(AppVersion.init))
        }
    }
}
