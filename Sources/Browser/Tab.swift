import AppKit
import WebKit
import Combine

enum UserAgent {
    /// Identical to the installed Safari, so you blend in with the largest group of Mac users.
    static let safari: String = {
        let v = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "18.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v) Safari/605.1.15"
    }()
}

/// One browser tab. A tab hosts one WKWebView per site it has visited (each in that site's
/// container), so following a link to another site never carries cookies across.
@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    enum Problem: Equatable {
        case insecure(URL)                       // HTTPS-only: the site has no secure version
        case unreachable(URL, String)
        case blocked(URL, String)                // the page itself is on a block list
        case crashed
    }

    let id = UUID()
    @Published private(set) var webView: WKWebView?
    @Published var title = "New Tab"
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isSecure = false
    @Published var favicon: NSImage?
    @Published private(set) var site: String?
    @Published var problem: Problem?
    @Published var blockedCount = 0
    @Published var pageZoom: Double = 1

    weak var browser: BrowserState?
    private var kvo: [NSKeyValueObservation] = []
    private struct Hop { var webView: WKWebView?; var url: URL; var title: String; var site: String }
    private var back: [Hop] = []
    private var forward: [Hop] = []
    private var upgradedHosts = Set<String>()
    static var httpAllowed = Set<String>()       // hosts you chose to open without HTTPS (this session)

    init(browser: BrowserState?, url: URL? = nil) {
        self.browser = browser
        super.init()
        if let url { load(url) }
    }

    /// Wraps a popup WebKit created (window.open), so it keeps its link to the opener page.
    init(browser: BrowserState?, adopting wv: WKWebView, site: String) {
        self.browser = browser
        super.init()
        configure(wv)
        attach(wv, site: site)
    }

    var container: Container? { site.flatMap { ContainerManager.shared.existing(for: $0) } }
    var isNewTabPage: Bool { webView == nil && problem == nil }

    // MARK: Navigation

    func load(_ input: URL) {
        problem = nil
        var target = input
        if AppSettings.shared.cleanLinks, let c = LinkCleaner.clean(target) { target = c; Stats.shared.add(.linkCleaned) }
        if let up = upgrade(target) { target = up }
        guard let targetSite = PublicSuffix.shared.site(for: target), target.scheme?.hasPrefix("http") == true else {
            webView?.load(URLRequest(url: target)); return
        }
        if let wv = webView, site == targetSite {
            wv.load(URLRequest(url: target))
        } else {
            open(target, in: targetSite, keepHistory: hasCommitted)
        }
    }

    private var hasCommitted: Bool { webView?.backForwardList.currentItem != nil }

    /// HTTPS-only: rewrites http:// to https:// unless the host is local or you allowed it.
    private func upgrade(_ u: URL) -> URL? {
        guard AppSettings.shared.httpsOnly, u.scheme == "http", let host = u.host?.lowercased(),
              !PublicSuffix.isLocal(host), !Tab.httpAllowed.contains(host),
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        if c.port == 80 { c.port = nil }
        upgradedHosts.insert(host)
        Stats.shared.add(.httpsUpgrade)
        return c.url
    }

    private func open(_ url: URL, in targetSite: String, keepHistory: Bool) {
        if let cur = webView {
            if keepHistory {
                cur.pauseAllMediaPlayback { }
                back.append(Hop(webView: cur, url: cur.url ?? url, title: title, site: site ?? targetSite))
            } else {
                retire(cur)
            }
        }
        forward.forEach { $0.webView.map(retire) }
        forward.removeAll()
        trimHistory()
        let wv = makeWebView(for: targetSite)
        attach(wv, site: targetSite)
        wv.load(URLRequest(url: url))
    }

    func goBack() {
        if let wv = webView, wv.canGoBack { wv.goBack(); return }
        guard let hop = back.popLast() else { return }
        if let cur = webView { cur.pauseAllMediaPlayback { }; forward.append(Hop(webView: cur, url: cur.url ?? hop.url, title: title, site: site ?? hop.site)) }
        restore(hop)
    }

    func goForward() {
        if let wv = webView, wv.canGoForward { wv.goForward(); return }
        guard let hop = forward.popLast() else { return }
        if let cur = webView { cur.pauseAllMediaPlayback { }; back.append(Hop(webView: cur, url: cur.url ?? hop.url, title: title, site: site ?? hop.site)) }
        restore(hop)
    }

    private func restore(_ hop: Hop) {
        problem = nil
        if let wv = hop.webView {
            attach(wv, site: hop.site)
        } else {
            let wv = makeWebView(for: hop.site)
            attach(wv, site: hop.site)
            wv.load(URLRequest(url: hop.url))
        }
        trimHistory()
    }

    /// Keeps live pages only for the 3 most recent sites each way; older ones reload on demand.
    private func trimHistory() {
        for i in back.indices.dropLast(3) { if let w = back[i].webView { retire(w); back[i].webView = nil } }
        for i in forward.indices.dropLast(3) { if let w = forward[i].webView { retire(w); forward[i].webView = nil } }
        if back.count > 50 { back.removeFirst(back.count - 50) }
        updateNavState()
    }

    func reload() {
        if let p = problem {
            problem = nil
            switch p {
            case .insecure(let u), .unreachable(let u, _), .blocked(let u, _): load(u)
            case .crashed: webView?.reload()
            }
            return
        }
        webView?.reload()
    }

    func stop() { webView?.stopLoading() }

    /// Re-opens the current page in its site's newest container (after "Forget this site"
    /// or "Stay signed in" changed which data store the site uses).
    func reopenInFreshContainer() {
        guard let u = url, let s = site else { return }
        problem = nil
        open(u, in: s, keepHistory: false)
    }

    func setZoom(_ z: Double) {
        let clamped = min(max(z, 0.5), 3.0)
        webView?.pageZoom = clamped
        pageZoom = clamped
    }

    /// Continue to the plain-HTTP version of a site after the HTTPS-only warning.
    func allowInsecure(_ url: URL) {
        if let h = url.host?.lowercased() { Tab.httpAllowed.insert(h) }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = "http"
        problem = nil
        if let u = c?.url { load(u) }
    }

    /// Load anyway: turns protections off for this site (you can turn them back on in the shield panel).
    func allowBlockedPage(_ url: URL) {
        if let s = PublicSuffix.shared.site(for: url) { AppSettings.shared.shieldsOff.insert(s) }
        problem = nil
        load(url)
    }

    func close() {
        if let w = webView { retire(w) }
        (back + forward).compactMap(\.webView).forEach(retire)
        back.removeAll(); forward.removeAll()
        kvo.removeAll()
        webView = nil
    }

    func refreshBlockedCount() {
        let n = container?.proxy.report.pageBlockedCount ?? 0
        if n != blockedCount { blockedCount = n }
    }

    // MARK: WebView plumbing

    private func makeWebView(for site: String) -> WKWebView {
        let c = ContainerManager.shared.container(for: site)
        let wv = WKWebView(frame: .zero, configuration: c.configuration)
        configure(wv)
        return wv
    }

    private func configure(_ wv: WKWebView) {
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.customUserAgent = UserAgent.safari
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = true
        ContainerManager.shared.register(wv)
    }

    private func retire(_ wv: WKWebView) {
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.removeFromSuperview()
    }

    private func attach(_ wv: WKWebView, site newSite: String) {
        kvo.removeAll()
        webView = wv
        site = newSite
        wv.navigationDelegate = self
        wv.uiDelegate = self
        let refresh: (WKWebView) -> Void = { [weak self] _ in Task { @MainActor in self?.updateFromWebView() } }
        kvo = [
            wv.observe(\.title) { w, _ in refresh(w) },
            wv.observe(\.url) { w, _ in refresh(w) },
            wv.observe(\.isLoading) { w, _ in refresh(w) },
            wv.observe(\.canGoBack) { w, _ in refresh(w) },
            wv.observe(\.canGoForward) { w, _ in refresh(w) },
            wv.observe(\.hasOnlySecureContent) { w, _ in refresh(w) },
            wv.observe(\.estimatedProgress) { [weak self] w, _ in
                let p = w.estimatedProgress
                Task { @MainActor in self?.progress = p }
            },
        ]
        favicon = FaviconLoader.shared.cached(for: wv.url)
        updateFromWebView()
    }

    private func updateFromWebView() {
        guard let wv = webView else { return }
        let t = wv.title ?? ""
        if problem == nil || !t.isEmpty { title = t.isEmpty ? (wv.url?.host() ?? "New Tab") : t }
        if wv.url != nil || problem == nil { url = wv.url }
        isLoading = wv.isLoading
        isSecure = wv.url?.scheme == "https" && wv.hasOnlySecureContent
        pageZoom = wv.pageZoom
        updateNavState()
    }

    private func updateNavState() {
        canGoBack = (webView?.canGoBack ?? false) || !back.isEmpty
        canGoForward = (webView?.canGoForward ?? false) || !forward.isEmpty
    }
}

