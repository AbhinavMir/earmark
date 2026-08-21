import SwiftUI

@main
struct EarmarkApp: App {
    @State private var model = AppModel()
    @State private var updates = UpdateModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(updates)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    // A picture of the library, drawn without a screen.
                    if let path = PromoShot.requestedPath {
                        await PromoShot.run(path: path)
                    }
                    if let directory = PromoShot.requestedScenesPath {
                        await PromoShot.runScenes(directory: directory)
                    }
                    await model.start()
                }
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
