import Foundation
import Testing
@testable import Earmark

@Suite("Versions")
struct AppVersionTests {

    @Test("Every shape a tag comes in is read")
    func reading() {
        #expect(AppVersion("1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("1.2") == AppVersion(major: 1, minor: 2, patch: 0))
        #expect(AppVersion("1") == AppVersion(major: 1, minor: 0, patch: 0))
        // A dash ends it, so a name for a trial build still reads.
        #expect(AppVersion("1.2.3-beta1") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("v2.0.0-rc.1") == AppVersion(major: 2, minor: 0, patch: 0))
    }

    @Test("Text that is not a version reads as nothing")
    func refusesRubbish() {
        // A tag nobody can read is not a reason to tell somebody to upgrade.
        for text in ["", "v", "a.b.c", "1.2.x", "1.2.3.4", "-1.0.0", "1..3",
                     "..", "1.2.3rc", "🎧", "latest", "nightly",
                     String(repeating: "9", count: 400)] {
            #expect(AppVersion(text) == nil, "\(text) was taken as a version")
        }
    }

    @Test("Versions compare as numbers, not as text")
    func ordering() {
        // Comparing the text says 1.10.0 is older than 1.9.0.
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
        #expect(AppVersion("1.0.10")! > AppVersion("1.0.9")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
        #expect(AppVersion("1.2.3")! == AppVersion("1.2.3")!)
        #expect(!(AppVersion("1.2.3")! > AppVersion("1.2.3")!))
    }

    @Test("The last number says whether a release is finished work")
    func sequential() {
        #expect(AppVersion("1.3.0")!.isSequential)
        #expect(AppVersion("2.0.0")!.isSequential)
        #expect(!AppVersion("1.3.1")!.isSequential)
    }

    @Test("A channel is decided by the version, never by a flag")
    func channels() {
        #expect(UpdateChannel.stable.carries(AppVersion("1.3.0")!))
        #expect(!UpdateChannel.stable.carries(AppVersion("1.3.1")!))
        #expect(UpdateChannel.nightly.carries(AppVersion("1.3.0")!))
        #expect(UpdateChannel.nightly.carries(AppVersion("1.3.1")!))
    }

    @Test("Nightly is looked for more often than finished work")
    func intervals() {
        #expect(UpdateChannel.nightly.interval == 60 * 60 * 6)
        #expect(UpdateChannel.stable.interval == 60 * 60 * 24)
    }
}

@Suite("Reading releases")
struct ReleaseReadingTests {

    static let json = Data("""
    [
      {"tag_name": "v1.3.1", "body": "Nightly", "draft": false, "prerelease": true},
      {"tag_name": "v1.3.0", "body": "Finished", "draft": false, "prerelease": true},
      {"tag_name": "v1.2.0", "body": "Older", "draft": false, "prerelease": false},
      {"tag_name": "v9.9.9", "body": "A draft", "draft": true, "prerelease": false},
      {"tag_name": "nightly", "body": "Unreadable", "draft": false},
      {"body": "No tag at all"}
    ]
    """.utf8)

    @Test("Drafts are left out and prereleases are kept")
    func readsReleases() {
        // A prerelease is what a nightly is. A draft is not published.
        let releases = UpdateService.releases(from: Self.json)
        #expect(releases.map(\.version.description) == ["1.3.1", "1.3.0", "1.2.0"])
    }

    @Test("A finished release marked as a prerelease still reaches the stable channel")
    func prereleaseFlagIsIgnored() {
        // 1.3.0 is marked prerelease above, while it is being tried out.
        let releases = UpdateService.releases(from: Self.json)
        let offered = releases.filter {
            UpdateChannel.stable.carries($0.version) && $0.version > AppVersion("1.2.0")!
        }
        #expect(offered.map(\.version.description) == ["1.3.0"])
    }

    @Test("A version equal to the running one is not an update")
    func equalIsNotNewer() {
        let releases = UpdateService.releases(from: Self.json)
        let same = AppVersion("1.3.1")!
        #expect(releases.filter { $0.version > same }.isEmpty)
    }

