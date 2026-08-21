import Foundation
import SwiftUI
import AppKit
import AudibleKit

/// What the application knows about other versions of itself.
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
    /// The advisory covering the running version, when there is one.
    private(set) var advisory: Advisory?
    /// Set when an install that nobody asked for went wrong, so it can be
    /// offered by hand instead of failing quietly.
    private(set) var offerAfterFailure: Release?

    let current = AppVersion.current

    // MARK: Settings

    /// Whether to look at all. Nothing is asked for while this is off.
    @ObservationIgnored
    @AppStorage("checksForUpdates") var checksForUpdates = false
    /// Whether to put what it finds in place without asking.
    @ObservationIgnored
    @AppStorage("installsWithoutAsking") var installsWithoutAsking = false
    /// Whether to warn about builds known to be harmful. On, because a warning
    /// nobody switched on warns nobody.
    @ObservationIgnored
    @AppStorage("warnsAboutFaultyBuilds") var warnsAboutFaultyBuilds = true

    @ObservationIgnored
    @AppStorage("updateChannel") private var channelName = UpdateChannel.stable.rawValue
    @ObservationIgnored
    @AppStorage("lastUpdateCheck") private var lastCheck: Double = 0
    @ObservationIgnored
    @AppStorage("skippedVersion") private var skippedVersion = ""
    @ObservationIgnored
    @AppStorage("dismissedAdvisory") private var dismissedAdvisory = ""

    var channel: UpdateChannel {
        get { UpdateChannel(rawValue: channelName) ?? .stable }
        set {
            guard newValue != channel else { return }
            channelName = newValue.rawValue
            // The last look answered a different question.
            lastCheck = 0
            state = .idle
        }
    }

    /// When it last looked, or nil if it never has.
    var lastCheckedAt: Date? {
        lastCheck > 0 ? Date(timeIntervalSince1970: lastCheck) : nil
    }

    private let service: UpdateService
    private let installer: Installer

    init(service: UpdateService = UpdateService(), installer: Installer = Installer()) {
        self.service = service
        self.installer = installer
    }

    // MARK: Launch

    func onLaunch() async {
        if warnsAboutFaultyBuilds {
            let found = await service.advisory(for: current)
            // A serious one can be set aside against that exact version. A
            // critical one cannot.
            if let found, found.severity == .serious,
               dismissedAdvisory == "\(current)|\(found.summary)" {
                advisory = nil
            } else {
                advisory = found
            }
        }
        guard checksForUpdates, isDueForCheck else { return }
        await check(byHand: false)
    }

    /// True when enough time has passed for this channel.
    var isDueForCheck: Bool {
        guard let lastCheckedAt else { return true }
        return Date().timeIntervalSince(lastCheckedAt) >= channel.interval
    }

    // MARK: Looking

    /// Looks for something newer.
    ///
    /// - Parameter byHand: True when somebody pressed a button. Asking once by
    ///   hand is not the same as agreeing to be asked every day, so this works
    ///   whether or not looking is switched on.
    func check(byHand: Bool = true) async {
        state = .looking
        do {
            let release = try await service.newestRelease(after: current, on: channel)
            lastCheck = Date().timeIntervalSince1970

            guard let release else {
                state = .upToDate
                return
            }
            if !byHand, skippedVersion == release.version.description {
                state = .idle
                return
            }
            state = .available(release)
            if installsWithoutAsking, !byHand {
                await install(release, wasAsked: false)
            }
        } catch {
            // A failure to look is said plainly and changes nothing else. The
            // time of the last look is not moved on, so the next launch tries
            // again rather than waiting out the interval.
            state = .failed(UpdateModel.explain(error))
        }
    }

    /// A failure in words a person can act on.
    ///
    /// Plain text work, so it stays off the main actor and stays testable.
    nonisolated static func explain(_ error: Error) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .some(.notConnectedToInternet), .some(.networkConnectionLost):
            return "No network, so it could not look."
        case .some(.timedOut):
            return "The releases page did not answer in time."
        case .some(.cannotFindHost), .some(.cannotConnectToHost):
            return "The releases page could not be reached."
        default:
            return error.localizedDescription
        }
    }

    /// Sets one release aside without turning looking off.
    func skip(_ release: Release) {
        skippedVersion = release.version.description
        state = .idle
    }

    /// Sets aside an advisory that can be set aside.
    func dismissAdvisory() {
        guard let advisory, advisory.severity == .serious else { return }
        dismissedAdvisory = "\(current)|\(advisory.summary)"
        self.advisory = nil
    }

    func openReleasePage(_ release: Release) {
        NSWorkspace.shared.open(release.pageURL)
    }

    // MARK: Installing

    /// Fetches, checks, and puts a release in place.
    ///
    /// - Parameter wasAsked: False when nobody asked. A failure then falls
    ///   back to offering it by hand rather than going quiet, because this
    ///   copy is now known to be behind.
    func install(_ release: Release, wasAsked: Bool = true) async {
        offerAfterFailure = nil
        state = .installing("Starting...")
        do {
            try await installer.install(release) { step in
                Task { @MainActor in self.state = .installing(step.description) }
            }
        } catch {
            state = .failed(error.localizedDescription)
            if !wasAsked { offerAfterFailure = release }
        }
    }

    /// Installs the version an advisory names as the fix.
    func installFix() async {
        guard let version = advisory?.fixedIn else { return }
        await install(Release(version: version, notes: ""))
    }

    /// Goes back to a version known to be good.
    func rollBack() async {
        guard let version = advisory?.rollBackTo else { return }
        await install(Release(version: version, notes: ""))
    }
}
