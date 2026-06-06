import AppKit
import WebKit

/// Presents an in-app login window so the user can complete the OAuth2 Proxy /
/// SSO flow. On success the `_oauth2_proxy` session cookie is copied from the
/// WKWebView's cookie store into `HTTPCookieStorage.shared`, which is what
/// `ServiceControlClient`'s URLSession uses — so polling becomes authenticated.
@MainActor
final class AuthManager: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var apiHost: String = ""
    private var onSuccess: (() -> Void)?
    private var finished = false

    /// Opens (or focuses) a login window for the given API host.
    func login(apiHost: String, onSuccess: @escaping () -> Void) {
        guard let url = URL(string: apiHost) else { return }
        self.apiHost = apiHost
        self.onSuccess = onSuccess
        self.finished = false

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // persistent, reused across launches

        let web = WKWebView(frame: NSRect(x: 0, y: 40, width: 540, height: 660), configuration: configuration)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        self.webView = web

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 700))
        container.addSubview(web)
        container.addSubview(makeBottomBar(width: 540))

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Sign in to \(URL(string: apiHost)?.host ?? apiHost)"
        win.contentView = container
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()

        web.load(URLRequest(url: url))
    }

    private func makeBottomBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        bar.autoresizingMask = [.width]

        let info = NSTextField(labelWithString: "Complete the sign-in, then click \u{201C}I\u{2019}m signed in\u{201D}.")
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 12, y: 11, width: 320, height: 18)
        info.autoresizingMask = [.maxXMargin]
        bar.addSubview(info)

        let done = NSButton(title: "I\u{2019}m signed in", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: width - 140, y: 6, width: 128, height: 28)
        done.autoresizingMask = [.minXMargin]
        bar.addSubview(done)

        return bar
    }

    @objc private func doneTapped() {
        syncCookiesAndFinish(force: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncCookiesAndFinish(force: false)
    }

    /// Copies cookies to shared storage and closes when an auth cookie is present
    /// (or when the user confirms via the button).
    private func syncCookiesAndFinish(force: Bool) {
        guard !finished, let host = URL(string: apiHost)?.host else { return }
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let matchesHost: (HTTPCookie) -> Bool = { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix(domain) || domain.hasSuffix(host)
            }
            let authCookiePresent = cookies.contains { cookie in
                matchesHost(cookie) && cookie.name.lowercased().contains("oauth2")
            }
            guard force || authCookiePresent else { return }

            for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
            self.finished = true
            self.onSuccess?()
            self.onSuccess = nil
            self.window?.close()
            self.window = nil
            self.webView = nil
        }
    }
}
