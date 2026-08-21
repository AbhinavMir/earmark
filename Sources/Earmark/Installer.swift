import Foundation
import AppKit
import AudibleKit

/// Fetches a release and puts it in place of the running application.
///
/// The order matters. The new application is checked before anything is
/// replaced, and it is copied beside the old one rather than over it, so a
/// failure at any point leaves a working application rather than none.
struct Installer: Sendable {
    /// What a build must be, to be put in place.
    ///
    /// The identifier keeps it to this application, the team keeps it to this
    /// developer, and the anchor keeps it to a certificate Apple issued.
    /// Without the identifier, any application by this developer would pass;
    /// without the team, any signed application would.
    static let requirement = "identifier \"com.earmark.app\" "
        + "and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"P4ANTPX4G4\""

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// What the installer is doing. Said as text at each step, because a
    /// click that fetches silently reads as a button that did nothing.
    enum Step: Sendable, CustomStringConvertible {
        case fetching(fraction: Double?)
        case checking
        case replacing
        case done

        var description: String {
            switch self {
            case .fetching(let fraction):
                guard let fraction else { return "Fetching..." }
                return "Fetching \(Int(min(100, max(0, fraction * 100))))%"
            case .checking: return "Checking the signature..."
            case .replacing: return "Putting it in place..."
            case .done: return "Restarting..."
            }
        }
    }

    /// Installs `release` over the running application and restarts it.
    ///
    /// - Throws: When anything is wrong. The running application is untouched
    ///   unless the very last step succeeded.
    func install(
        _ release: Release,
        onStep: @Sendable @escaping (Step) -> Void = { _ in }
    ) async throws {
        onStep(.fetching(fraction: nil))
        let image = try await download(release, onStep: onStep)
        defer { try? FileManager.default.removeItem(at: image) }

        onStep(.checking)
        let mounted = try mount(image)
        defer { unmount(mounted) }

        let newApp = mounted.appendingPathComponent("Earmark.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw AudibleError.downloadFailed("The disk image holds no application.")
        }

        // A refusal, not a warning. An application that is not signed by the
        // right developer is never put in place.
        try verify(newApp)

        onStep(.replacing)
        try replaceRunningApplication(with: newApp)

        onStep(.done)
        restart()
    }

    // MARK: Steps

    private func download(
        _ release: Release,
        onStep: @Sendable @escaping (Step) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 120

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AudibleError.downloadFailed("The release could not be fetched.")
        }
        let expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Earmark-\(release.version).dmg")
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: nil)

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        var buffer = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onStep(.fetching(fraction: expected.map { Double(received) / Double($0) }))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        // A part of a disk image is not a disk image.
        if let expected, received != expected {
            try? FileManager.default.removeItem(at: file)
            throw AudibleError.downloadFailed(
                "The download stopped early: \(received) bytes of \(expected).")
        }
        return file
    }

    private func mount(_ image: URL) throws -> URL {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", image.path, "-nobrowse", "-readonly", "-noverify", "-plist"
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AudibleError.downloadFailed("The disk image did not open.")
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let point = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw AudibleError.downloadFailed("The disk image reported no mount point.")
        }
        return URL(fileURLWithPath: point, isDirectory: true)
    }

    private func unmount(_ mounted: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mounted.path, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    /// Checks the new application is signed by the right developer.
    func verify(_ application: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // The requirement goes in the same argument as the flag. Given as a
        // separate one it is read as the name of a file, and codesign stops
        // with "invalid requirement specification" before it checks anything.
        process.arguments = [
            "--verify", "--deep", "--strict",
            "-R=\(Installer.requirement)",
            application.path
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()

        let text = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AudibleError.downloadFailed(
                "The download is not signed by the developer of this application. "
                + "Nothing was replaced. \(text.prefix(200))")
        }
    }

    /// Puts the new application where the running one is.
    ///
    /// The copy lands beside the old application first. Only once it is whole
    /// are the two exchanged, so an interrupted install leaves the old one
    /// working.
    private func replaceRunningApplication(with newApp: URL) throws {
        let running = Bundle.main.bundleURL
        let beside = running.deletingLastPathComponent()
            .appendingPathComponent("Earmark-new-\(UUID().uuidString).app")

        try FileManager.default.copyItem(at: newApp, to: beside)

        do {
            // The new copy is checked again where it now lives, because that
            // is the copy that will run.
            try verify(beside)
            _ = try FileManager.default.replaceItemAt(running, withItemAt: beside)
        } catch {
            try? FileManager.default.removeItem(at: beside)
            throw error
        }
    }

    private func restart() {
        let running = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this application to close, then open the new one.
        process.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; "
            + "do sleep 0.2; done; open \(running.path.replacingOccurrences(of: " ", with: "\\ "))"
        ]
        try? process.run()

        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }
}