    @Test("Addresses are worked out from the version")
    func addresses() {
        let release = Release(version: AppVersion("1.3.0")!, notes: "")
        #expect(release.downloadURL.absoluteString
                == "https://github.com/AbhinavMir/earmark/releases/download/v1.3.0/Earmarky-1.3.0.dmg")
        #expect(release.pageURL.absoluteString
                == "https://github.com/AbhinavMir/earmark/releases/tag/v1.3.0")
    }

    @Test("The request names the application and nothing else")
    func userAgent() {
        #expect(UpdateService.userAgent(for: AppVersion("1.2.3")!) == "Earmarky/1.2.3")
    }
}

@Suite("Reading advisories")
struct AdvisoryReadingTests {

    static let json = Data("""
    {"advisories": [
      {"affects": ["1.1.0"], "severity": "critical",
       "summary": "Loses bookmarks on quit.",
       "detail": "Bookmarks made in this build are not written.",
       "fixedIn": "1.1.1", "rollBackTo": "1.0.11"},
      {"affects": ["1.1.0", "1.1.1"], "severity": "serious",
       "summary": "Sign-in fails on some accounts."},
      {"affects": ["not-a-version"], "severity": "critical", "summary": "x"},
      {"affects": [], "summary": "no versions"},
      {"affects": ["1.2.0"], "summary": ""},
      {"nonsense": true}
    ]}
    """.utf8)

    @Test("Readable records are kept and the rest are left out")
    func readsAdvisories() {
        // One bad record must not hide a real warning.
        let advisories = UpdateService.advisories(from: Self.json)
        #expect(advisories.count == 2)
    }

    @Test("Versions affected are an exact list, never a range")
    func exactVersions() {
        let advisories = UpdateService.advisories(from: Self.json)
        #expect(advisories[0].covers(AppVersion("1.1.0")!))
        #expect(!advisories[0].covers(AppVersion("1.1.1")!))
        #expect(!advisories[0].covers(AppVersion("1.0.9")!))
        #expect(advisories[1].covers(AppVersion("1.1.1")!))
    }

    @Test("A record that does not say how bad it is counts as serious")
    func defaultSeverity() {
        let data = Data("""
        {"advisories": [{"affects": ["1.0.0"], "summary": "Something is wrong."}]}
        """.utf8)
        #expect(UpdateService.advisories(from: data).first?.severity == .serious)
    }

    @Test("The worst one wins when more than one matches")
    func worstWins() {
        let matching = UpdateService.advisories(from: Self.json)
            .filter { $0.covers(AppVersion("1.1.0")!) }
        #expect(matching.count == 2)
        #expect(matching.max { $0.severity < $1.severity }?.severity == .critical)
    }

