import Foundation
import Network
import WebKit

/// Everything belonging to one site: its own cookie jar and storage, its own proxy, and
/// the WebKit configuration its pages use. Sites can never read each other's data, and
/// ad networks can't follow you from one site to the next.
@MainActor
final class Container {
    let site: String
    let store: WKWebsiteDataStore
    let proxy: SocksProxy
    let persistent: Bool
    let tor: Bool
    let configuration: WKWebViewConfiguration
    let seed = UInt32.random(in: 1...UInt32.max)      // per-site, per-session fingerprint noise

    init(site: String, store: WKWebsiteDataStore, proxy: SocksProxy, persistent: Bool, tor: Bool) {
        self.site = site
        self.store = store
        self.proxy = proxy
        self.persistent = persistent
        self.tor = tor
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        cfg.userContentController = WKUserContentController()
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.mediaTypesRequiringUserActionForPlayback = .audio          // no surprise sound
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration = cfg
        apply()
    }

    /// Applies the current settings: content rules, privacy scripts, preferences.
    func apply() {
        let s = AppSettings.shared
        let on = s.shieldsOn(for: site)
        configuration.preferences.isFraudulentWebsiteWarningEnabled = s.fraudWarnings
        configuration.defaultWebpagePreferences.allowsContentJavaScript = s.javaScript
        let ucc = configuration.userContentController
        ucc.removeAllContentRuleLists()
        ucc.removeAllUserScripts()
        if on { ContentRules.shared.install(into: ucc) }
        if let script = Shields.script(seed: seed, site: site, shieldsOn: on) { ucc.addUserScript(script) }
    }
}

@MainActor
final class ContainerManager {
    static let shared = ContainerManager()
    private var containers: [String: Container] = [:]
    private var webViews = NSHashTable<WKWebView>.weakObjects()

    var all: [Container] { Array(containers.values) }

    /// Tor windows use separate containers: memory-only, never "stay signed in", so nothing
    /// links what you do in a Tor window to your normal windows.
    private func key(_ site: String, _ tor: Bool) -> String { tor ? "tor|" + site : site }

    func container(for site: String, tor: Bool = false) -> Container {
        if let c = containers[key(site, tor)] { return c }
        let settings = AppSettings.shared
        let store: WKWebsiteDataStore
        var persistent = false
        if !tor, let idString = settings.rememberedSites[site], let id = UUID(uuidString: idString) {
            store = WKWebsiteDataStore(forIdentifier: id)
            persistent = true
        } else {
            store = .nonPersistent()                                    // forgotten when Umbra quits
        }
        let proxy = (try? SocksProxy(site: site, tor: tor)) ?? (try! SocksProxy(site: site, tor: tor))
        // Must be set before any page uses this store.
        store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!))]
        let c = Container(site: site, store: store, proxy: proxy, persistent: persistent, tor: tor)
        containers[key(site, tor)] = c
        return c
    }

    func existing(for site: String, tor: Bool = false) -> Container? { containers[key(site, tor)] }

    /// Re-applies settings to a site's containers in normal and Tor windows.
    func apply(site: String) { containers.values.filter { $0.site == site }.forEach { $0.apply() } }

    /// New Tor identity: forget every Tor container (cookies, storage, cache).
    func dropTorContainers() {
        for (k, c) in containers where c.tor {
            c.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            containers.removeValue(forKey: k)
        }
    }

    func register(_ webView: WKWebView) { webViews.add(webView) }

    func refreshAll() { containers.values.forEach { $0.apply() } }

    /// Keep this site's cookies and logins after quitting (new data store from now on).
    func remember(_ site: String) {
        guard AppSettings.shared.rememberedSites[site] == nil else { return }
        AppSettings.shared.rememberedSites[site] = UUID().uuidString
        drop(site)
    }

    /// Stop remembering a site and delete everything it stored.
    func forget(_ site: String) {
        let id = AppSettings.shared.rememberedSites.removeValue(forKey: site)
        drop(site)
        if let id, let uuid = UUID(uuidString: id) {
            PendingDeletion.add(uuid)
            PendingDeletion.run()
        }
    }

    /// Discards the live container so the next visit starts fresh.
    private func drop(_ site: String) {
        guard let c = containers.removeValue(forKey: site) else { return }
        if !c.persistent {
            c.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        // The proxy stays up until the old pages are gone; it is tiny.
    }

    /// Wipes every non-remembered site's data right now.
    func forgetAllUnremembered() {
        for (k, c) in containers where !c.persistent {
            c.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            containers.removeValue(forKey: k)
        }
    }
}

/// Remembered-site data stores can only be deleted once no page uses them, so deletions
/// are queued and retried (also at the next launch).
enum PendingDeletion {
    private static let key = "pendingStoreDeletions"
    static func add(_ id: UUID) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.append(id.uuidString)
        UserDefaults.standard.set(list, forKey: key)
    }
    @MainActor static func run() {
        let list = UserDefaults.standard.stringArray(forKey: key) ?? []
        for s in list {
            guard let id = UUID(uuidString: s) else { continue }
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if error == nil {
                    var l = UserDefaults.standard.stringArray(forKey: key) ?? []
                    l.removeAll { $0 == s }
                    UserDefaults.standard.set(l, forKey: key)
                }
            }
        }
    }
}
