import SwiftUI

@main
struct EarmarkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
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

    var body: some View {
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
