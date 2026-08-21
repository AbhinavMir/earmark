import Foundation
import Testing
@testable import Earmark

@Suite("Versions and channels")
struct AppVersionTests {

    @Test("A version reads from text, with or without a leading v")
    func reading() {
        #expect(AppVersion("1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion(" 1.0.0 ") == AppVersion(major: 1, minor: 0, patch: 0))
    }

    @Test("Text that is not a version reads as nothing")
    func refusesRubbish() {
        for text in ["", "1", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "-1.0.0",
                     "1..3", "..", "v", "1.2.3-beta", "🎧",
                     String(repeating: "9", count: 400)] {
            #expect(AppVersion(text) == nil, "\(text) was taken as a version")
        }
    }

    @Test("Versions order by each number in turn")
    func ordering() {
        #expect(AppVersion("1.0.0")! < AppVersion("1.0.1")!)
        #expect(AppVersion("1.0.9")! < AppVersion("1.1.0")!)
        #expect(AppVersion("1.9.9")! < AppVersion("2.0.0")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
        #expect(AppVersion("1.2.3")! == AppVersion("1.2.3")!)
    }

    @Test("The last number says whether a version is finished work")
    func stability() {
        // 1.3.0 is finished; 1.2.1 is the day's work.
        #expect(AppVersion("1.3.0")!.isStable)
        #expect(!AppVersion("1.2.1")!.isStable)
        #expect(AppVersion("1.3.0")!.channel == .stable)
        #expect(AppVersion("1.2.1")!.channel == .nightly)
    }

    @Test("A channel offers only what belongs to it")
    func channelsCarry() {
        let finished = AppVersion("1.3.0")!
        let nightly = AppVersion("1.3.1")!

        #expect(UpdateChannel.stable.carries(finished))
        #expect(!UpdateChannel.stable.carries(nightly))
        #expect(UpdateChannel.nightly.carries(finished))
        #expect(UpdateChannel.nightly.carries(nightly))
    }
}

@Suite("Reading releases and recalls")
struct UpdateServiceTests {

    static let releasesJSON = Data("""
    [
      {"tag_name": "v1.3.1", "body": "A night's work", "draft": false},
      {"tag_name": "v1.3.0", "body": "Finished", "draft": false},
      {"tag_name": "v1.2.0", "body": "Older", "draft": false},
      {"tag_name": "v2.0.0", "body": "A draft", "draft": true},
      {"tag_name": "not-a-version", "body": "", "draft": false},
      {"body": "no tag at all"}
    ]
    """.utf8)

    @Test("Releases are read, newest first, and drafts left out")
    func readsReleases() {
        let releases = UpdateService.releases(from: Self.releasesJSON)
        #expect(releases.map(\.version.description) == ["1.3.1", "1.3.0", "1.2.0"])
    }

    @Test("A download address is worked out from the version")
    func downloadAddress() {
        let release = Release(version: AppVersion("1.3.0")!, notes: "")
        #expect(release.downloadURL.absoluteString
                == "https://github.com/AbhinavMir/earmark/releases/download/v1.3.0/Earmark-1.3.0.dmg")
    }

    @Test("A stable channel is never offered a night's work")
    func stableSkipsNightlies() {
        let releases = UpdateService.releases(from: Self.releasesJSON)
        let current = AppVersion("1.2.0")!

        let stable = releases.filter { UpdateChannel.stable.carries($0.version)
            && $0.version > current }
        #expect(stable.map(\.version.description) == ["1.3.0"])

        let nightly = releases.filter { UpdateChannel.nightly.carries($0.version)
            && $0.version > current }
        #expect(nightly.map(\.version.description) == ["1.3.1", "1.3.0"])
    }

    @Test("A recall list is read, and entries that say nothing are left out")
    func readsRecalls() {
        let data = Data("""
        [
          {"version": "1.2.1", "reason": "Loses bookmarks on quit.",
           "fixed_in": "1.2.2", "last_good": "1.2.0"},
          {"version": "1.1.0", "reason": "Will not sign in."},
          {"version": "not-a-version", "reason": "x"},
          {"version": "1.0.0"},
          {"version": "1.0.0", "reason": ""}
        ]
        """.utf8)
        let recalls = UpdateService.recalls(from: data)
        #expect(recalls.count == 2)
        #expect(recalls[0].version == AppVersion("1.2.1")!)
        #expect(recalls[0].fixedIn == AppVersion("1.2.2")!)
        #expect(recalls[0].lastGood == AppVersion("1.2.0")!)
        #expect(recalls[1].fixedIn == nil)
    }

    @Test("Anything at all can be offered as a list without ending the process")
    func fuzzLists() {
        var state: UInt64 = 7
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        var bodies: [Data] = [
            Data(), Data("null".utf8), Data("{}".utf8), Data("[]".utf8),
            Data("[[]]".utf8), Data(#"[{"tag_name": 1}]"#.utf8),
            Data(#"[{"tag_name": "v1.0.0", "draft": "yes"}]"#.utf8),
            Data(String(repeating: "[", count: 500).utf8)
        ]
        for _ in 0..<60 {
            bodies.append(Data((0..<Int(next() % 300)).map {
                _ in UInt8(truncatingIfNeeded: next())
            }))
        }
        for body in bodies {
            _ = UpdateService.releases(from: body)
            _ = UpdateService.recalls(from: body)
        }
    }
}

@Suite("What an installer accepts")
struct InstallerTests {

    @Test("The requirement names this developer and Apple's own anchor")
    func requirementIsSpecific() {
        // Without the team, any signed application would pass.
        #expect(Installer.requirement.contains("P4ANTPX4G4"))
        #expect(Installer.requirement.contains("anchor apple generic"))
    }

    @Test("An application signed by somebody else is refused")
    func refusesForeignSignature() throws {
        // Every application on the machine that is not this developer's.
        let others = ["/System/Applications/Calculator.app",
                      "/System/Applications/TextEdit.app"]
        let installer = Installer()
        for path in others where FileManager.default.fileExists(atPath: path) {
            #expect(throws: (any Error).self, "accepted \(path)") {
                try installer.verify(URL(fileURLWithPath: path))
            }
        }
    }

    @Test("Something that is not an application at all is refused")
    func refusesRubbish() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-app-\(UUID().uuidString).app")
        try Data("not an application".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: (any Error).self) {
            try Installer().verify(file)
        }
    }
}
