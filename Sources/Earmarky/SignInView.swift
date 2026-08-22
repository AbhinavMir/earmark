import SwiftUI
import WebKit
import AudibleKit

/// The one-time Amazon sign-in.
///
/// Earmarky shows Amazon's own page and never sees the password. It watches for
/// the redirect that carries the authorization code and registers the device
/// with it.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var marketplace = AudibleMarketplace.us
    @State private var attempt: DeviceRegistration.Attempt?
    @State private var isRegistering = false
    @State private var failure: String?
    /// Every address the sign-in passed through, newest last. Shown when the
    /// code is not found, so the reason is visible rather than guessed at.
    @State private var trail: [String] = []
    @State private var showingTrail = false
    @State private var pastedRedirect = ""
    @State private var currentAddress = ""

    var body: some View {
        if let attempt {
            signInPage(attempt)
        } else {
            chooseStore
        }
    }

    private var chooseStore: some View {
        VStack(spacing: 20) {
            AppIconView(size: 84)
            Text("Earmarky").font(.largeTitle.weight(.semibold))
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
        VStack(spacing: 0) {
            // The controls live in the view rather than the window toolbar,
            // which does not render for this screen.
            HStack(spacing: 12) {
                Button("Back") { self.attempt = nil }
                Spacer()
                Text(currentAddress)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show Addresses") { showingTrail = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ZStack {
                AmazonSignInWebView(url: attempt.url) { redirect in
                    receive(redirect, attempt: attempt)
                }
                if isRegistering {
                    Color.black.opacity(0.35)
                    ProgressView("Registering this Mac...")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .sheet(isPresented: $showingTrail) { trailSheet }
    }

    /// Handles one address the sign-in passed through.
    private func receive(_ redirect: URL, attempt: DeviceRegistration.Attempt) {
        let address = redirect.absoluteString
        if trail.last != address { trail.append(address) }
        currentAddress = address

        guard let code = DeviceRegistration.authorizationCode(in: redirect) else {
            // Reaching the return page with no code means the sign-in finished
            // but Amazon issued nothing. Say so instead of showing a blank 404.
            if redirect.path.contains("/ap/maplanding") {
                failure = "Amazon returned to the landing page without an authorization code."
                showingTrail = true
            }
            return
        }
        register(code: code, attempt: attempt)
    }

    /// Lists the addresses the sign-in passed through, so a failed capture can
    /// be read directly. A code can also be pasted in by hand from here.
    private var trailSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign-in addresses").font(.headline)
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(trail.enumerated()), id: \.offset) { _, address in
                        Text(address)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 260)

            Text("Paste the address of the page that failed to load:")
                .font(.callout)
            HStack {
                TextField("https://www.amazon.com/ap/maplanding?...", text: $pastedRedirect)
                Button("Use") { usePastedRedirect() }
                    .disabled(pastedRedirect.isEmpty)
            }
            HStack {
                Spacer()
                Button("Close") { showingTrail = false }
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func usePastedRedirect() {
        guard let attempt else { return }
        guard let url = URL(string: pastedRedirect.trimmingCharacters(in: .whitespacesAndNewlines)),
              let code = DeviceRegistration.authorizationCode(in: url)
        else {
            failure = "That address carries no authorization code."
            return
        }
        showingTrail = false
        register(code: code, attempt: attempt)
    }

    private func register(code: String, attempt: DeviceRegistration.Attempt) {
        guard !isRegistering else { return }
        isRegistering = true
        Task {
            do {
                let name = "Earmarky on \(ProcessInfo.processInfo.hostName)"
                let identity = try await DeviceRegistration(marketplace: marketplace)
                    .register(code: code, attempt: attempt, deviceName: name)
                // Kept through the application's own store. A second store
                // writes to its own idea of where, and the first one has
                // already decided there is nothing there.
                await model.finishSignIn(with: identity)
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

        // Amazon reaches the landing page through a chain of server redirects.
        // Each hook below sees a different part of that chain, so all four
        // report, and the caller ignores an address it has already seen.

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let request = navigationAction.request
            if let url = request.url {
                // The last hop of the Amazon flow may be a form submission,
                // which carries its values in the body rather than the query.
                let method = request.httpMethod ?? "GET"
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
                Log.write("nav \(method) \(url.absoluteString)")
                if let body, !body.isEmpty {
                    Log.write("nav body: \(body)")
                }
                onNavigate(url)
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let url = navigationResponse.response.url { onNavigate(url) }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            if let url = webView.url { onNavigate(url) }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url { onNavigate(url) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                Log.write("loaded \(url.absoluteString)")
                onNavigate(url)
            }
            // A form submission's values never reach the delegate, so read the
            // finished page's own address and form fields directly.
            webView.evaluateJavaScript(
                "JSON.stringify({href: location.href, forms: "
                + "Array.from(document.querySelectorAll('input')).map(i => i.name)})"
            ) { value, _ in
                guard let value = value as? String else { return }
                Log.write("page state: \(value)")
            }
        }
    }
}
