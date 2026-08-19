import SwiftUI
import WebKit
import AudibleKit

/// The one-time Amazon sign-in.
///
/// Earmark shows Amazon's own page and never sees the password. It watches for
/// the redirect that carries the authorization code and registers the device
/// with it.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var marketplace = AudibleMarketplace.us
    @State private var attempt: DeviceRegistration.Attempt?
    @State private var isRegistering = false
    @State private var failure: String?

    var body: some View {
        if let attempt {
            signInPage(attempt)
        } else {
            chooseStore
        }
    }

    private var chooseStore: some View {
        VStack(spacing: 20) {
            Image(systemName: "headphones")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Earmark").font(.largeTitle.weight(.semibold))
            Text("Sign in to Audible to reach your library.")
                .foregroundStyle(.secondary)

            Picker("Audible store", selection: $marketplace) {
                ForEach(AudibleMarketplace.all, id: \.countryCode) { store in
                    Text(store.countryCode.uppercased()).tag(store)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)

            Button("Sign In") {
                attempt = DeviceRegistration(marketplace: marketplace).signInAttempt()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(40)
    }

    private func signInPage(_ attempt: DeviceRegistration.Attempt) -> some View {
        ZStack {
            AmazonSignInWebView(url: attempt.url) { redirect in
                guard let code = DeviceRegistration.authorizationCode(in: redirect) else { return }
                register(code: code, attempt: attempt)
            }
            if isRegistering {
                Color.black.opacity(0.35)
                ProgressView("Registering this Mac...")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { self.attempt = nil }
            }
        }
    }

    private func register(code: String, attempt: DeviceRegistration.Attempt) {
        guard !isRegistering else { return }
        isRegistering = true
        Task {
            do {
                let name = "Earmark on \(ProcessInfo.processInfo.hostName)"
                let identity = try await DeviceRegistration(marketplace: marketplace)
                    .register(code: code, attempt: attempt, deviceName: name)
                try KeychainCredentialStore().save(identity)
                await model.connect()
            } catch {
                failure = error.localizedDescription
                self.attempt = nil
            }
            isRegistering = false
        }
    }
}

/// Shows Amazon's sign-in page and reports every address it lands on.
struct AmazonSignInWebView: NSViewRepresentable {
    let url: URL
    let onNavigate: (URL) -> Void

    func makeNSView(context: Context) -> WKWebView {
        // A fresh data store each time, so a previous sign-in never leaks into
        // the next one.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigate: onNavigate)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onNavigate: (URL) -> Void

        init(onNavigate: @escaping (URL) -> Void) {
            self.onNavigate = onNavigate
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                onNavigate(url)
            }
            decisionHandler(.allow)
        }
    }
}
