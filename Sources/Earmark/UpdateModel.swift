import Foundation
import SwiftUI
import AudibleKit

/// What the application knows about newer versions of itself.
@MainActor
@Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case looking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// A recall covering the running version, when there is one.
    private(set) var recall: Recall?
    /// The version this copy was built as.
    let current = AppVersion.current

    /// Which versions to be offered. Kept between launches.
    var channel: UpdateChannel {
        get { UpdateChannel(rawValue: channelName) ?? .stable }
        set { channelName = newValue.rawValue }
    }

    @ObservationIgnored
    @AppStorage("updateChannel") private var channelName = UpdateChannel.stable.rawValue
    /// Whether to look on launch. Looking is not installing.
    @ObservationIgnored
    @AppStorage("checkForUpdatesOnLaunch") var checksOnLaunch = true
    /// Whether to install what is found without asking.
    @ObservationIgnored
    @AppStorage("installUpdatesAutomatically") var installsAutomatically = false

    private let service: UpdateService
    private let installer: Installer

    init(service: UpdateService = UpdateService(), installer: Installer = Installer()) {
        self.service = service
        self.installer = installer
    }

    /// Runs on launch: the recall list always, a look for newer versions when
    /// asked for.
    ///
    /// The recall check is not a preference. A warning nobody switched on
    /// warns nobody.
    func onLaunch() async {
        recall = await service.recall(for: current)
        if checksOnLaunch { await check(announceUpToDate: false) }
    }

    /// Looks for something newer on the chosen channel.
    func check(announceUpToDate: Bool = true) async {
        state = .looking
        do {
            guard let release = try await service.newestRelease(
                after: current, on: channel) else {
                state = announceUpToDate ? .upToDate : .idle
                return
            }
            state = .available(release)
            if installsAutomatically { await install(release) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Fetches, checks, and puts a release in place.
    func install(_ release: Release) async {
        state = .installing("Fetching \(release.version)...")
        do {
            try await installer.install(release) { step in
                Task { @MainActor in
                    switch step {
                    case .fetching(let fraction):
                        self.state = .installing(
                            fraction.map { "Fetching \(Int($0 * 100))%" } ?? "Fetching...")
                    case .checking:
                        self.state = .installing("Checking the signature...")
                    case .replacing:
                        self.state = .installing("Putting it in place...")
                    case .done:
                        self.state = .installing("Restarting...")
                    }
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Installs the version a recall names as the fix.
    func installRecallFix() async {
        guard let version = recall?.fixedIn else { return }
        await install(Release(version: version, notes: ""))
    }

    /// Goes back to the last version known to be good.
    func installLastGood() async {
        guard let version = recall?.lastGood else { return }
        await install(Release(version: version, notes: ""))
    }
}