// MARK: - Navigation delegate

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = AppSettings.shared.javaScript
        guard let url = action.request.url else { return decisionHandler(.allow, preferences) }
        if action.shouldPerformDownload { return decisionHandler(.download, preferences) }

        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data", "javascript", "file"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            if ["mailto", "tel", "facetime", "sms", "maps"].contains(scheme) { NSWorkspace.shared.open(url) }
            return
        }
        let isMainFrame = action.targetFrame?.isMainFrame ?? false
        guard isMainFrame, webView === self.webView, scheme.hasPrefix("http") else { return decisionHandler(.allow, preferences) }

        // ⌘-click opens a background tab.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            decisionHandler(.cancel, preferences)
            browser?.newTab(url: url, after: self, select: action.modifierFlags.contains(.shift))
            return
        }

        let isGET = (action.request.httpMethod ?? "GET").uppercased() == "GET"
        var target = url
        var changed = false
        if isGET, AppSettings.shared.cleanLinks, let c = LinkCleaner.clean(target) { target = c; changed = true; Stats.shared.add(.linkCleaned) }
        if isGET, let up = upgrade(target) { target = up; changed = true }

        let targetSite = PublicSuffix.shared.site(for: target)
        if isGET, let targetSite, targetSite != site {
            decisionHandler(.cancel, preferences)
            open(target, in: targetSite, keepHistory: hasCommitted)    // other site: its own container
            return
        }
        if changed {
            decisionHandler(.cancel, preferences)
            webView.load(URLRequest(url: target))
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if !response.canShowMIMEType { return decisionHandler(.download) }
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.attach(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.attach(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        problem = nil
        container?.proxy.report.beginPage()
        blockedCount = 0
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        updateFromWebView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        updateFromWebView()
        if let u = webView.url { HistoryStore.shared.record(u, title: title) }
        loadFavicon(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        problem = .crashed
    }

    private func handle(_ error: Error, in webView: WKWebView) {
        guard webView === self.webView else { return }
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? url
        guard let failing else { return }
        let host = failing.host?.lowercased() ?? ""
        isLoading = false
        url = failing                                  // keep what you asked for in the address bar
        title = failing.host() ?? failing.absoluteString
        if container?.proxy.report.recentlyBlocked(host) == true {
            problem = .blocked(failing, host)
        } else if upgradedHosts.contains(host), Self.secureFailureCodes.contains(e.code) {
            problem = .insecure(failing)
        } else if e.domain == NSURLErrorDomain && [NSURLErrorBadURL, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(e.code) {
            problem = .unreachable(failing, "There's no website at this address")
        } else {
            problem = .unreachable(failing, e.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
    }

    private static let secureFailureCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
        NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
    ]

    private func loadFavicon(_ wv: WKWebView) {
        let js = "(() => { const l = document.querySelector('link[rel~=\"icon\"][sizes=\"32x32\"], link[rel~=\"icon\"], link[rel=\"apple-touch-icon\"]'); return l ? l.href : null; })()"
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let page = wv.url else { return }
            let icon = (result as? String).flatMap(URL.init(string:)) ?? URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL
            guard let icon, let c = self.container else { return }
            FaviconLoader.shared.load(icon, page: page, proxyPort: c.proxy.port) { [weak self] img in
                if wv === self?.webView { self?.favicon = img }
            }
        }
    }
}

// MARK: - UI delegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A target=_blank link: open a normal tab in the right site's container (no opener link).
        if action.navigationType == .linkActivated, let url = action.request.url {
            browser?.newTab(url: url, after: self, select: !action.modifierFlags.contains(.command))
            return nil
        }
        // A script popup (sign-in windows etc.) must share the opener's container to work.
        let wv = WKWebView(frame: .zero, configuration: configuration)
        let tab = Tab(browser: browser, adopting: wv, site: site ?? "popup")
        browser?.insert(tab, after: self, select: true)
        return wv
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === self.webView { browser?.close(self) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert(); a.messageText = frame.securityOrigin.host; a.informativeText = message
        present(a) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert(); a.messageText = frame.securityOrigin.host; a.informativeText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        present(a) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let a = NSAlert(); a.messageText = frame.securityOrigin.host; a.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        present(a) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        if let w = browser?.window { p.beginSheetModal(for: w) { completionHandler($0 == .OK ? p.urls : nil) } }
        else { completionHandler(p.runModal() == .OK ? p.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)       // WebKit asks you each time
    }

    private func present(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = browser?.window { alert.beginSheetModal(for: w, completionHandler: done) } else { done(alert.runModal()) }
    }
}