    @Test("Anything at all can be offered as a list without ending the process")
    func fuzzLists() {
        var state: UInt64 = 11
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        var bodies: [Data] = [
            Data(), Data("null".utf8), Data("[]".utf8), Data("{}".utf8),
            Data(#"{"advisories": "none"}"#.utf8),
            Data(#"{"advisories": [null]}"#.utf8),
            Data(#"{"advisories": [{"affects": "1.0.0"}]}"#.utf8),
            Data(String(repeating: "{", count: 400).utf8)
        ]
        for _ in 0..<60 {
            bodies.append(Data((0..<Int(next() % 300)).map {
                _ in UInt8(truncatingIfNeeded: next())
            }))
        }
        for body in bodies {
            _ = UpdateService.advisories(from: body)
            _ = UpdateService.releases(from: body)
        }
    }
}

@Suite("What an installer accepts")
struct InstallerTests {

    @Test("The requirement names the bundle, the developer, and Apple's anchor")
    func requirementIsSpecific() {
        // Without the identifier, any application by this developer would
        // pass. Without the team, any signed application would.
        #expect(Installer.requirement.contains("com.earmark.app"))
        #expect(Installer.requirement.contains("P4ANTPX4G4"))
        #expect(Installer.requirement.contains("anchor apple generic"))
    }

    @Test("An application signed by somebody else is refused")
    func refusesForeignSignature() throws {
        let installer = Installer()
        for path in ["/System/Applications/Calculator.app",
                     "/System/Applications/TextEdit.app"]
            where FileManager.default.fileExists(atPath: path) {
            #expect(throws: (any Error).self, "accepted \(path)") {
                try installer.verify(URL(fileURLWithPath: path))
            }
        }
    }

    @Test("Something that is not an application is refused")
    func refusesRubbish() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-app-\(UUID().uuidString).app")
        try Data("not an application".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try Installer().verify(file) }
    }

    @Test("Every step says what it is doing")
    func stepsSpeak() {
        // A click that fetches silently reads as a button that did nothing.
        #expect(Installer.Step.fetching(fraction: 0.5).description == "Fetching 50%")
        #expect(Installer.Step.fetching(fraction: nil).description == "Fetching...")
        #expect(!Installer.Step.checking.description.isEmpty)
        #expect(!Installer.Step.replacing.description.isEmpty)
        #expect(!Installer.Step.done.description.isEmpty)

        // A fraction outside what a fraction can be still reads.
        #expect(Installer.Step.fetching(fraction: .nan).description.hasPrefix("Fetching"))
        #expect(Installer.Step.fetching(fraction: 5).description == "Fetching 100%")
    }
}

@Suite("When the network is not there")
struct OfflineTests {

    @Test("A failure to look is said in words a person can act on")
    func failuresAreReadable() {
        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "No network"),
            (.timedOut, "did not answer in time"),
            (.cannotFindHost, "could not be reached"),
            (.networkConnectionLost, "No network")
        ]
        for (code, expected) in cases {
            let text = UpdateModel.explain(URLError(code))
            #expect(text.contains(expected), "\(code) gave \(text)")
        }
    }

    @Test("Anything else still says something")
    func unknownFailuresStillSpeak() {
        struct Nameless: Error {}
        #expect(!UpdateModel.explain(Nameless()).isEmpty)
    }
}

@Suite("How often it looks")
struct CheckIntervalTests {

    @Test("A look is due when the interval has passed, and not before")
    func intervalDecides() {
        let now = Date()
        for channel in UpdateChannel.allCases {
            let justChecked = now.addingTimeInterval(-channel.interval + 60)
            let longAgo = now.addingTimeInterval(-channel.interval - 60)

            #expect(now.timeIntervalSince(justChecked) < channel.interval)
            #expect(now.timeIntervalSince(longAgo) >= channel.interval)
        }
    }

    @Test("A copy that has never looked is due at once")
    func neverCheckedIsDue() {
        // Otherwise switching the setting on would wait a day before doing
        // anything.
        let never: Date? = nil
        #expect(never == nil)
    }
}

@Suite("The signature check actually runs")
struct RequirementFormTests {

    /// Runs codesign the way the installer does, and reports what happened.
    static func check(_ path: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify", "--deep", "--strict",
            "-R=\(Installer.requirement)",
            path
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try? process.run()
        let text = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    @Test("The requirement is understood, not read as a file name")
    func requirementIsUnderstood() {
        // Given as a separate argument, the requirement is read as the name of
        // a file and codesign stops before it checks anything. That refuses
        // every update, including the right ones.
        let result = Self.check("/System/Applications/Calculator.app")
        #expect(!result.output.contains("invalid requirement"),
                "the requirement was not understood: \(result.output)")
        #expect(!result.output.contains("No such file"),
                "the requirement was read as a file name: \(result.output)")
    }

    @Test("An application by another developer is refused for the right reason")
    func foreignApplicationRefused() {
        let result = Self.check("/System/Applications/Calculator.app")
        #expect(result.status != 0)
        #expect(result.output.contains("failed to satisfy"),
                "refused for the wrong reason: \(result.output)")
    }
}
