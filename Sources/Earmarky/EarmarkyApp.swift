import SwiftUI

@main
struct EarmarkyApp: App {
    @State private var model = AppModel()
    @State private var updates = UpdateModel()

    init() {
        // Drawing a picture of the library does not wait for a window. A
        // window only appears once something is on screen to show, and when
        // the application is started to draw a picture there is nothing.
        if let path = PromoShot.requestedPath {
            Task { @MainActor in await PromoShot.run(path: path) }
        }
        if let directory = PromoShot.requestedScenesPath {
            Task { @MainActor in await PromoShot.runScenes(directory: directory) }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(updates)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
                .task { await updates.onLaunch() }
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environment(updates)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { await updates.check() }
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Play or Pause") { model.player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Skip Ahead") { model.player.skipAhead() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Skip Back") { model.player.skipBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Divider()
                Button("Add Bookmark") { Task { await model.addBookmark() } }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Refresh Library") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        VStack(spacing: 0) {
            // A version known to be harmful says so before anything else, and
            // says it whatever the settings are.
            if let advisory = updates.advisory {
                AdvisoryBanner(advisory: advisory)
                Divider()
            }
            if updates.hasSomethingToSay {
                UpdateBar()
                Divider()
            }
            stage
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch model.stage {
        case .checkingCredentials:
            ProgressView().controlSize(.large)
        case .signedOut:
            SignInView()
        case .settingUp:
            SetupView()
        case .ready:
            LibraryView()
        }
    }
}
